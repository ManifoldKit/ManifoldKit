import Foundation
import ManifoldInference

/// A completed generation turn, passed to ``GenerationHook`` implementations.
public struct CompletedTurn: Sendable {
    public let sessionID: UUID
    public let assistantMessage: ChatMessageRecord
    public let promptTokens: Int?
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

/// A callback invoked after each successful generation turn.
///
/// `postGeneration(_:)` is awaited with a configurable timeout (default 30 s).
/// A hung hook logs a warning and is skipped; it never blocks the next turn.
///
/// Hooks are **not** called when:
/// - the turn was cancelled
/// - the stream produced an error
/// - the assistant response was empty (no-op turn)
///
/// Register via
/// ``ConversationRuntime/init(messageStore:sessionStore:inferenceService:pipeline:ragService:auxiliaryInferenceService:usageStore:generationHooks:compressionPolicy:)``.
public protocol GenerationHook: Sendable {
    func postGeneration(_ turn: CompletedTurn) async
}
