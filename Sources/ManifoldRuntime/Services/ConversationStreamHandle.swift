import Foundation

// MARK: - Stream handle

/// Identifier for an in-flight runtime stream.
///
/// Returned from ``ConversationRuntime/processTurn(_:)`` and passed back to
/// ``ConversationRuntime/cancel(_:)`` to cancel a specific in-flight turn.
/// Per-runtime unique; not stable across runtime instances.
public struct ConversationStreamHandle: Sendable, Hashable {
    public let id: UUID
    public init(id: UUID = UUID()) {
        self.id = id
    }
}
