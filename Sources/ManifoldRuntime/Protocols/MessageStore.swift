import Foundation
import ManifoldInference

/// Storage port for chat messages and message-scope search.
///
/// Phase 1.2 split of the previous combined `ChatPersistenceProvider`; see
/// ``SessionStore`` for the session-scope counterpart. Hosts that want to
/// implement only one slice (audit / read-only sidecars) can do so without
/// dragging in the other.
///
/// `async throws` at the surface, sync at the implementation. `@MainActor`
/// for parity with SwiftData's `ModelContext`; in-memory and remote impls
/// remain free to do their work off-main and hop on demand.
@MainActor
public protocol MessageStore: AnyObject, Sendable {

    /// Inserts a new chat message.
    ///
    /// Hooks registered via ``addPostWriteHook(_:)`` fire after the underlying
    /// write commits.
    ///
    /// - Throws: Storage errors from the underlying store.
    func insertMessage(_ message: ChatMessage) async throws

    /// Updates an existing chat message.
    ///
    /// Hooks registered via ``addPostWriteHook(_:)`` fire after the underlying
    /// write commits.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/messageNotFound(_:)`` when the message does not exist.
    ///   - Storage errors from the underlying store.
    func updateMessage(_ message: ChatMessage) async throws

    /// Deletes a chat message.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/messageNotFound(_:)`` when the message does not exist.
    ///   - Storage errors from the underlying store.
    func deleteMessage(_ messageID: UUID) async throws

    /// Fetches messages for a session in timestamp order.
    ///
    /// This is the complete, chronological transcript. Implementations must
    /// return every stored record for `sessionID`; bounded UI and prompt reads
    /// use the paging APIs instead.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage]

    /// Fetches one backwards page of a session's history.
    ///
    /// `messages` is chronological (oldest first). A page captures the newest
    /// `(timestamp, id)` key on its first call, then continues below that
    /// high-water key. In a quiescent store this visits each captured record
    /// exactly once. It does not promise a transaction snapshot against
    /// concurrent backdated inserts or deletes.
    func fetchMessageHistoryPage(
        for sessionID: UUID,
        cursor: MessageHistoryCursor?,
        limit: Int
    ) async throws -> MessageHistoryPage

    /// Fetches the most recent messages for a session, up to `limit`.
    ///
    /// Results are returned in ascending timestamp order (oldest first).
    /// Use ``fetchMessages(for:before:limit:)`` to page backwards from a known
    /// timestamp.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchRecentMessages(for sessionID: UUID, limit: Int) async throws -> [ChatMessage]

    /// Fetches messages older than `before` for a session, up to `limit`.
    ///
    /// Results are returned in ascending timestamp order (oldest first).
    /// Returns an empty array when no older messages exist.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchMessages(for sessionID: UUID, before: Date, limit: Int) async throws -> [ChatMessage]

    /// Deletes all messages for a session.
    ///
    /// - Throws: Storage errors from the underlying store.
    func deleteMessages(for sessionID: UUID) async throws

    /// Searches messages whose plain-text content contains `query`.
    ///
    /// Matching is case- and diacritic-insensitive. Multi-word queries match
    /// messages containing every whitespace-delimited term, even when the
    /// terms are not adjacent. Results are sorted by message timestamp
    /// in descending order (most recent first) and capped at `limit`. Each hit
    /// carries a short snippet centred on the first match to support inline
    /// previews in search UI.
    ///
    /// - Parameters:
    ///   - query: Substring to search for. Empty queries return no hits.
    ///   - limit: Maximum number of hits to return (UI default: 100).
    /// - Throws: Storage errors from the underlying store.
    func searchMessages(query: String, limit: Int) async throws -> [MessageSearchHit]

    /// Registers a hook fired after every successful message write.
    ///
    /// See ``MessageStorePostWriteHook`` for ordering and error semantics.
    /// Hooks are a low-level primitive; consumers whose unit of work is the
    /// turn (not the message) compose at the use-case layer instead.
    func addPostWriteHook(_ hook: any MessageStorePostWriteHook)
}

