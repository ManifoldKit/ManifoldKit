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
    func insertMessage(_ message: ChatMessageRecord) async throws

    /// Updates an existing chat message.
    ///
    /// Hooks registered via ``addPostWriteHook(_:)`` fire after the underlying
    /// write commits.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/messageNotFound(_:)`` when the message does not exist.
    ///   - Storage errors from the underlying store.
    func updateMessage(_ message: ChatMessageRecord) async throws

    /// Deletes a chat message.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/messageNotFound(_:)`` when the message does not exist.
    ///   - Storage errors from the underlying store.
    func deleteMessage(_ messageID: UUID) async throws

    /// Fetches messages for a session in timestamp order.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord]

    /// Fetches the most recent messages for a session, up to `limit`.
    ///
    /// Results are returned in ascending timestamp order (oldest first).
    /// Use ``fetchMessages(for:before:limit:)`` to page backwards from a known
    /// timestamp.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchRecentMessages(for sessionID: UUID, limit: Int) async throws -> [ChatMessageRecord]

    /// Fetches messages older than `before` for a session, up to `limit`.
    ///
    /// Results are returned in ascending timestamp order (oldest first).
    /// Returns an empty array when no older messages exist.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchMessages(for sessionID: UUID, before: Date, limit: Int) async throws -> [ChatMessageRecord]

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

// MARK: - Default pagination

extension MessageStore {

    /// Default: fetches all messages then returns the last `limit`.
    public func fetchRecentMessages(for sessionID: UUID, limit: Int) async throws -> [ChatMessageRecord] {
        let all = try await fetchMessages(for: sessionID)
        return Array(all.suffix(limit))
    }

    /// Default: fetches all messages then filters to those before `before`.
    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) async throws -> [ChatMessageRecord] {
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
        _ record: ChatMessageRecord,
        in sessionID: ChatSessionRecord.ID
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
