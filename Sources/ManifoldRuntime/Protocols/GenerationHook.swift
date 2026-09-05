import Foundation
import ManifoldInference

/// A completed generation turn, passed to ``GenerationHook`` implementations.
public struct CompletedTurn: Sendable {
    public let sessionID: UUID
    public let assistantMessage: ChatMessage
    public let promptTokens: Int?
    public let completionTokens: Int?
    /// Opaque host-app payload sourced from ``ConversationRuntime/turnContextProvider``.
    /// Nil when no provider is registered or when the provider returns nil for
    /// this session. Mirrors ``TurnContext/appData`` so hooks can act on
    /// per-session app state without a separate registry.
    public let appData: (any Sendable)?

    public init(
        sessionID: UUID,
        assistantMessage: ChatMessage,
        promptTokens: Int?,
        completionTokens: Int?,
        appData: (any Sendable)? = nil
    ) {
        self.sessionID = sessionID
        self.assistantMessage = assistantMessage
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.appData = appData
    }
}

/// A callback invoked after each successful generation turn.
///
/// `postGeneration(_:)` is awaited with a configurable cancellation-request
/// deadline (default 30 s). When that deadline elapses, the runtime requests
/// cancellation and logs it, but still joins this direct invocation before its
/// turn outcome settles. A hook that ignores cancellation can therefore keep
/// the turn pending until it returns; Swift cannot forcibly terminate it.
///
/// A hook may start host-owned descendant work and return promptly. That work
/// is outside the runtime's settlement boundary; the host owns its lifetime
/// and any later join.
///
/// Hooks are **not** called when:
/// - the turn was cancelled
/// - the stream produced an error
/// - the assistant response was empty (no-op turn)
///
/// Register via
/// ``ConversationRuntime/init(messageStore:sessionStore:inferenceService:pipeline:ragService:auxiliaryInferenceService:usageStore:generationHooks:compressionPolicy:)``.
public protocol GenerationHook: Sendable {
    /// Called at the very start of a new turn, before context assembly begins.
    ///
    /// Implementations use this to cancel any in-flight work from the prior turn
    /// (e.g. an extraction coordinator running against the previous assistant
    /// message) before the new turn's context is assembled. The default
    /// implementation is a no-op.
    ///
    /// - Parameter sessionID: The session starting a new turn.
    func willBeginTurn(sessionID: UUID) async

    func postGeneration(_ turn: CompletedTurn) async
}

extension GenerationHook {
    public func willBeginTurn(sessionID: UUID) async {}
}
