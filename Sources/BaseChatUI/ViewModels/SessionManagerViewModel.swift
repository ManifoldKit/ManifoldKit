import Foundation
import Observation
import BaseChatRuntime
import BaseChatInference

/// Scope for ``SessionManagerViewModel`` search.
public enum SessionSearchScope: String, CaseIterable, Hashable, Sendable {
    /// Filter the loaded session list by title (client-side).
    case titles
    /// Search across persisted message bodies (server-side via the persistence provider).
    case messages
}

/// Manages chat session CRUD operations and the session list.
///
/// Phase 1.1 of the runtime ports refactor split orchestration off into
/// ``SessionListService``: this view model is now a thin `@Observable`
/// `@MainActor` adapter that consumes the service's
/// ``SessionListEvent`` stream and republishes state for SwiftUI. Mutation
/// methods delegate to the service rather than running their own
/// persistence + reload cycle — the `.sessionsLoaded` event coming back from
/// the service is what updates ``sessions``.
@Observable
@MainActor
public final class SessionManagerViewModel {

    /// Default page size used when paginating the session list.
    public static let sessionsPageSize: Int = SessionListService.sessionsPageSize

    /// Default cap on message search results per query.
    public static let messageSearchLimit: Int = SessionListService.messageSearchLimit

    /// Upper bound on sessions resolved when surfacing message-search hits.
    public static let messageSearchSessionResolveCap: Int = SessionListService.messageSearchSessionResolveCap

    // MARK: - Published state

    public private(set) var sessions: [ChatSessionRecord] = []
    public private(set) var hasMoreSessions: Bool = false
    public var activeSession: ChatSessionRecord?

    public var searchScope: SessionSearchScope = .titles
    public var searchQuery: String = ""

    public private(set) var messageHitsBySession: [UUID: [MessageSearchHit]] = [:]
    public private(set) var titleMatches: [ChatSessionRecord] = []
    public private(set) var messageMatchSessions: [ChatSessionRecord] = []

    /// Optional diagnostics sink for non-fatal operational failures.
    public private(set) var diagnostics: DiagnosticsService?

    /// Handle to the fire-and-forget `loadSessions()` Task scheduled by
    /// `configure(persistence:autoLoad:diagnostics:)` when `autoLoad: true`.
    ///
    /// Production bootstrap paths can ignore this. Tests that exercise the
    /// `autoLoad: true` path must `await autoLoadTask?.value` before tearing
    /// down the model container — otherwise the in-flight fetch races
    /// SwiftData teardown and traps with SIGSEGV.
    public private(set) var autoLoadTask: Task<Void, Never>?

    // MARK: - Service wiring

    private(set) var service: SessionListService?

    // The consumer task is held in a `Sendable` box so `deinit`
    // (nonisolated) can cancel it without hopping back to `@MainActor`.
    // Reads/writes from `@MainActor` contexts (`configure`,
    // `startConsumerTask`) go through the same box.
    private let consumerTaskBox = ConsumerTaskBox()

    /// Exposed for `PersistenceGuard` and call sites that need to assert
    /// configuration. Reads through to the underlying service's persistence
    /// reference (or `nil` when unconfigured).
    var persistence: (any SessionStore & MessageStore)? { _persistence }
    private var _persistence: (any SessionStore & MessageStore)?

    public init() {}

    deinit {
        consumerTaskBox.cancel()
    }

