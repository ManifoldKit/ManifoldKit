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
/// `package`-visibility only (2026-07 residual sweep, D.6): zero external
/// adopters across all six consumer repos. The runtime still wires this
/// internally (`ConversationTurnExecutor.appData(for:)` calls it on the real
/// turn path) and `ManifoldBootstrap` still threads
/// `ConversationRuntimeOptions.hostTurnContextProvider` through to it, but
/// hosts building against the public API cannot construct a conformance
/// anymore. Host apps that need per-turn data should use the planner-path
/// `TurnContext.appData` handoff instead — see
/// ``ContextBudgetPlanner`` and the "Providing app-specific per-turn data"
/// section of <doc:ContributingConversationHistory>.
///
/// The runtime awaits this provider once per turn; any thrown error aborts the
/// turn as ``ConversationError/contextAssembly(_:)``.
package protocol HostTurnContextProvider: Sendable {
    func appData(for request: TurnContextBuildRequest) async throws -> (any Sendable)?
}
