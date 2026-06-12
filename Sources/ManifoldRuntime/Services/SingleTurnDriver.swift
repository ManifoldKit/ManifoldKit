import Foundation
import ManifoldInference

// MARK: - SingleTurnDriver
//
// P3a: the default ``TurnDriver`` conformer that reproduces the pre-P3
// linear behavior of `ConversationRuntime`. Behavior-preserving — the
// golden P0c transcripts must diff clean after this refactor.
//
// The implementation is a thin router: it reads `TurnKind` and delegates
// to the matching `ConversationTurnExecutor` flow, exactly as the
// `processTurn` switch in `ConversationRuntime` did before the seam was
// introduced. No logic is added or removed.
//
// Acceptance metric: adding a driver = conform TurnDriver, 0 engine-core
// edits. `SingleTurnDriver` proves the contract by being the first conformer.

/// Default ``TurnDriver`` that executes one linear turn per call, reproducing
/// the behavior that existed in ``ConversationRuntime`` before the P3 driver
/// seam was introduced.
///
/// This is always the right choice for standard chat sessions. Pass
/// ``ResumableRunDriver`` when you need long-running, checkpointed runs that
/// survive app suspension.
///
/// ## Behavior preservation
///
/// `SingleTurnDriver` is a thin router — it adds no new logic beyond the
/// `TurnKind` switch that previously lived inline in `ConversationRuntime`.
/// The P0c golden transcripts must diff clean against any build that uses
/// this driver.
public struct SingleTurnDriver: TurnDriver {

    public init() {}

    package func executeTurn(
        _ input: TurnInput,
        executor: ConversationTurnExecutor,
        taskRegistry: ConversationTurnTaskRegistry,
        outcomeCompletion: ConversationTurnOutcomeCompletion?
    ) async throws -> ConversationStreamHandle? {
        switch input.kind {
        case let .send(text, attachments):
            return try await executor.runSendFlow(
                sessionID: input.sessionID,
                text: text,
                attachments: attachments,
                config: input.config,
                taskRegistry: taskRegistry,
                outcomeCompletion: outcomeCompletion
            )
        case .regenerate:
            return try await executor.runRegenerateFlow(
                sessionID: input.sessionID,
                config: input.config,
                taskRegistry: taskRegistry,
                outcomeCompletion: outcomeCompletion
            )
        case let .edit(messageID, text):
            return try await executor.runEditFlow(
                sessionID: input.sessionID,
                messageID: messageID,
                text: text,
                config: input.config,
                taskRegistry: taskRegistry,
                outcomeCompletion: outcomeCompletion
            )
        case let .branch(messageID, newSessionID, newSessionTitle, generateAfter):
            return try await executor.runBranchFlow(
                sourceSessionID: input.sessionID,
                branchMessageID: messageID,
                newSessionID: newSessionID,
                newSessionTitle: newSessionTitle,
                generateAfter: generateAfter,
                config: input.config,
                taskRegistry: taskRegistry,
                outcomeCompletion: outcomeCompletion
            )
        }
    }
}
