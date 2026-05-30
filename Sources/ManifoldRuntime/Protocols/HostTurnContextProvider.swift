import Foundation
import ManifoldInference

/// Metadata available when the runtime constructs host-owned per-turn context.
///
/// The runtime builds this request once per turn from the target session and
/// the current canonical history snapshot, before any prompt-history shaping or
/// additive ``HistoryProvider`` contributions run.
public struct TurnContextBuildRequest: Sendable {
    public let sessionID: UUID
    public let turnKind: TurnKind
    public let messageCount: Int
    public let userInput: String?
    /// Derived from the canonical (unfiltered) history snapshot; does not
    /// reflect any subsequent shaping by a registered ``HistoryShaper``.
    public let conversationText: String?
    public let tokenizer: (any TokenizerProvider)?

    public init(
        sessionID: UUID,
        turnKind: TurnKind,
        messageCount: Int,
        userInput: String?,
        conversationText: String?,
        tokenizer: (any TokenizerProvider)? = nil
    ) {
        self.sessionID = sessionID
        self.turnKind = turnKind
        self.messageCount = messageCount
        self.userInput = userInput
        self.conversationText = conversationText
        self.tokenizer = tokenizer
    }
}

/// Builds host-owned per-turn app context for ``TurnContext/appData``.
///
/// Register via ``ConversationRuntime/init(messageStore:sessionStore:inferenceService:pipeline:budgetPlanner:ragService:auxiliaryInferenceService:usageStore:generationHooks:compressionPolicy:historyShaper:historyProviders:hostTurnContextProvider:turnContextProvider:sessionToolSources:hookRegistry:)``.
/// The runtime awaits this provider once per turn; any thrown error aborts the
/// turn as ``ConversationError/contextAssembly(_:)``.
public protocol HostTurnContextProvider: Sendable {
    func appData(for request: TurnContextBuildRequest) async throws -> (any Sendable)?
}
