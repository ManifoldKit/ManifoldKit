import Foundation
import BaseChatInference

/// Preferred vertical alignment when scrolling a message into view.
public enum ChatMessageScrollAnchor: Sendable, Hashable {
    case top
    case center
    case bottom
}

/// A one-shot request for ``ChatView`` to scroll a message into view.
///
/// Each request carries a fresh ``requestID`` so callers can request the same
/// ``messageID`` repeatedly and still trigger SwiftUI observation.
public struct ChatScrollToMessageRequest: Sendable, Identifiable, Hashable {
    public var id: UUID { requestID }

    public let requestID: UUID
    public let messageID: ChatMessageRecord.ID
    public let anchor: ChatMessageScrollAnchor?

    public init(
        requestID: UUID = UUID(),
        messageID: ChatMessageRecord.ID,
        anchor: ChatMessageScrollAnchor? = nil
    ) {
        self.requestID = requestID
        self.messageID = messageID
        self.anchor = anchor
    }
}
