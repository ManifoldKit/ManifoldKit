import Foundation
import ManifoldInference

// MARK: - Event surface
//
// The service emits state transitions as events; the adapter
// (`SessionManagerViewModel`) consumes them and re-publishes for SwiftUI.
//
// `.sessionInserted` from the Phase 0 spike (#878) was always paired with a
// reload; it is collapsed into `.sessionsLoaded`. Adapters that need the new
// record's identity get it from the `createSession(...)` return value.
//
// `.titleGenerated` carries both the session id and the resolved title so
// the adapter does not need to re-fetch persistence to update its slot for
// the renamed session — the subsequent `.sessionsLoaded` carries the full
// page, but `.titleGenerated` lets observers react to the rename
// independently (e.g., to surface a "renamed!" affordance).
//
// Adding cases later is allowed; renaming or removing is a coordinated
// breaking change with downstream consumers.

/// Events emitted by ``SessionListService``.
public enum SessionListEvent: Sendable {
    /// A page of sessions was loaded. Adapters either replace (`offset == 0`)
    /// or append (`offset > 0`) based on the carried offset.
    case sessionsLoaded([ChatSession], hasMore: Bool, offset: Int)

    /// A session's title was changed (manual rename or auto-rename).
    case sessionRenamed(UUID, title: String)

    /// A session was deleted.
    case sessionDeleted(UUID)

    /// Search results changed. The full snapshot replaces previous state.
    case searchResultsChanged(SearchResults)

    /// An AI title was generated and persisted for a session.
    case titleGenerated(UUID, title: String)

    /// A session's pinned state changed. Carries the resolved boolean so
    /// observers can update sort/grouping affordances without re-fetching the
    /// page — the subsequent `.sessionsLoaded` carries the full re-sorted
    /// list, but `.sessionPinChanged` lets surfaces animate the move
    /// independently.
    case sessionPinChanged(UUID, isPinned: Bool)

    /// A persistence operation failed in a non-throwing path. Throwing
    /// commands surface their error directly to the caller; this case carries
    /// errors that occur inside event-driven loaders (initial load, next-page,
    /// message search) where the caller has already returned.
    case persistenceFailure(any Error)
}

/// Snapshot of search state emitted in ``SessionListEvent/searchResultsChanged(_:)``.
public struct SearchResults: Sendable {
    public let titleMatches: [ChatSession]
    public let messageHitsBySession: [UUID: [MessageSearchHit]]
    public let messageMatchSessions: [ChatSession]

    public init(
        titleMatches: [ChatSession],
        messageHitsBySession: [UUID: [MessageSearchHit]],
        messageMatchSessions: [ChatSession]
    ) {
        self.titleMatches = titleMatches
        self.messageHitsBySession = messageHitsBySession
        self.messageMatchSessions = messageMatchSessions
    }

    public static let empty = SearchResults(
        titleMatches: [],
        messageHitsBySession: [:],
        messageMatchSessions: []
    )
}

// MARK: - Service

