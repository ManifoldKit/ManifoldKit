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

/// Manages chat session CRUD operations and the session list.
@Observable
@MainActor
public final class SessionManagerViewModel {

    /// Default page size used when paginating the session list.
    public static let sessionsPageSize: Int = 50

    /// Default cap on message search results per query.
    public static let messageSearchLimit: Int = 100

    /// Upper bound on sessions resolved when surfacing message-search hits.
    /// Sessions beyond this count cannot be surfaced as a "matching session"
    /// row even if their messages match — in practice the cap is well above
    /// any realistic single-user history.
    public static let messageSearchSessionResolveCap: Int = 10_000

    /// All currently loaded sessions, sorted by most recently updated.
    ///
    /// Populated incrementally a page at a time. ``loadSessions()`` resets to
    /// the first page; ``loadNextPage()`` appends the next page. There is no
    /// path that fetches every session at once — the sidebar is paginated end
    /// to end so it stays responsive past 1000+ sessions.
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

    /// Message-search hits indexed by session ID. Empty when scope is titles
    /// or query is empty.
    public private(set) var messageHitsBySession: [UUID: [MessageSearchHit]] = [:]

    /// Sessions matching the current title-scope query. Empty when scope is
    /// messages or query is empty.
    public private(set) var titleMatches: [ChatSessionRecord] = []

    /// Sessions surfaced by the most recent message-scope search, ordered by
    /// their most recent matching message.
    public private(set) var messageMatchSessions: [ChatSessionRecord] = []

    private(set) var persistence: ChatPersistenceProvider?

    /// Optional diagnostics sink for non-fatal operational failures
    /// (e.g., auto-rename inference errors). Inject via `configure` so
    /// existing call sites that do not care about diagnostics keep working.
    public private(set) var diagnostics: DiagnosticsService?

    public init() {}

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
    ///   `.task { }` modifier). **Always use this in tests.** The
    ///   `autoLoad: true` Task is fire-and-forget and will trap SwiftData
    ///   if the model container deallocates before the fetch runs, which
    ///   is the typical test teardown shape.
    public func configure(
        persistence: ChatPersistenceProvider,
        autoLoad: Bool,
        diagnostics: DiagnosticsService? = nil
    ) {
        guard self.persistence == nil else { return }
        self.persistence = persistence
        self.diagnostics = diagnostics
        Log.persistence.info("SessionManagerViewModel configured")
        if autoLoad {
            Task { await loadSessions() }
        }
    }

    /// Creates a new session, inserts it, activates it, and returns it.
    ///
    /// Setting `activeSession` to the new record ensures that
    /// `onChange(of: sessionManager.activeSession)` fires in the host view so
    /// `ChatViewModel.switchToSession(_:)` is called immediately. Without this,
    /// callers that rely on the binding (e.g. `SessionListView`'s `List(selection:)`)
    /// would leave the chat detail in a "No session selected" state until the user
    /// manually tapped a row.
    @discardableResult
    public func createSession(title: String = "New Chat") async throws -> ChatSessionRecord {
        let persistence = try requirePersistence("createSession")
        let record = ChatSessionRecord(title: title)
        try await persistence.insertSession(record)
        await loadSessions()
        activeSession = record
        return record
    }

    /// Deletes a session and all its messages.
    public func deleteSession(_ session: ChatSessionRecord) async throws {
        let persistence = try requirePersistence("deleteSession")
        try await persistence.deleteSession(session.id)

        if activeSession?.id == session.id {
            activeSession = nil
        }

        await loadSessions()
    }

    /// Renames a session.
    public func renameSession(_ session: ChatSessionRecord, title: String) async throws {
        let persistence = try requirePersistence("renameSession")
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        try await persistence.updateSession(updated)
        await loadSessions()
    }

    // MARK: - AI Auto-Rename

    /// Generates a concise session title by running a short inference request.
    ///
    /// Returns `nil` when the model produced an empty response. Throws the
    /// underlying inference error on failure so callers can surface it to
    /// `DiagnosticsService` instead of silently dropping it.
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
            if case .token(let text) = event {
                result += text
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 50 ? String(trimmed.prefix(50)) : trimmed
    }

