import Foundation
import Observation
import ManifoldRuntime
import ManifoldInference

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

    // MARK: - Published state

    public private(set) var sessions: [ChatSession] = []
    public private(set) var hasMoreSessions: Bool = false
    public var activeSession: ChatSession? {
        didSet {
            // #1464: persist the active-session ID across relaunches so the
            // documented `BuildingAChatUI` bootstrap can restore the previously
            // viewed conversation without each host re-inventing the
            // bookkeeping. The store is injected (see `lastActiveStore`) so
            // `--parallel` test runs do not collide on `UserDefaults.standard`.
            guard oldValue?.id != activeSession?.id else { return }
            lastActiveStore.write(activeSession?.id)
            updatePendingSearchScrollTarget()
        }
    }

    public var searchScope: SessionSearchScope = .titles
    public var searchQuery: String = ""

    public private(set) var messageHitsBySession: [UUID: [MessageSearchHit]] = [:]
    public private(set) var titleMatches: [ChatSession] = []
    public private(set) var messageMatchSessions: [ChatSession] = []

    /// The `messageID` of the most recent match for the currently active
    /// session, when it was activated by tapping a `.messages`-scope search
    /// result (#search-jump-to-message). `nil` for an ordinary session open.
    ///
    /// Set automatically by ``activeSession``'s `didSet` — no dedicated
    /// selection method is required because the sidebar's `List(selection:)`
    /// binding writes ``activeSession`` directly. A coordinating host reads
    /// this via ``consumeSearchScrollTarget(for:)`` after handing the session
    /// to a `ChatViewModel`.
    public private(set) var pendingSearchScrollMessageID: UUID?

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

    /// Bookkeeping for the most recently activated session ID. Used by
    /// ``selectInitialSession()`` on relaunch to prefer the previously
    /// viewed conversation over an arbitrary newest entry. Injected so
    /// `swift test --parallel` does not flake on shared `UserDefaults.standard`.
    private let lastActiveStore: LastActiveSessionStore

    public init(userDefaults: UserDefaults = .standard) {
        self.lastActiveStore = LastActiveSessionStore(defaults: userDefaults)
    }

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
    ///   paths (the `ManifoldRuntime` adapter does this for you).
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
        guard self.service == nil else {
            Log.persistence.warning(
                "SessionManagerViewModel.configure(persistence:) called again after the store was already set; keeping the original store"
            )
            return
        }
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

        case let .sessionPinChanged(id, isPinned):
            // The trailing .sessionsLoaded event carries the re-sorted page
            // so the row moves into its new bucket. Update the local
            // record's flag synchronously so a SwiftUI surface bound to the
            // record's `isPinned` reacts in the same tick rather than
            // waiting on the reload.
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].isPinned = isPinned
                sessions[idx].pinnedAt = isPinned ? Date() : nil
            }
            if activeSession?.id == id {
                activeSession?.isPinned = isPinned
                activeSession?.pinnedAt = isPinned ? Date() : nil
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
    public func createSession(title: String = "New Chat") async throws -> ChatSession {
        let service = try requireService("createSession")
        let record = try await service.createSession(title: title)
        activeSession = record
        return record
    }

    /// Deletes a session and all its messages.
    public func deleteSession(_ session: ChatSession) async throws {
        let service = try requireService("deleteSession")
        try await service.deleteSession(session.id)
    }

    /// Deletes every persisted session and its messages in a single atomic
    /// pass.
    ///
    /// For consumer surfaces like Settings → "Erase All Chats", GDPR-style
    /// purges, and account-reset flows. Issuing `deleteSession(_:)` in a
    /// loop instead is O(N) round-trips, emits N
    /// ``SessionListEvent/sessionDeleted(_:)`` events the SwiftUI list will
    /// animate one-by-one, and races mid-iteration mutations (a new session
    /// created from another scene-phase path can survive the loop). This
    /// call lowers to a single ``SessionStore/deleteAll()`` transaction at
    /// the persistence layer and emits one terminal
    /// `.sessionsLoaded(records: [], …)` event — observable state settles
    /// to an empty list in a single update.
    ///
    /// Also clears ``activeSession`` so a surface re-entering the session
    /// list after the purge does not retain a stale pointer.
    ///
    /// - Throws: ``ChatPersistenceError/providerNotConfigured`` if
    ///   persistence was never injected, or any storage error raised by the
    ///   adapter's `deleteAll()`. On throw, observable state is unchanged.
    public func deleteAllSessions() async throws {
        let service = try requireService("deleteAllSessions")
        try await service.deleteAllSessions()
        activeSession = nil
    }

    /// Renames a session.
    public func renameSession(_ session: ChatSession, title: String) async throws {
        let service = try requireService("renameSession")
        try await service.renameSession(session, title: title)
    }

    /// Pins a session to the top of the list (#1301).
    ///
    /// Consumer apps no longer need to maintain their own `Set<UUID>` of
    /// pinned IDs in `UserDefaults` — pinned state lives on the session
    /// record and survives reload, app-group reads, and any future
    /// export/sync. Idempotent: pinning an already-pinned session is a
    /// no-op (no `pinnedAt` reshuffle, no event).
    public func pinSession(_ session: ChatSession) async throws {
        let service = try requireService("pinSession")
        try await service.pinSession(session)
    }

    /// Unpins a session. Idempotent — no-op when the session is not pinned.
    public func unpinSession(_ session: ChatSession) async throws {
        let service = try requireService("unpinSession")
        try await service.unpinSession(session)
    }

    /// Toggles a session's pinned state (#1300).
    ///
    /// Convenience over ``pinSession(_:)`` / ``unpinSession(_:)`` for the common
    /// "pin/unpin button" affordance: a pinned session unpins, an unpinned one
    /// pins. The decision reads `session.isPinned` at call time, so pass the
    /// freshest record (e.g. the one in ``sessions``) to avoid acting on stale
    /// state. Both underlying calls are idempotent.
    public func togglePin(_ session: ChatSession) async throws {
        if session.isPinned {
            try await unpinSession(session)
        } else {
            try await pinSession(session)
        }
    }

    /// Currently loaded pinned sessions, in `pinnedAt`-descending order
    /// (most recently pinned first). Derived from ``sessions`` so it
    /// stays in sync with the page state without an extra fetch.
    ///
    /// Note: this is the *currently loaded* slice — if pagination has not
    /// drained every pinned record into ``sessions``, callers that need an
    /// exhaustive list should fetch a sufficiently large page. With the
    /// pinned-first sort order applied by the persistence layer, page one
    /// is guaranteed to surface every pin in any realistic configuration
    /// (page size 50; pinning >50 sessions is not a real workflow).
    public var pinnedSessions: [ChatSession] {
        sessions
            .filter(\.isPinned)
            .sorted { lhs, rhs in
                // Records with nil pinnedAt are degenerate (isPinned true
                // without a stamp); place them last so well-formed rows
                // dominate the visible order.
                switch (lhs.pinnedAt, rhs.pinnedAt) {
                case let (l?, r?): return l > r
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return lhs.updatedAt > rhs.updatedAt
                }
            }
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
        _ session: ChatSession,
        firstMessage: String,
        inferenceService: InferenceService
    ) async {
        guard let service else { return }
        await service.autoRenameSession(session, firstMessage: firstMessage, inferenceService: inferenceService)
    }

    /// Auto-generates a session title from the first user message.
    public func autoGenerateTitle(for session: ChatSession, firstMessage: String) async {
        guard let service else { return }
        await service.autoGenerateTitle(for: session, firstMessage: firstMessage)
    }

    // MARK: - Branch origin

    /// Forwards to ``SessionListService/branchOriginTitle(for:)`` — the seam
    /// `ChatViewModel.resolveBranchOriginTitle` wires to (see
    /// `ManifoldKit/QuickStart.swift`) so `ManifoldUI`'s `BranchOriginChipView`
    /// gets a display title without `ChatViewModel` depending on
    /// `ManifoldRuntime`'s `SessionListService` directly.
    public func branchOriginTitle(for session: ChatSession) async -> String? {
        guard let service else { return nil }
        return await service.branchOriginTitle(for: session)
    }

    // MARK: - Loading + pagination

    /// Reloads sessions from the persistence provider (page one).
    public func loadSessions() async {
        guard let service else { return }
        await service.loadInitialPage()
    }

    /// Fetches a page of sessions from the persistence provider without
    /// mutating VM state. Tests assert on raw page contents.
    public func fetchSessionsPage(offset: Int, limit: Int) async throws -> [ChatSession] {
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
    public var displayedSessions: [ChatSession] {
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
    ///
    /// Resets ``searchScope`` to `.titles` so the scope tab snaps back when
    /// the user clears a query entered while on the Messages tab. Also drops
    /// any pending search-jump target so a later ordinary session open does
    /// not incorrectly trigger a scroll.
    public func clearSearch() {
        searchQuery = ""
        searchScope = .titles
        pendingSearchScrollMessageID = nil
        service?.clearSearch()
    }

    /// Returns (and clears) the pending search-jump target recorded by
    /// ``activeSession``'s selection, if `sessionID` matches the currently
    /// active session.
    ///
    /// Call this once, immediately before switching a `ChatViewModel` to
    /// `sessionID`, and forward the result to
    /// `ChatViewModel.switchToSession(_:scrollToMessageID:)`. Consuming
    /// clears the target so re-activating the same session later (an
    /// ordinary open) does not re-trigger the jump.
    public func consumeSearchScrollTarget(for sessionID: UUID) -> UUID? {
        guard let pendingSearchScrollMessageID, activeSession?.id == sessionID else { return nil }
        self.pendingSearchScrollMessageID = nil
        return pendingSearchScrollMessageID
    }

    /// Recomputes ``pendingSearchScrollMessageID`` whenever ``activeSession``
    /// changes. Only sets a target when the selection happened while an
    /// active `.messages`-scope search is showing a hit for the newly
    /// activated session — an ordinary sidebar tap (scope `.titles`, or no
    /// query) always clears it.
    private func updatePendingSearchScrollTarget() {
        guard searchScope == .messages,
              !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sessionID = activeSession?.id,
              let mostRecentHit = messageHitsBySession[sessionID]?.first else {
            pendingSearchScrollMessageID = nil
            return
        }
        pendingSearchScrollMessageID = mostRecentHit.messageID
    }

    // MARK: - Export

    /// Exports a session's full message history to a shareable file via the
    /// rich file-based export pipeline (``ConversationExporter``).
    ///
    /// Reads through ``MessageStore/fetchMessages(for:)`` on the injected
    /// persistence provider rather than requiring a SwiftData
    /// `PersistedChatSession` handle — this view model only ever holds the
    /// storage-agnostic ``ChatSession`` snapshot, so this overload is the one
    /// that fits without widening the VM's dependency surface.
    ///
    /// - Parameters:
    ///   - session: The session to export. Does not need to be ``activeSession``.
    ///   - format: The serializer — ``MarkdownExportFormat``,
    ///     ``PlainTextExportFormat``, ``JSONLExportFormat``, or a custom
    ///     ``ConversationExportFormat``.
    ///   - directory: Override for the write destination. Defaults to a
    ///     unique subdirectory of the system temp directory (see
    ///     ``ConversationExporter``).
    /// - Returns: A ``ShareableFile`` suitable for `ShareLink`.
    /// - Throws: ``ChatPersistenceError/providerNotConfigured`` if persistence
    ///   was never injected, or any error raised while fetching messages,
    ///   serializing, or writing the file.
    public func exportSession(
        _ session: ChatSession,
        format: ConversationExportFormat,
        directory: URL? = nil
    ) async throws -> ShareableFile {
        guard let persistence = _persistence else {
            Log.persistence.warning("exportSession called before persistence was configured")
            throw ChatPersistenceError.providerNotConfigured
        }
        let messages = try await persistence.fetchMessages(for: session.id)
        return try ConversationExporter.export(
            session: session,
            messages: messages,
            format: format,
            directory: directory
        )
    }

    // MARK: - Initial-session selection (#1464)

    /// Picks the session a relaunching host should restore as ``activeSession``.
    ///
    /// Selection policy (first match wins):
    /// 1. The previously active session (persisted across relaunches), when it
    ///    still exists in ``sessions``.
    /// 2. The most recent session whose message count is greater than zero —
    ///    i.e. prefer real conversations over a stray empty `"New Chat"` row
    ///    that may have been minted by a previous launch's bootstrap.
    /// 3. The first session in ``sessions`` (already sorted most-recent-first
    ///    by the persistence layer).
    /// 4. `nil` when ``sessions`` is empty. The host decides whether to mint a
    ///    fresh blank session at that point — this helper deliberately does
    ///    not create one. Creating a session pre-restore is what produced the
    ///    duplicate-blank-row behaviour in #1464.
    ///
    /// Call this **after** ``configureAndLoad(bootstrap:)`` (or any other path
    /// that resolves the initial session page) and use the returned record to
    /// drive both ``activeSession`` and the chat view model's
    /// `switchToSession(_:)`. The act of assigning the returned record to
    /// ``activeSession`` records it as the new last-active session, so the
    /// next relaunch will prefer the same row.
    ///
    /// - Returns: The session to restore, or `nil` when there are no sessions.
    public func selectInitialSession() async -> ChatSession? {
        guard !sessions.isEmpty else { return nil }

        // 1. Previously active session, if it still exists.
        if let lastActiveID = lastActiveStore.read(),
           let restored = sessions.first(where: { $0.id == lastActiveID }) {
            return restored
        }

        // 2. Most recent non-empty session. We probe message counts via the
        //    MessageStore rather than a session field because the record type
        //    is storage-agnostic and does not carry a counter. The probe is
        //    bounded to the current page — restoring a session that lives on
        //    a deeper page is not worth a full fetch on the cold path.
        if let messages = _persistence {
            for session in sessions {
                do {
                    let recent = try await messages.fetchRecentMessages(for: session.id, limit: 1)
                    if !recent.isEmpty { return session }
                } catch {
                    Log.persistence.warning(
                        "selectInitialSession: message probe failed for \(session.id, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        // 3. Fallback: first session (most recent by updatedAt).
        return sessions.first
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

/// Persists the most recently activated session ID across launches so the
/// SwiftUI bootstrap can prefer it on relaunch (#1464). `UserDefaults` is
/// injected so test runs don't collide on `UserDefaults.standard`; see the
/// `userDefaults:` parameter on ``SessionManagerViewModel/init(userDefaults:)``.
private struct LastActiveSessionStore {
    static let defaultsKey = "manifoldkit.sessionManager.lastActiveSessionID"
    let defaults: UserDefaults

    func read() -> UUID? {
        guard let raw = defaults.string(forKey: Self.defaultsKey) else { return nil }
        return UUID(uuidString: raw)
    }

    func write(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
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
