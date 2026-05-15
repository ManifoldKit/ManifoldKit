import Foundation
import ManifoldInference

/// A turn-completion record passed to ``GenerationHook/postGeneration(_:)``
/// after each successful assistant response.
///
/// All fields that require inference infrastructure (token counts, message
/// content) are optional so hooks remain usable in contexts where the backend
/// does not report full usage.
public struct CompletedTurn: Sendable {
    /// The session this turn belongs to.
    public let sessionID: UUID
    /// The assistant message that was written to persistence this turn.
    public let assistantMessage: ChatMessageRecord
    /// Prompt tokens consumed by the backend for this turn, if reported.
    public let promptTokens: Int?
    /// Completion tokens produced by the backend for this turn, if reported.
    public let completionTokens: Int?

    public init(
        sessionID: UUID,
        assistantMessage: ChatMessageRecord,
        promptTokens: Int?,
        completionTokens: Int?
    ) {
        self.sessionID = sessionID
        self.assistantMessage = assistantMessage
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// Observer called after each successful generation turn completes.
///
/// Hooks are called sequentially in registration order with a per-hook
/// timeout (default 30 s). A hook that does not return within the timeout is
/// cancelled; the session is not affected. Hooks are **not** called on
/// cancelled, errored, or empty-response turns.
///
/// Use hooks for side effects that should trail every assistant response:
/// analytics recording, external memory writes, telemetry flushes. Do not
/// use hooks for logic that affects the current turn's output — that belongs
/// in a ``PromptContextProvider``.
public protocol GenerationHook: Sendable {
    /// Called after the assistant message for `turn` has been written to
    /// persistence and all ``ConversationEvent``s for the turn have been
    /// emitted.
    ///
    /// - Parameter turn: A snapshot of the completed turn.
    func postGeneration(_ turn: CompletedTurn) async
}
