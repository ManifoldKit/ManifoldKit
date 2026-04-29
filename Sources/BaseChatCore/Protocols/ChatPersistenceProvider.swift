import Foundation
import BaseChatInference

/// Errors produced by ``ChatPersistenceProvider`` implementations.
public enum ChatPersistenceError: Error, LocalizedError, Sendable, Equatable {
    case providerNotConfigured
    case sessionNotFound(UUID)
    case messageNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            return "Persistence provider is not configured."
        case let .sessionNotFound(sessionID):
            return "Session not found: \(sessionID.uuidString)"
        case let .messageNotFound(messageID):
            return "Message not found: \(messageID.uuidString)"
        }
    }
}

/// Abstraction over chat persistence, decoupling view models from SwiftData.
///
/// The default implementation is ``SwiftDataPersistenceProvider``. Tests
/// should build a real provider over an in-memory container via
/// ``InMemoryPersistenceHarness`` in `BaseChatTestSupport`, optionally wrapped
/// in ``ErrorInjectingPersistenceProvider`` when failure injection is needed.
@MainActor
public protocol ChatPersistenceProvider: AnyObject, Sendable {

    // MARK: - Sessions

    /// Inserts a new chat session.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func insertSession(_ session: ChatSessionRecord) async throws

    /// Updates an existing chat session.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/sessionNotFound(_:)`` when the session does not exist.
    ///   - Storage errors from the underlying provider.
    func updateSession(_ session: ChatSessionRecord) async throws

    /// Deletes a chat session and all associated messages.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/sessionNotFound(_:)`` when the session does not exist.
    ///   - Storage errors from the underlying provider.
    func deleteSession(_ sessionID: UUID) async throws

    /// Fetches all chat sessions sorted by most-recently-updated.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func fetchSessions() async throws -> [ChatSessionRecord]

    /// Fetches a page of chat sessions sorted by most-recently-updated.
    ///
    /// Use to paginate large session lists so the sidebar stays responsive at
    /// 1000+ sessions. Pages are returned in the same order as
    /// ``fetchSessions()``.
    ///
    /// - Parameters:
    ///   - offset: Index of the first session to return (0-based).
    ///   - limit: Maximum number of sessions to return.
    /// - Throws: Storage errors from the underlying provider.
    func fetchSessions(offset: Int, limit: Int) async throws -> [ChatSessionRecord]

    // MARK: - Search

    /// Searches messages whose plain-text content contains `query`.
    ///
    /// Matching is case-insensitive. Results are sorted by message timestamp
    /// in descending order (most recent first) and capped at `limit`. Each hit
    /// carries a short snippet centred on the first match to support inline
    /// previews in search UI.
    ///
    /// - Parameters:
    ///   - query: Substring to search for. Empty queries return no hits.
    ///   - limit: Maximum number of hits to return (UI default: 100).
    /// - Throws: Storage errors from the underlying provider.
    func searchMessages(query: String, limit: Int) async throws -> [MessageSearchHit]

    // MARK: - Messages

    /// Inserts a new chat message.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func insertMessage(_ message: ChatMessageRecord) async throws

    /// Updates an existing chat message.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/messageNotFound(_:)`` when the message does not exist.
    ///   - Storage errors from the underlying provider.
    func updateMessage(_ message: ChatMessageRecord) async throws

    /// Deletes a chat message.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/messageNotFound(_:)`` when the message does not exist.
    ///   - Storage errors from the underlying provider.
    func deleteMessage(_ messageID: UUID) async throws

    /// Fetches messages for a session in timestamp order.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord]

    /// Fetches the most recent messages for a session, up to `limit`.
    ///
    /// Results are returned in ascending timestamp order (oldest first).
    /// Use ``fetchMessages(for:before:limit:)`` to page backwards from a known timestamp.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func fetchRecentMessages(for sessionID: UUID, limit: Int) async throws -> [ChatMessageRecord]

    /// Fetches messages older than `before` for a session, up to `limit`.
    ///
    /// Results are returned in ascending timestamp order (oldest first).
    /// Returns an empty array when no older messages exist.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func fetchMessages(for sessionID: UUID, before: Date, limit: Int) async throws -> [ChatMessageRecord]

    /// Deletes all messages for a session.
    ///
    /// - Throws: Storage errors from the underlying provider.
    func deleteMessages(for sessionID: UUID) async throws
}

// MARK: - Default pagination implementations

extension ChatPersistenceProvider {

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

    /// Default: pages over the full list returned by ``fetchSessions()``.
    public func fetchSessions(offset: Int, limit: Int) async throws -> [ChatSessionRecord] {
        let all = try await fetchSessions()
        guard offset < all.count else { return [] }
        let end = min(offset + limit, all.count)
        return Array(all[offset..<end])
    }

    /// Default: returns no hits. Providers that don't implement search opt
    /// out by inheriting this no-op rather than throwing — UI shows the
    /// "No results" empty state, which is the correct behaviour.
    public func searchMessages(query: String, limit: Int) async throws -> [MessageSearchHit] {
        []
    }
}

// MARK: - Snippet helpers

/// Builds a short snippet around the first case-insensitive occurrence of
/// `query` in `content`. Used by persistence providers to populate
/// ``MessageSearchHit/snippet``.
///
/// The snippet aims for ~120 characters of context. If the match sits near
/// either edge the window is anchored there; otherwise the window is centred
/// on the match. An ellipsis prefix/suffix is added when content is trimmed.
public func makeMessageSearchSnippet(
    content: String,
    query: String,
    contextRadius: Int = 50
) -> (snippet: String, matchRange: Range<String.Index>)? {
    guard !query.isEmpty,
          let matchInContent = content.range(of: query, options: .caseInsensitive) else {
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
    // indices, and re-running the case-insensitive search is cheaper and
    // simpler than offset arithmetic.
    guard let matchInSnippet = snippet.range(of: query, options: .caseInsensitive) else {
        return (snippet, snippet.startIndex..<snippet.startIndex)
    }
    return (snippet, matchInSnippet)
}