    /// Injects the persistence provider. Call once from the view layer.
    ///
    /// `autoLoad` is required (no default) so every call site makes an
    /// explicit choice and the Phase 1.0 behavior change cannot be missed
    /// silently:
    ///
    /// - `autoLoad: true` — schedules `Task { await loadSessions() }` so the
    ///   session list populates immediately after configure. This is the
    ///   pre-Phase-1.0 default behavior. Use it from production bootstrap
    ///   paths (the `BaseChatRuntime` adapter does this for you).
    /// - `autoLoad: false` — the caller is responsible for calling
    ///   `await loadSessions()` (or relying on `SessionListView`'s
    ///   `.task { }` modifier). **Prefer this in tests.** The
    ///   `autoLoad: true` Task is fire-and-forget and will trap SwiftData
    ///   if the model container deallocates before the fetch runs, which
    ///   is the typical test teardown shape. Tests that must exercise the
    ///   `autoLoad: true` path (e.g. covering the `configure(runtime:)`
    ///   adapter) can `await autoLoadTask?.value` to drain the in-flight
    ///   fetch before teardown.
    public func configure(
        persistence: any SessionStore & MessageStore,
        autoLoad: Bool,
        diagnostics: DiagnosticsService? = nil
    ) {
        guard self.service == nil else { return }
        self._persistence = persistence
        self.diagnostics = diagnostics
        let service = SessionListService(persistence: persistence, diagnostics: diagnostics)
        self.service = service
        startConsumerTask(for: service)
        Log.persistence.info("SessionManagerViewModel configured")
        if autoLoad {
            autoLoadTask = Task { [weak self] in
                await self?.loadSessions()
            }
        }
    }

    private func startConsumerTask(for service: SessionListService) {
        // Phase 1.1 has every command isolated on `@MainActor`, so the
        // synchronous sink installed here runs in the same actor hop as the
        // command that produced the event. The adapter's observable state
        // is therefore consistent the moment the command's `await` returns
        // — no yield is required between `await vm.createSession(...)` and
        // the assertion that follows.
        //
        // Phase 1.2 step 5 lifts `InferenceService` off main and the service
        // commands drop their `@MainActor` isolation. At that point the
        // sink path becomes a cross-actor hazard and the adapter switches
        // to consuming `service.events` from the long-lived consumer task
        // below. Until then the consumer task only drains the stream so its
        // unbounded buffer does not grow — `AsyncStream` is single-consumer,
        // so attaching an adapter and a parallel external `for await` over
        // `service.events` would race for the same slot.
        let sink: @Sendable (SessionListEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                self?.apply(event)
            }
        }
        service.setEventSink(sink)