/// Stable continuation state for backwards message-history paging.
///
/// The cursor is tied to one session and uses `(timestamp, UUID)` rather than
/// timestamps alone, so records sharing a timestamp are neither skipped nor
/// repeated. Its public initializer lets external ``MessageStore`` adapters
/// implement ``MessageStore/fetchMessageHistoryPage(for:cursor:limit:)``.
public struct MessageHistoryCursor: Sendable, Hashable {
    public let sessionID: UUID
    public let highWaterTimestamp: Date
    public let highWaterID: UUID
    public let beforeTimestamp: Date
    public let beforeID: UUID

    public init(
        sessionID: UUID,
        highWaterTimestamp: Date,
        highWaterID: UUID,
        beforeTimestamp: Date,
        beforeID: UUID
    ) {
        self.sessionID = sessionID
        self.highWaterTimestamp = highWaterTimestamp
        self.highWaterID = highWaterID
        self.beforeTimestamp = beforeTimestamp
        self.beforeID = beforeID
    }
}

/// One chronological page of message history.
public struct MessageHistoryPage: Sendable {
    public let messages: [ChatMessage]
    public let nextCursor: MessageHistoryCursor?

    public init(messages: [ChatMessage], nextCursor: MessageHistoryCursor?) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

/// Recoverable validation failures for message-history paging.
public enum MessageHistoryPagingError: Error, LocalizedError, Sendable, Equatable {
    case invalidLimit(Int)
    case cursorSessionMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidLimit(let limit):
            "Message history page limits must be positive and smaller than Int.max (received \(limit))."
        case .cursorSessionMismatch:
            "The message history cursor belongs to a different session."
        }
    }
}

// MARK: - Transactional batch mutations

/// A single message-store mutation that can be grouped with other mutations.
///
/// ``TransactionalMessageStore`` conformers apply a batch of these operations
/// as one unit of work so multi-row edits can commit consistently.
public enum MessageStoreMutation: Sendable, Equatable {
    /// Insert a new message record.
    case insert(ChatMessage)
    /// Update an existing message record.
    case update(ChatMessage)
    /// Delete one message by id.
    case delete(UUID)
    /// Delete every message belonging to a session.
    case deleteMessages(sessionID: UUID)
}

/// Optional ``MessageStore`` capability for atomic multi-message writes.
///
/// Existing stores do not need to conform. Callers should probe with
/// `as? any TransactionalMessageStore` and fall back to the legacy per-row
/// operations when the capability is unavailable.
@MainActor
public protocol TransactionalMessageStore: MessageStore {
    /// Applies every mutation in order and commits them as one unit.
    ///
    /// Implementations should fire ``MessageStorePostWriteHook`` only after
    /// the full batch commits, and only for inserted or updated records.
    ///
    /// - Throws: The first validation or storage error encountered. If the
    ///   underlying store supports rollback, no partial mutation should be
    ///   visible after the error.
    func performMessageMutations(_ mutations: [MessageStoreMutation]) async throws
}

// MARK: - Default pagination

extension MessageStore {

    /// Compatibility implementation for stores that already honour
    /// ``fetchMessages(for:)``'s complete-history contract. Concrete stores
    /// with database paging must implement the protocol requirement so calls
    /// through an `any MessageStore` existential use that witness.
    public func fetchMessageHistoryPage(
        for sessionID: UUID,
        cursor: MessageHistoryCursor?,
        limit: Int
    ) async throws -> MessageHistoryPage {
        guard limit > 0, limit < Int.max else {
            throw MessageHistoryPagingError.invalidLimit(limit)
        }
        if let cursor, cursor.sessionID != sessionID {
            throw MessageHistoryPagingError.cursorSessionMismatch
        }

        let newestFirst = try await fetchMessages(for: sessionID).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id > $1.id
        }
        guard let highWater = newestFirst.first else {
            return MessageHistoryPage(messages: [], nextCursor: nil)
        }

