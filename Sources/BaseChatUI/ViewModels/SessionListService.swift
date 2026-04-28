import Foundation
import BaseChatCore
import BaseChatInference

// MARK: - Event surface

/// Sendable events emitted by ``SessionListService``.
///
/// All state transitions surface here rather than being written directly to
/// observable state — the adapter (``SessionManagerViewModel``) subscribes and
/// mirrors them into its published properties.
public enum SessionListEvent: Sendable {
    case sessionsLoaded([ChatSessionRecord], hasMore: Bool)
    case sessionInserted(ChatSessionRecord)
    case sessionRenamed(UUID, title: String)
    case sessionDeleted(UUID)
    case searchResultsChanged(SearchResults)
    case titleGenerated(UUID, title: String)
    case persistenceFailure(any Error)
}

/// Snapshot of search state emitted in `.searchResultsChanged`.
public struct SearchResults: Sendable {
    public let titleMatches: [ChatSessionRecord]
    public let messageHitsBySession: [UUID: [MessageSearchHit]]
    public let messageMatchSessions: [ChatSessionRecord]

    public static let empty = SearchResults(
        titleMatches: [],
        messageHitsBySession: [:],
        messageMatchSessions: []
    )
}

// MARK: - Service

/// Orchestrates session CRUD and search. Plain class — no `@Observable`,
/// no `@MainActor` pin on the type itself.
///
/// Commands are `@MainActor` because `ChatPersistenceProvider` is `@MainActor`-
/// isolated and all callers already run on the main actor. The `async` on
/// public commands is intentional: it signals that commands should be awaited
/// (rather than fire-and-forget) and preserves the shape the plan describes for
/// a future `BaseChatRuntime` target where commands *would* hop off main.
///
/// SPIKE NOTE (isolation seam): Because `ChatPersistenceProvider` is `@MainActor`
/// and sync, moving any of these commands truly off-main would require either
/// (a) making the persistence port async, or (b) wrapping the provider in a
/// dedicated actor. The current shape validates event emission and adapter
/// separation without that infrastructure change. See SPIKE FINDINGS in the PR.
public final class SessionListService: Sendable {

    public let events: AsyncStream<SessionListEvent>
    private let continuation: AsyncStream<SessionListEvent>.Continuation

    // `nonisolated(unsafe)` because the type is `Sendable` but the value is
    // only ever written once (in `configure`) and read only from `@MainActor`
    // contexts. Swift 6 strict concurrency requires the annotation when the
    // stored property is mutated after init outside a concurrency domain.
    nonisolated(unsafe) var _persistence: ChatPersistenceProvider?
    nonisolated(unsafe) var _diagnostics: DiagnosticsService?

    public static let sessionsPageSize: Int = 50
    public static let messageSearchLimit: Int = 100
    public static let messageSearchSessionResolveCap: Int = 10_000

    public init() {
        var cap: AsyncStream<SessionListEvent>.Continuation!
        events = AsyncStream { cap = $0 }
        continuation = cap
    }

    // MARK: - Configuration

    /// Injects the persistence provider. Call once.
    ///
    /// Does NOT emit an initial load — the caller is responsible for calling
    /// `loadInitialPage()` or `reloadSessionsSync()` after wiring up a consumer.
    @MainActor
    public func configure(persistence: ChatPersistenceProvider, diagnostics: DiagnosticsService? = nil) {
        _persistence = persistence
        _diagnostics = diagnostics
    }

    // MARK: - Commands

    /// Creates a new session, persists it, and emits `.sessionInserted` then `.sessionsLoaded`.
    @MainActor
    @discardableResult
    public func createSession(title: String = "New Chat") async throws -> ChatSessionRecord {
        guard let persistence = _persistence else {
            throw ChatPersistenceError.providerNotConfigured
        }
        let record = ChatSessionRecord(title: title)
        try persistence.insertSession(record)
        continuation.yield(.sessionInserted(record))
        reloadSessionsSync()
        return record
    }

    /// Deletes a session and emits `.sessionDeleted` then `.sessionsLoaded`.
    @MainActor
    public func deleteSession(_ id: UUID) async throws {
        guard let persistence = _persistence else {
            throw ChatPersistenceError.providerNotConfigured
        }
        try persistence.deleteSession(id)
        continuation.yield(.sessionDeleted(id))
        reloadSessionsSync()
    }

    /// Renames a session and emits `.sessionRenamed` then `.sessionsLoaded`.
    @MainActor
    public func renameSession(_ id: UUID, to title: String) async throws {
        guard let persistence = _persistence else {
            throw ChatPersistenceError.providerNotConfigured
        }
        let all = try persistence.fetchSessions()
        guard let existing = all.first(where: { $0.id == id }) else {
            throw ChatPersistenceError.sessionNotFound(id)
        }
        var updated = existing
        updated.title = title
        updated.updatedAt = Date()
        try persistence.updateSession(updated)
        continuation.yield(.sessionRenamed(id, title: title))
        reloadSessionsSync()
    }

    /// Reloads page one and emits `.sessionsLoaded`.
    @MainActor
    public func loadInitialPage() async {
        reloadSessionsSync()
    }

    /// Appends the next page if more are available and emits `.sessionsLoaded`.
    ///
    /// Callers pass the current count so the service doesn't need to own a
    /// separate cursor — the adapter owns loaded count as part of observable state.
    @MainActor
    public func loadNextPage(currentCount: Int) async {
        guard let persistence = _persistence else { return }
        do {
            let next = try persistence.fetchSessions(offset: currentCount, limit: Self.sessionsPageSize)
            let hasMore = next.count == Self.sessionsPageSize
            continuation.yield(.sessionsLoaded(next, hasMore: hasMore))
        } catch {
            Log.persistence.error("Failed to load next sessions page: \(error)")
            continuation.yield(.persistenceFailure(error))
        }
    }

