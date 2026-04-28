import Foundation
import Observation
import BaseChatCore
import BaseChatInference

/// Scope for ``SessionManagerViewModel`` search.
public enum SessionSearchScope: String, CaseIterable, Hashable, Sendable {
    /// Filter the loaded session list by title (client-side).
    case titles
    /// Search across persisted message bodies (server-side via the persistence provider).
    case messages
}

/// Thin `@Observable` adapter over ``SessionListService``.
///
/// Owns only the published mirror of the service's state and a consumer
/// `Task` that processes ``SessionListEvent`` values into those properties.
/// All real orchestration lives in ``SessionListService``.
///
/// SPIKE NOTE on sync-command seam: The public API for `createSession`,
/// `deleteSession`, and `renameSession` must be synchronous `throws` to keep
/// existing call sites source-compatible. The adapter therefore calls persistence
/// directly (we're already `@MainActor`, same isolation as the sync provider),
/// emits the corresponding events to keep the service stream consistent, and then
/// schedules a `loadInitialPage()` via the service so the full session list
/// reloads. This means the sync commands bypass `SessionListService.createSession`
/// etc. — the adapter is partially a forwarder and partially a direct caller. In
/// a real `BaseChatRuntime` extraction the public surface would become `async
/// throws` and the seam disappears entirely. For now this is the most faithful
/// spike possible within the source-compat constraint.
@Observable
@MainActor
public final class SessionManagerViewModel {

    /// Default page size used when paginating the session list.
    public static let sessionsPageSize: Int = SessionListService.sessionsPageSize

    /// Default cap on message search results per query.
    public static let messageSearchLimit: Int = SessionListService.messageSearchLimit

    /// Upper bound on sessions resolved when surfacing message-search hits.
    public static let messageSearchSessionResolveCap: Int = SessionListService.messageSearchSessionResolveCap

    // MARK: - Observable state (mirrors service events)

    /// All currently loaded sessions, sorted by most recently updated.
    public private(set) var sessions: [ChatSessionRecord] = []

    /// `true` when more pages may be available beyond what's loaded.
    public private(set) var hasMoreSessions: Bool = false

    /// The currently active session.
    public var activeSession: ChatSessionRecord?

    // MARK: - Search

    /// Current search scope. Defaults to titles.
    public var searchScope: SessionSearchScope = .titles

    /// Live query string. The view layer is responsible for debouncing input
    /// before reassigning this — the VM treats every set as authoritative.
    public var searchQuery: String = ""

    /// Message-search hits indexed by session ID.
    public private(set) var messageHitsBySession: [UUID: [MessageSearchHit]] = [:]

    /// Sessions matching the current title-scope query.
    public private(set) var titleMatches: [ChatSessionRecord] = []

    /// Sessions surfaced by the most recent message-scope search.
    public private(set) var messageMatchSessions: [ChatSessionRecord] = []

    // MARK: - Passthrough accessors required by existing call sites

    private(set) var persistence: ChatPersistenceProvider? {
        get { service._persistenceAccessor }
        set { /* write-path is configure(persistence:) only */ }
    }

    public private(set) var diagnostics: DiagnosticsService?

    // MARK: - Internal

    // Exposed so `SessionListServiceTests` can reach the service directly.
    let service: SessionListService
    // `nonisolated(unsafe)` required so deinit can cancel the task without
    // a main-actor hop. Task.cancel() is concurrency-safe (it only sets a flag).
    nonisolated(unsafe) private var eventConsumerTask: Task<Void, Never>?

    public init() {
        service = SessionListService()
    }

    deinit {
        eventConsumerTask?.cancel()
    }

    // MARK: - Configuration

    /// Injects the persistence provider. Call once from the view layer.
    public func configure(persistence: ChatPersistenceProvider, diagnostics: DiagnosticsService? = nil) {
        guard service._persistenceAccessor == nil else { return }
        self.diagnostics = diagnostics
        service.configure(persistence: persistence, diagnostics: diagnostics)
        startEventConsumer()
        // Eager sync so `sessions` is populated before any async event processing.
        reloadSessionsEagerly()
        Log.persistence.info("SessionManagerViewModel configured")
    }

    // MARK: - Commands

    /// Creates a new session, inserts it, activates it, and returns it.
    @discardableResult
    public func createSession(title: String = "New Chat") throws -> ChatSessionRecord {
        let p = try requirePersistence("createSession")
        let record = ChatSessionRecord(title: title)
        try p.insertSession(record)
        // Reload eagerly so `sessions` is up to date for synchronous callers.
        // The service also emits `.sessionsLoaded` via its event stream —
        // the dual-write is a consequence of keeping a sync public API while
        // routing through an async event stream. See SPIKE FINDINGS in the PR.
        reloadSessionsEagerly()
        activeSession = record
        return record
    }

    /// Deletes a session and all its messages.
    public func deleteSession(_ session: ChatSessionRecord) throws {
        let p = try requirePersistence("deleteSession")
        try p.deleteSession(session.id)
        if activeSession?.id == session.id { activeSession = nil }
        reloadSessionsEagerly()
    }