        let highWaterTimestamp = cursor?.highWaterTimestamp ?? highWater.timestamp
        let highWaterID = cursor?.highWaterID ?? highWater.id
        let candidates = newestFirst.filter { message in
            let atOrBelowHighWater = message.timestamp < highWaterTimestamp ||
                (message.timestamp == highWaterTimestamp && message.id <= highWaterID)
            guard atOrBelowHighWater else { return false }
            guard let cursor else { return true }
            return message.timestamp < cursor.beforeTimestamp ||
                (message.timestamp == cursor.beforeTimestamp && message.id < cursor.beforeID)
        }
        let pageNewestFirst = Array(candidates.prefix(limit))
        let nextCursor = candidates.count > limit ? pageNewestFirst.last.map {
            MessageHistoryCursor(
                sessionID: sessionID,
                highWaterTimestamp: highWaterTimestamp,
                highWaterID: highWaterID,
                beforeTimestamp: $0.timestamp,
                beforeID: $0.id
            )
        } : nil
        return MessageHistoryPage(
            messages: pageNewestFirst.reversed(),
            nextCursor: nextCursor
        )
    }

    /// Default: fetches all messages then returns the last `limit`.
    public func fetchRecentMessages(for sessionID: UUID, limit: Int) async throws -> [ChatMessage] {
        let all = try await fetchMessages(for: sessionID)
        return Array(all.suffix(limit))
    }

    /// Default: fetches all messages then filters to those before `before`.
    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) async throws -> [ChatMessage] {
        let all = try await fetchMessages(for: sessionID)
        let older = all.filter { $0.timestamp < before }
        return Array(older.suffix(limit))
    }

    /// Default: returns no hits. Stores that don't implement search opt out
    /// by inheriting this no-op rather than throwing — UI shows the
    /// "No results" empty state, which is the correct behaviour.
    public func searchMessages(query: String, limit: Int) async throws -> [MessageSearchHit] {
        []
    }

    /// Default: no-op. Stores that don't surface post-write hooks inherit
    /// this and silently drop the registration.
    public func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
}

// MARK: - Post-write hooks

/// Low-level primitive: fires after a message write commits.
///
/// **Not the canonical attachment point for any specific consumer's
/// cross-cutting concerns.** The hook is for consumers whose unit of work
/// *is* the message (audit, indexing, debug logging). Consumers whose unit
/// of work is the turn (post-turn extraction, narrative summarisation)
/// compose at the use-case / turn-orchestrator layer instead — the per-
/// message hook fires twice per turn and doesn't surface the turn boundary.
///
/// Semantics:
///
/// - Hooks fire **after** the underlying write commits. A failing hook
///   cannot roll back the write.
/// - Hooks fire in registration order. Adding a hook after writes have
///   already happened does not replay the prior writes.
/// - Hooks **must not throw**. Errors are logged via `Log.persistence.error`
///   and otherwise swallowed by the store. Surfaces that need transactional
///   guarantees compose at the use-case layer instead.
public protocol MessageStorePostWriteHook: Sendable {
    func messageDidWrite(
        _ record: ChatMessage,
        in sessionID: ChatSession.ID
    ) async
}

// MARK: - Snippet helpers

/// Builds a short snippet around the first case- and diacritic-insensitive occurrence of
/// `query` in `content`. Used by ``MessageStore`` implementations to
/// populate ``MessageSearchHit/snippet``.
///
/// The snippet aims for ~120 characters of context. If the match sits near
/// either edge the window is anchored there; otherwise the window is centred
/// on the match. An ellipsis prefix/suffix is added when content is trimmed.
public func makeMessageSearchSnippet(
    content: String,
    query: String,
    contextRadius: Int = 50
) -> (snippet: String, matchRange: Range<String.Index>)? {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    guard !query.isEmpty,
          let matchInContent = content.range(of: query, options: options) else {
        return nil
    }

    let matchStartOffset = content.distance(from: content.startIndex, to: matchInContent.lowerBound)
    let matchEndOffset = content.distance(from: content.startIndex, to: matchInContent.upperBound)

    let windowStart = max(0, matchStartOffset - contextRadius)
    let windowEnd = min(content.count, matchEndOffset + contextRadius)

    let lower = content.index(content.startIndex, offsetBy: windowStart)
    let upper = content.index(content.startIndex, offsetBy: windowEnd)

    var snippet = String(content[lower..<upper])
    let prefixEllipsis = windowStart > 0 ? "…" : ""
    let suffixEllipsis = windowEnd < content.count ? "…" : ""
    snippet = prefixEllipsis + snippet + suffixEllipsis

    // Re-locate the query inside the snippet — the ellipsis prefix shifts
    // indices, and re-running the case- and diacritic-insensitive search is
    // cheaper and simpler than offset arithmetic.
    guard let matchInSnippet = snippet.range(of: query, options: options) else {
        return (snippet, snippet.startIndex..<snippet.startIndex)
    }
    return (snippet, matchInSnippet)
}