    // MARK: - Search

    /// Filters the provided sessions by title and emits `.searchResultsChanged`.
    ///
    /// The adapter passes its own `sessions` array so the service doesn't need
    /// to re-fetch from persistence for a client-side filter.
    public func runTitleSearch(_ query: String, against sessions: [ChatSessionRecord]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            continuation.yield(.searchResultsChanged(.empty))
            return
        }
        let matches = sessions.filter {
            $0.title.range(of: trimmed, options: .caseInsensitive) != nil
        }
        continuation.yield(.searchResultsChanged(SearchResults(
            titleMatches: matches,
            messageHitsBySession: [:],
            messageMatchSessions: []
        )))
    }

    /// Runs a message-scope search via persistence and emits `.searchResultsChanged`.
    @MainActor
    public func runMessageSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let persistence = _persistence else {
            continuation.yield(.searchResultsChanged(.empty))
            return
        }
        do {
            let hits = try persistence.searchMessages(query: trimmed, limit: Self.messageSearchLimit)
            var grouped: [UUID: [MessageSearchHit]] = [:]
            grouped.reserveCapacity(hits.count)
            var orderedSessionIDs: [UUID] = []
            for hit in hits {
                if grouped[hit.sessionID] == nil { orderedSessionIDs.append(hit.sessionID) }
                grouped[hit.sessionID, default: []].append(hit)
            }
            let allSessions = try persistence.fetchSessions(offset: 0, limit: Self.messageSearchSessionResolveCap)
            let byID = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
            let matchSessions = orderedSessionIDs.compactMap { byID[$0] }
            continuation.yield(.searchResultsChanged(SearchResults(
                titleMatches: [],
                messageHitsBySession: grouped,
                messageMatchSessions: matchSessions
            )))
        } catch {
            Log.persistence.error("Message search failed: \(error)")
            continuation.yield(.searchResultsChanged(.empty))
            continuation.yield(.persistenceFailure(error))
        }
    }

    /// Clears all search state and emits `.searchResultsChanged(.empty)`.
    public func clearSearch() {
        continuation.yield(.searchResultsChanged(.empty))
    }

    // MARK: - Title Generation

    /// Generates an AI title for a session and emits `.titleGenerated` on success.
    ///
    /// Emits nothing (but logs) on inference or persistence failure.
    ///
    /// SPIKE NOTE: `InferenceService` is `@Observable @MainActor` so `enqueue`
    /// is also `@MainActor`. The title-generation path doesn't escape main.
    /// In a real `BaseChatRuntime` target the inference API would need an
    /// actor-isolated or `Sendable` surface before this path could leave main.
    @MainActor
    public func autoRenameSession(
        _ session: ChatSessionRecord,
        firstMessage: String,
        inferenceService: InferenceService
    ) async {
        guard session.title == "New Chat" else { return }
        let title: String?
        do {
            title = try await generateTitle(from: firstMessage, using: inferenceService)
        } catch {
            Log.ui.warning("Title generation failed for session \(session.id): \(error.localizedDescription)")
            _diagnostics?.record(.titleGenerationFailed(sessionID: session.id, reason: error.localizedDescription))
            return
        }
        guard let title else { return }
        guard let persistence = _persistence else { return }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try persistence.updateSession(updated)
            continuation.yield(.titleGenerated(session.id, title: title))
            reloadSessionsSync()
        } catch {
            Log.persistence.warning("Failed to persist auto-rename for session \(session.id): \(error.localizedDescription)")
            _diagnostics?.record(.sessionRenamePersistenceFailed(sessionID: session.id, reason: error.localizedDescription))
        }
    }

    /// Truncates the first message to 50 chars and uses it as the session title.
    ///
    /// Fallback for callers without inference. Only applies when the session is
    /// still named "New Chat".
    @MainActor
    public func autoGenerateTitle(for session: ChatSessionRecord, firstMessage: String) {
        guard session.title == "New Chat" else { return }
        let maxLength = 50
        var title = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if title.count > maxLength {
            let truncated = String(title.prefix(maxLength))
            if let lastSpace = truncated.lastIndex(of: " ") {
                title = String(truncated[truncated.startIndex..<lastSpace]) + "..."
            } else {
                title = truncated + "..."
            }
        }
        guard let persistence = _persistence else { return }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try persistence.updateSession(updated)
            continuation.yield(.titleGenerated(session.id, title: title))
            reloadSessionsSync()
        } catch {
            Log.persistence.error("Failed to auto-generate title: \(error)")
        }
    }

    // MARK: - Reload helper

    // Safe to call synchronously because `ChatPersistenceProvider` is sync and
    // `@MainActor`. Every call site is `@MainActor`-isolated.
    @MainActor
    func reloadSessionsSync() {
        guard let persistence = _persistence else { return }
        do {
            let page = try persistence.fetchSessions(offset: 0, limit: Self.sessionsPageSize)
            let hasMore = page.count == Self.sessionsPageSize
            continuation.yield(.sessionsLoaded(page, hasMore: hasMore))
        } catch {
            Log.persistence.error("Failed to reload sessions: \(error)")
            continuation.yield(.sessionsLoaded([], hasMore: false))
            continuation.yield(.persistenceFailure(error))
        }
    }

    // MARK: - Private title generation

    @MainActor
    private func generateTitle(
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
}