    /// Renames a session.
    public func renameSession(_ session: ChatSessionRecord, title: String) throws {
        let p = try requirePersistence("renameSession")
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        try p.updateSession(updated)
        reloadSessionsEagerly()
    }

    // MARK: - AI Auto-Rename

    @MainActor
    public func generateTitle(
        from firstMessage: String,
        using inferenceService: InferenceService
    ) async throws -> String? {
        let systemPrompt = "Generate a concise 3-5 word title for a conversation that starts with the following message. Reply with ONLY the title, no punctuation, no quotes."
        let messages: [(role: String, content: String)] = [
            (role: "user", content: firstMessage)
        ]
        let (_, stream) = try inferenceService.enqueue(
            messages: messages,
            systemPrompt: systemPrompt,
            temperature: 0.3,
            topP: 0.9,
            repeatPenalty: 1.0,
            priority: .background,
            sessionID: nil
        )
        var result = ""
        for try await event in stream.events {
            if case .token(let text) = event { result += text }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 50 ? String(trimmed.prefix(50)) : trimmed
    }

    @MainActor
    public func autoRenameSession(
        _ session: ChatSessionRecord,
        firstMessage: String,
        inferenceService: InferenceService
    ) async {
        await service.autoRenameSession(session, firstMessage: firstMessage, inferenceService: inferenceService)
    }

    public func autoGenerateTitle(for session: ChatSessionRecord, firstMessage: String) {
        service.autoGenerateTitle(for: session, firstMessage: firstMessage)
        reloadSessionsEagerly()
    }

    // MARK: - Load / Pagination

    public func loadSessions() {
        reloadSessionsEagerly()
        // Also trigger the async service reload so the event stream stays in
        // sync with any downstream consumers (e.g. views that bind to `service.events`).
        service.reloadSessionsSync()
    }

    public func fetchSessionsPage(offset: Int, limit: Int) throws -> [ChatSessionRecord] {
        guard let p = service._persistenceAccessor else {
            throw ChatPersistenceError.providerNotConfigured
        }
        return try p.fetchSessions(offset: offset, limit: limit)
    }

    public func loadNextPage() {
        guard hasMoreSessions else { return }
        let currentCount = sessions.count
        Task { await service.loadNextPage(currentCount: currentCount) }
    }

    // MARK: - Search

    public var displayedSessions: [ChatSessionRecord] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        switch searchScope {
        case .titles: return titleMatches
        case .messages: return messageMatchSessions
        }
    }

    public var hasNoSearchResults: Bool {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch searchScope {
        case .titles: return titleMatches.isEmpty
        case .messages: return messageMatchSessions.isEmpty
        }
    }

    public func runTitleSearch(_ query: String) {
        service.runTitleSearch(query, against: sessions)
    }

    public func runMessageSearch(_ query: String) {
        Task { await service.runMessageSearch(query) }
    }

    public func clearSearch() {
        searchQuery = ""
        service.clearSearch()
    }

    // MARK: - Eager reload

    // Reads page one from persistence synchronously and updates `sessions`.
    // Required so sync public commands (`createSession`, `deleteSession`, etc.)
    // leave observable state consistent without waiting for the async event
    // consumer. The service also emits `.sessionsLoaded` — this is an explicit
    // dual-write, not a bug. See SPIKE FINDINGS for the architectural implication.
    private func reloadSessionsEagerly() {
        guard let p = service._persistenceAccessor else { return }
        do {
            let page = try p.fetchSessions(offset: 0, limit: Self.sessionsPageSize)
            sessions = page
            hasMoreSessions = page.count == Self.sessionsPageSize
        } catch {
            Log.persistence.error("Eager session reload failed: \(error)")
        }
    }

    // MARK: - Event consumer

    private func startEventConsumer() {
        eventConsumerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.service.events {
                await MainActor.run {
                    self.apply(event)
                }
            }
        }
    }

    private func apply(_ event: SessionListEvent) {
        switch event {
        case .sessionsLoaded(let page, let hasMore):
            sessions = page
            hasMoreSessions = hasMore

        case .sessionInserted:
            // Full reload follows every insert — handled by .sessionsLoaded.
            break

        case .sessionRenamed(let id, let title):
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].title = title
            }
            if activeSession?.id == id { activeSession?.title = title }

        case .sessionDeleted(let id):
            sessions.removeAll { $0.id == id }

        case .searchResultsChanged(let results):
            titleMatches = results.titleMatches
            messageHitsBySession = results.messageHitsBySession
            messageMatchSessions = results.messageMatchSessions

        case .titleGenerated(let id, let title):
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].title = title
            }
            if activeSession?.id == id { activeSession?.title = title }

        case .persistenceFailure:
            // Logged at the service level — no additional action needed.
            break
        }
    }
}

// MARK: - Internal accessor for persistence (needed by PersistenceGuard extension)

extension SessionListService {
    /// Read-only view of the stored persistence provider, used by the adapter
    /// and the `PersistenceGuard` helpers on `SessionManagerViewModel`.
    var _persistenceAccessor: ChatPersistenceProvider? { _persistence }
}