        consumerTaskBox.cancel()
        let task = Task { @MainActor [weak self] in
            for await _ in service.events {
                if self == nil { return }
            }
        }
        consumerTaskBox.set(task)
    }

    /// Mirrors a service event into observable state.
    private func apply(_ event: SessionListEvent) {
        switch event {
        case let .sessionsLoaded(records, hasMore, offset):
            if offset == 0 {
                sessions = records
            } else {
                let existing = Set(sessions.map(\.id))
                let unique = records.filter { !existing.contains($0.id) }
                sessions.append(contentsOf: unique)
            }
            hasMoreSessions = hasMore

        case let .sessionRenamed(id, title):
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].title = title
            }
            if activeSession?.id == id {
                activeSession?.title = title
            }

        case let .sessionDeleted(id):
            if activeSession?.id == id {
                activeSession = nil
            }
            sessions.removeAll { $0.id == id }

        case let .searchResultsChanged(results):
            titleMatches = results.titleMatches
            messageHitsBySession = results.messageHitsBySession
            messageMatchSessions = results.messageMatchSessions

        case let .titleGenerated(id, title):
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].title = title
            }
            if activeSession?.id == id {
                activeSession?.title = title
            }

        case .persistenceFailure:
            // Service has already logged; the adapter has nothing to publish.
            // Surface points (banners, retry affordances) wire onto the same
            // event in a future PR rather than ad-hoc state here.
            break
        }
    }

    // MARK: - Mutating commands

    /// Creates a new session, activates it, and returns it.
    @discardableResult
    public func createSession(title: String = "New Chat") async throws -> ChatSessionRecord {
        let service = try requireService("createSession")
        let record = try await service.createSession(title: title)
        activeSession = record
        return record
    }

    /// Deletes a session and all its messages.
    public func deleteSession(_ session: ChatSessionRecord) async throws {
        let service = try requireService("deleteSession")
        try await service.deleteSession(session.id)
    }

    /// Renames a session.
    public func renameSession(_ session: ChatSessionRecord, title: String) async throws {
        let service = try requireService("renameSession")
        try await service.renameSession(session, title: title)
    }

    // MARK: - AI auto-rename

    /// Generates a concise session title by running a short inference request.
    public func generateTitle(
        from firstMessage: String,
        using inferenceService: InferenceService
    ) async throws -> String? {
        let service = try requireService("generateTitle")
        return try await service.generateTitle(from: firstMessage, using: inferenceService)
    }

    /// Generates an AI title for the session and saves it.
    public func autoRenameSession(
        _ session: ChatSessionRecord,
        firstMessage: String,
        inferenceService: InferenceService
    ) async {
        guard let service else { return }
        await service.autoRenameSession(session, firstMessage: firstMessage, inferenceService: inferenceService)
    }

    /// Auto-generates a session title from the first user message.
    public func autoGenerateTitle(for session: ChatSessionRecord, firstMessage: String) async {
        guard let service else { return }
        await service.autoGenerateTitle(for: session, firstMessage: firstMessage)
    }

    // MARK: - Loading + pagination

    /// Reloads sessions from the persistence provider (page one).
    public func loadSessions() async {
        guard let service else { return }
        await service.loadInitialPage()
    }

    /// Fetches a page of sessions from the persistence provider without
    /// mutating VM state. Tests assert on raw page contents.
    public func fetchSessionsPage(offset: Int, limit: Int) async throws -> [ChatSessionRecord] {
        let service = try requireService("fetchSessionsPage")
        return try await service.fetchPage(offset: offset, limit: limit)
    }

    /// Appends the next page of sessions, if any, to ``sessions``.
    public func loadNextPage() async {
        guard hasMoreSessions, let service else { return }
        let offset = sessions.count
        await service.loadNextPage(offset: offset)
    }

    // MARK: - Search

    /// Computes the visible session list given the current scope and query.
    public var displayedSessions: [ChatSessionRecord] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        switch searchScope {
        case .titles:
            return titleMatches
        case .messages:
            return messageMatchSessions
        }
    }

    /// `true` when an active search produced no results.
    public var hasNoSearchResults: Bool {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch searchScope {
        case .titles:
            return titleMatches.isEmpty
        case .messages:
            return messageMatchSessions.isEmpty
        }
    }

    /// Recomputes ``titleMatches`` against the currently loaded ``sessions``.
    public func runTitleSearch(_ query: String) {
        guard let service else { return }
        service.runTitleSearch(query, against: sessions)
    }

    /// Runs a message-scope search via the persistence provider.
    public func runMessageSearch(_ query: String) async {
        guard let service else {
            messageHitsBySession = [:]
            messageMatchSessions = []
            return
        }
        await service.runMessageSearch(query)
    }

    /// Clears search state and falls back to the unfiltered session list.
    public func clearSearch() {
        searchQuery = ""
        service?.clearSearch()
    }

    // MARK: - Service guard

    private func requireService(
        _ context: @autoclosure () -> String,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) throws -> SessionListService {
        guard let service else {
            let resolved = context()
            Log.persistence.warning(
                "\(resolved, privacy: .public) called before persistence was configured (\(fileID, privacy: .public):\(line, privacy: .public))"
            )
            throw ChatPersistenceError.providerNotConfigured
        }
        return service
    }
}

/// Holds the consumer `Task` so a non-isolated `deinit` can cancel it
/// without hopping back to `@MainActor`. The lock guards the single mutable
/// reference; `Task.cancel()` is itself thread-safe.
private final class ConsumerTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }

    func cancel() {
        lock.lock()
        let current = task
        task = nil
        lock.unlock()
        current?.cancel()
    }
}