/// Owns session-list orchestration: CRUD, search, pagination, title generation.
///
/// Plain `final class` — not `@Observable`, not `@MainActor`-pinned at the
/// type level. Internal state is `private`; all external state changes go out
/// as events on ``events``. Commands are `async throws`.
///
/// `SessionStore`, `DiagnosticsService`, and `InferenceService` are
/// `@MainActor`-isolated `Sendable` references. The service holds them as
/// `let` references injected at init and hops to `@MainActor` on demand
/// inside command bodies. This keeps `SessionListService` itself off the
/// main actor while preserving the actor isolation the underlying ports
/// require — and removes the `nonisolated(unsafe) var _persistence` smell
/// the Phase 0 spike (#878) flagged.
///
/// Widened to `package` when moved to `ManifoldRuntime` so `ManifoldUI`
/// (a sibling package target) can continue to use it without making it public.
package final class SessionListService: Sendable {

    /// Default page size used when paginating the session list.
    package static let sessionsPageSize: Int = 50

    /// Default cap on message search results per query.
    package static let messageSearchLimit: Int = 100

    /// Async stream of state transitions. The adapter
    /// (`SessionManagerViewModel`) installs a synchronous sink via
    /// ``setEventSink(_:)`` so state changes land in observable state in the
    /// same actor hop as the command that produced them; the adapter also
    /// runs a long-lived `Task` that drains this stream so its unbounded
    /// buffer does not grow.
    ///
    /// `AsyncStream` is single-consumer by design: tests that drive the
    /// service directly (no adapter attached) iterate this stream
    /// themselves. Once an adapter is attached, the adapter's drain task
    /// owns the consumer slot and external `for await` loops over
    /// `service.events` will not observe events. Either drive the service
    /// without an adapter or install your own sink via ``setEventSink(_:)``.
    ///
    /// Phase 1.2 will move the runtime off `@MainActor`; at that point the
    /// adapter switches to consuming this stream from its drain `Task` (the
    /// sink path becomes a cross-actor hazard) without changing this surface.
    package let events: AsyncStream<SessionListEvent>
    private let continuation: AsyncStream<SessionListEvent>.Continuation

    // The service primarily orchestrates session-scope work (CRUD,
    // pagination, title generation), but the message-scope search the UI
    // surfaces also lives here for now — splitting `runMessageSearch` out
    // would force the adapter to fan one user search across two services.
    // Held as a combined existential so callers can pass a single adapter
    // (the SwiftData impl conforms to both); a future move into a runtime
    // package may split this back into separate references when it also
    // splits the message-search use case off.
    private let persistence: any SessionStore & MessageStore
    private let diagnostics: DiagnosticsService?

    @MainActor private var messageSearchGeneration = 0
    /// Test seam called after the storage query completes but before search
    /// results are published, so integration tests can exercise stale results.
    @MainActor package var messageSearchObserver: ((String) async throws -> Void)?

    private let sinkBox = EventSinkBox()

    package init(
        persistence: any SessionStore & MessageStore,
        diagnostics: DiagnosticsService? = nil
    ) {
        self.persistence = persistence
        self.diagnostics = diagnostics
        var cap: AsyncStream<SessionListEvent>.Continuation!
        self.events = AsyncStream { cap = $0 }
        self.continuation = cap
    }

    deinit {
        continuation.finish()
    }

    /// Installs a synchronous sink invoked on every emitted event before the
    /// event reaches ``events`` subscribers. The adapter uses this to mirror
    /// state without an extra actor hop. Pass `nil` to remove the sink.
    package func setEventSink(_ sink: (@Sendable (SessionListEvent) -> Void)?) {
        sinkBox.set(sink)
    }

    /// Emits an event: invokes the synchronous sink (if any) then yields to
    /// the public `events` stream. Both delivery channels run synchronously
    /// from the caller's executor — adapters that install a sink see state
    /// applied before `emit` returns, which keeps the
    /// `await command(); assert(state)` test pattern deterministic.
    private func emit(_ event: SessionListEvent) {
        sinkBox.invoke(event)
        continuation.yield(event)
    }

    // MARK: - Commands

    /// Creates a new session, persists it, and emits `.sessionsLoaded`.
    ///
    /// Commands are `@MainActor`-isolated for Phase 1.1: the underlying
    /// `SessionStore` and `DiagnosticsService` are `@MainActor`-
    /// bound, and isolating the command bodies on `@MainActor` keeps event
    /// emission ordered with respect to the adapter's main-actor consumer
    /// without needing a buffered AsyncStream barrier. Phase 1.2 step 5 lifts
    /// `InferenceService` off main, at which point the command isolation
    /// drops in tandem.
    @MainActor
    @discardableResult
    package func createSession(title: String = "New Chat") async throws -> ChatSession {
        let record = ChatSession(title: title)
        try await persistence.insertSession(record)
        await emitFirstPage()
        return record
    }

    /// Deletes a session and emits `.sessionDeleted` followed by `.sessionsLoaded`.
    @MainActor
    package func deleteSession(_ id: UUID) async throws {
        try await persistence.deleteSession(id)
        emit(.sessionDeleted(id))
        await emitFirstPage()
    }

    /// Deletes every persisted session and its messages in a single
    /// transaction and emits **one** terminal
    /// `.sessionsLoaded([], hasMore: false, offset: 0)` event so SwiftUI
    /// lists collapse to empty in a single animation rather than animating
    /// N row removals.
    ///
    /// Lowering choice: reusing `.sessionsLoaded(records: [], …)` rather
    /// than introducing a new `.allSessionsDeleted` case. The adapter's
    /// `apply` switch already treats `offset == 0` as a full replace, so a
    /// terminal empty page is the smallest possible delta — observers that
    /// only need "settle to empty" get it for free; a hypothetical observer
    /// that needs to distinguish "we just nuked everything" from "initial
    /// load returned empty" can be added as a new case in a follow-up
    /// without breaking source compat here.
    ///
    /// Throws: storage errors from ``SessionStore/deleteAll()``. On throw,
    /// no event is emitted so observable state stays consistent with the
    /// (unchanged) store.
    @MainActor
    package func deleteAllSessions() async throws {
        try await persistence.deleteAll()
        emit(.sessionsLoaded([], hasMore: false, offset: 0))
    }

    /// Pins a session to the top of the session list and emits
    /// `.sessionPinChanged(_, isPinned: true)` followed by `.sessionsLoaded`
    /// so observers see the re-sorted page.
    ///
    /// No-op (no event, no write) when the session is already pinned —
    /// callers that double-tap a pin affordance do not pay for a redundant
    /// `pinnedAt` reset, which would otherwise reshuffle the pinned bucket.
    @MainActor
    package func pinSession(_ session: ChatSession) async throws {
        guard !session.isPinned else { return }
        var updated = session
        updated.isPinned = true
        updated.pinnedAt = Date()
        try await persistence.updateSession(updated)
        emit(.sessionPinChanged(session.id, isPinned: true))
        await emitFirstPage()
    }

    /// Unpins a session and emits `.sessionPinChanged(_, isPinned: false)`
    /// followed by `.sessionsLoaded`. No-op when the session is not pinned.
    @MainActor
    package func unpinSession(_ session: ChatSession) async throws {
        guard session.isPinned else { return }
        var updated = session
        updated.isPinned = false
        updated.pinnedAt = nil
        try await persistence.updateSession(updated)
        emit(.sessionPinChanged(session.id, isPinned: false))
        await emitFirstPage()
    }

    /// Renames a session and emits `.sessionRenamed` followed by `.sessionsLoaded`.
    @MainActor
    package func renameSession(_ session: ChatSession, title: String) async throws {
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        try await persistence.updateSession(updated)
        emit(.sessionRenamed(session.id, title: title))
        await emitFirstPage()
    }

    // MARK: - Pagination

    /// Loads page one and emits `.sessionsLoaded`.
    @MainActor
    package func loadInitialPage() async {
        await emitFirstPage()
    }

    /// Fetches a page of sessions without emitting an event. Mirrors the
    /// previous `fetchSessionsPage` helper for tests that want to assert on
    /// raw page contents without VM mutation.
    @MainActor
    package func fetchPage(offset: Int, limit: Int) async throws -> [ChatSession] {
        try await persistence.fetchSessions(offset: offset, limit: limit)
    }

    /// Loads the next page starting at `offset` and emits `.sessionsLoaded`.
    /// On persistence failure, emits an empty `.sessionsLoaded(_, hasMore: false, offset:)`
    /// so the adapter clears `hasMoreSessions` (matching Phase 1.0 behaviour
    /// where a transient page-load failure stopped further pagination), then
    /// emits `.persistenceFailure` for diagnostics consumers.
    @MainActor
    package func loadNextPage(offset: Int) async {
        do {
            let next = try await persistence.fetchSessions(offset: offset, limit: Self.sessionsPageSize)
            let hasMore = next.count == Self.sessionsPageSize
            emit(.sessionsLoaded(next, hasMore: hasMore, offset: offset))
        } catch {
            Log.persistence.error("Failed to load next sessions page: \(error)")
            // Reset hasMoreSessions on the adapter so the failed offset is not
            // retried automatically. Pre-Phase-1.1 behaviour; restoring it
            // keeps the public surface source-compatible.
            emit(.sessionsLoaded([], hasMore: false, offset: offset))
            emit(.persistenceFailure(error))
        }
    }

    // MARK: - Search

    /// Filters the provided sessions by title and emits `.searchResultsChanged`.
    ///
    /// The adapter passes its currently loaded `sessions` so the service does
    /// not need to re-fetch persistence for a client-side filter.
    @MainActor
    package func runTitleSearch(_ query: String, against sessions: [ChatSession]) {
        invalidateMessageSearch()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            emit(.searchResultsChanged(.empty))
            return
        }
        let matches = sessions.filter {
            $0.title.range(of: trimmed, options: .caseInsensitive) != nil
        }
        emit(.searchResultsChanged(SearchResults(
            titleMatches: matches,
            messageHitsBySession: [:],
            messageMatchSessions: []
        )))
    }

    /// Runs a message-scope search via persistence and emits
    /// `.searchResultsChanged`.
    @MainActor
    package func runMessageSearch(_ query: String) async {
        invalidateMessageSearch()
        let generation = messageSearchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            emit(.searchResultsChanged(.empty))
            return
        }
        do {
            let hits = try await persistence.searchMessages(query: trimmed, limit: Self.messageSearchLimit)
            try Task.checkCancellation()
            guard generation == messageSearchGeneration else { return }
            if let messageSearchObserver {
                try await messageSearchObserver(trimmed)
            }
            try Task.checkCancellation()
            guard generation == messageSearchGeneration else { return }
            var grouped: [UUID: [MessageSearchHit]] = [:]
            grouped.reserveCapacity(hits.count)
            // Preserve first occurrence order so recency-first ordering of
            // hits maps directly onto recency-first ordering of sessions.
            var orderedSessionIDs: [UUID] = []
            for hit in hits {
                if grouped[hit.sessionID] == nil {
                    orderedSessionIDs.append(hit.sessionID)
                }
                grouped[hit.sessionID, default: []].append(hit)
            }
            var matchSessions: [ChatSession] = []
            matchSessions.reserveCapacity(orderedSessionIDs.count)
            for sessionID in orderedSessionIDs {
                try Task.checkCancellation()
                guard generation == messageSearchGeneration else { return }
                if let session = try await persistence.fetchSession(id: sessionID) {
                    try Task.checkCancellation()
                    guard generation == messageSearchGeneration else { return }
                    matchSessions.append(session)
                }
            }
            try Task.checkCancellation()
            guard generation == messageSearchGeneration else { return }
            emit(.searchResultsChanged(SearchResults(
                titleMatches: [],
                messageHitsBySession: grouped,
                messageMatchSessions: matchSessions
            )))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == messageSearchGeneration else { return }
            Log.persistence.error("Message search failed: \(error)")
            emit(.searchResultsChanged(.empty))
            emit(.persistenceFailure(error))
        }
    }

    /// Clears search state and emits `.searchResultsChanged(.empty)`.
    @MainActor
    package func clearSearch() {
        invalidateMessageSearch()
        emit(.searchResultsChanged(.empty))
    }

    @MainActor
    package func invalidateMessageSearch() {
        messageSearchGeneration &+= 1
    }

    // MARK: - Title generation

    /// Generates a concise AI title for `firstMessage` by running a short
    /// inference request. Returns `nil` when the model produces an empty
    /// response. Throws the underlying inference error on failure.
    @MainActor
    package func generateTitle(
        from firstMessage: String,
        using inferenceService: InferenceService
    ) async throws -> String? {
        let systemPrompt = "Generate a concise 3-5 word title for a conversation that starts with the following message. Reply with ONLY the title, no punctuation, no quotes."
        let messages: [Message] = [.user(firstMessage)]
        let (_, stream) = try inferenceService.enqueue(
            messages: messages,
            systemPrompt: systemPrompt,
            config: GenerationConfig(temperature: 0.3, topP: 0.9, repeatPenalty: 1.0),
            priority: .background,
            requestGroupID: nil
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

    /// Generates an AI title for the session and persists it. Only renames
    /// sessions that are still named "New Chat". Inference and persistence
    /// failures are recorded on diagnostics in distinct categories.
    @MainActor
    package func autoRenameSession(
        _ session: ChatSession,
        firstMessage: String,
        inferenceService: InferenceService
    ) async {
        guard session.title == "New Chat" else { return }
        let title: String?
        do {
            title = try await generateTitle(from: firstMessage, using: inferenceService)
        } catch {
            Log.ui.warning("Title generation failed for session \(session.id): \(error.localizedDescription)")
            await diagnostics?.record(.titleGenerationFailed(sessionID: session.id, reason: error.localizedDescription))
            return
        }
        guard let title else { return }
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try await persistence.updateSession(updated)
        } catch {
            Log.persistence.warning("Failed to persist auto-rename for session \(session.id): \(error.localizedDescription)")
            // Persistence failure is a distinct category from inference
            // failure — different remediation (disk/store health vs.
            // backend availability), so we surface it as its own case.
            await diagnostics?.record(.sessionRenamePersistenceFailed(sessionID: session.id, reason: error.localizedDescription))
            return
        }
        emit(.titleGenerated(session.id, title: title))
        await emitFirstPage()
    }

    /// Auto-generates a session title from the first user message using a
    /// 50-character word-boundary truncation. Fallback for callers without
    /// inference. No-op when the session is no longer named "New Chat".
    @MainActor
    package func autoGenerateTitle(for session: ChatSession, firstMessage: String) async {
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
        var updated = session
        updated.title = title
        updated.updatedAt = Date()
        do {
            try await persistence.updateSession(updated)
        } catch {
            Log.persistence.error("Failed to auto-generate title: \(error)")
            return
        }
        emit(.titleGenerated(session.id, title: title))
        await emitFirstPage()
    }

    // MARK: - Branch origin

    /// Resolves the display title for `session`'s branch-origin chip
    /// ("Branched from ‹title›"), or `nil` when `session` was not branched.
    ///
    /// Prefers the source session's *current* title, fetched live via
    /// `session.branchOriginSessionID` — so a rename of the source is
    /// reflected in every branch's chip. Falls back to
    /// `session.branchOriginTitleSnapshot` (captured at branch time) only
    /// when the source session has since been deleted, so the chip still has
    /// a title to render instead of silently disappearing.
    ///
    /// This is the seam `ManifoldUI`'s `BranchOriginChipView` — which takes a
    /// plain `String?` title — resolves through; the view itself stays
    /// storage-agnostic.
    @MainActor
    package func branchOriginTitle(for session: ChatSession) async -> String? {
        guard let originID = session.branchOriginSessionID else { return nil }
        do {
            if let liveTitle = try await persistence.fetchSession(id: originID)?.title {
                return liveTitle
            }
        } catch {
            Log.persistence.warning(
                "SessionListService.branchOriginTitle: live lookup failed for \(originID): \(error.localizedDescription); using snapshot"
            )
        }
        return session.branchOriginTitleSnapshot
    }

    // MARK: - Internal helpers

    /// Loads page one and emits `.sessionsLoaded` (or a failure event).
    @MainActor
    private func emitFirstPage() async {
        do {
            let page = try await persistence.fetchSessions(offset: 0, limit: Self.sessionsPageSize)
            let hasMore = page.count == Self.sessionsPageSize
            emit(.sessionsLoaded(page, hasMore: hasMore, offset: 0))
        } catch {
            Log.persistence.error("Failed to load sessions: \(error)")
            emit(.sessionsLoaded([], hasMore: false, offset: 0))
            emit(.persistenceFailure(error))
        }
    }
}

/// Holds the optional synchronous event sink. The adapter installs the sink
/// from `@MainActor`; the service emits events from whatever isolation it is
/// running on. Lock-protected so any future move of the service off-main
/// (Phase 1.2) does not need to revisit this storage.
private final class EventSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (SessionListEvent) -> Void)?

    func set(_ sink: (@Sendable (SessionListEvent) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.sink = sink
    }

    func invoke(_ event: SessionListEvent) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?(event)
    }
}
