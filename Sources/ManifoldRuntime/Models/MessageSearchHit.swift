import Foundation

/// A single match returned from full-text message search.
///
/// `snippet` is a short excerpt of the matched message centred around the
/// first occurrence of the query, suitable for display under the parent
/// session row. `matchRange` locates the query within `snippet` so callers
/// can highlight it without re-searching.
///
/// Lives alongside ``MessageStore`` (the producer) in `ManifoldRuntime`. The
/// record types it summarises (``ChatMessageRecord``, ``ChatSessionRecord``)
/// remain in `ManifoldInference` because inference-layer services (prompt
/// assembly, context-window management, transcript healing) traffic in them
/// independently of any persistence port.
public struct MessageSearchHit: Identifiable, Hashable, Sendable {
    public var id: UUID { messageID }
    public var messageID: UUID
    public var sessionID: UUID
    public var snippet: String
    public var matchRange: Range<String.Index>
    public var timestamp: Date

    public init(
        messageID: UUID,
        sessionID: UUID,
        snippet: String,
        matchRange: Range<String.Index>,
        timestamp: Date
    ) {
        self.messageID = messageID
        self.sessionID = sessionID
        self.snippet = snippet
        self.matchRange = matchRange
        self.timestamp = timestamp
    }
}