    /// Generates an AI title for the session and saves it.
    ///
    /// Only renames sessions that are still named "New Chat". Failures
    /// fall back to the existing title but are recorded on
    /// `DiagnosticsService` so they can be surfaced to the user.
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
            diagnostics?.record(.titleGenerationFailed(sessionID: session.id, reason: error.localizedDescription))
            return
        }
        guard let title else { return }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try await persistence?.updateSession(updated)
        } catch {
            Log.persistence.warning("Failed to persist auto-rename for session \(session.id): \(error.localizedDescription)")
            // Persistence failure is a distinct category from inference
            // failure — different remediation (disk/store health vs.
            // backend availability), so we surface it as its own case.
            diagnostics?.record(.sessionRenamePersistenceFailed(sessionID: session.id, reason: error.localizedDescription))
            return
        }
        await loadSessions()
    }

    /// Auto-generates a session title from the first user message.
    /// Only applies if the current title is "New Chat".
    public func autoGenerateTitle(for session: ChatSessionRecord, firstMessage: String) async {
        guard session.title == "New Chat" else { return }

        let maxLength = 50
        var title = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        if title.count > maxLength {
            let truncated = String(title.prefix(maxLength))
            if let lastSpace = truncated.lastIndex(of: " ") {
                title = String(truncated[truncated.startIndex..<lastSpace]) + "..."
            } else {
                title = truncated + "..."
            }
        }

        guard !title.isEmpty else { return }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try await persistence?.updateSession(updated)
        } catch {
            Log.persistence.error("Failed to auto-generate title: \(error)")
        }
        await loadSessions()
    }

    /// Reloads sessions from the persistence provider.
    ///
    /// Resets pagination and loads the first page. Mutations elsewhere in the
    /// VM (create/delete/rename) call this to refresh the list — the caller's
    /// expectation is "show me the freshest top of the list", which page 1
    /// always satisfies.
    public func loadSessions() async {
        guard let persistence else { return }

        do {
            let firstPage = try await persistence.fetchSessions(offset: 0, limit: Self.sessionsPageSize)
            sessions = firstPage
            hasMoreSessions = firstPage.count == Self.sessionsPageSize
        } catch {
            Log.persistence.error("Failed to load sessions: \(error)")
            sessions = []
            hasMoreSessions = false
        }
    }

    // MARK: - Pagination

    /// Fetches a page of sessions from the persistence provider.
    ///
    /// Used by ``SessionListView`` to drive incremental loading as the user
    /// scrolls. Caller is responsible for appending the result to
    /// ``sessions``; this method does not mutate VM state directly so tests
    /// can assert on raw page contents.
    public func fetchSessionsPage(offset: Int, limit: Int) async throws -> [ChatSessionRecord] {
        let persistence = try requirePersistence("fetchSessionsPage")
        return try await persistence.fetchSessions(offset: offset, limit: limit)
    }

    /// Appends the next page of sessions, if any, to ``sessions``.
    ///
    /// No-op when no more pages are available, when a search is active, or
    /// when persistence is unconfigured.
    public func loadNextPage() async {
        guard hasMoreSessions, persistence != nil else { return }
        let offset = sessions.count
        do {
            let next = try await fetchSessionsPage(offset: offset, limit: Self.sessionsPageSize)
            // Defensive against duplicates if a concurrent insert raced the
            // page boundary — keys are session IDs, so the dedupe is cheap.
            let existing = Set(sessions.map(\.id))
            let unique = next.filter { !existing.contains($0.id) }
            sessions.append(contentsOf: unique)
            hasMoreSessions = next.count == Self.sessionsPageSize
        } catch {
            Log.persistence.error("Failed to load next sessions page: \(error)")
            hasMoreSessions = false
        }
    }

    // MARK: - Search

    /// Computes the visible session list given the current scope and query.
    ///
    /// Returns the unfiltered ``sessions`` list when no search is active.
    /// Title scope filters in-memory; message scope returns sessions surfaced
    /// by the most recent ``runMessageSearch(_:)`` call.
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            titleMatches = []
            return
        }
        titleMatches = sessions.filter {
            $0.title.range(of: trimmed, options: .caseInsensitive) != nil
        }
    }

    /// Runs a message-scope search via the persistence provider.
    ///
    /// Populates ``messageHitsBySession`` and ``messageMatchSessions``. The
    /// result list is ordered by hit recency (most recent matching message
    /// first), matching the rest of the sidebar's recency-first ordering.
    public func runMessageSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let persistence else {
            messageHitsBySession = [:]
            messageMatchSessions = []
            return
        }

        do {
            let hits = try await persistence.searchMessages(query: trimmed, limit: Self.messageSearchLimit)
            var grouped: [UUID: [MessageSearchHit]] = [:]
            grouped.reserveCapacity(hits.count)
            // Preserve the first occurrence of each sessionID to keep
            // recency ordering — `hits` is already newest-first.
            var orderedSessionIDs: [UUID] = []
            for hit in hits {
                if grouped[hit.sessionID] == nil {
                    orderedSessionIDs.append(hit.sessionID)
                }
                grouped[hit.sessionID, default: []].append(hit)
            }
            messageHitsBySession = grouped

            // Resolve sessions for the surfaced IDs. We fetch up to
            // `messageSearchSessionResolveCap` sessions so a hit in an
            // unloaded page still gets its session row rendered — otherwise
            // message search would silently miss matches deep in history.
            let allSessions = try await persistence.fetchSessions(
                offset: 0,
                limit: Self.messageSearchSessionResolveCap
            )
            let byID = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
            messageMatchSessions = orderedSessionIDs.compactMap { byID[$0] }
        } catch {
            Log.persistence.error("Message search failed: \(error)")
            messageHitsBySession = [:]
            messageMatchSessions = []
        }
    }

    /// Clears search state and falls back to the unfiltered session list.
    public func clearSearch() {
        searchQuery = ""
        titleMatches = []
        messageHitsBySession = [:]
        messageMatchSessions = []
    }
}
