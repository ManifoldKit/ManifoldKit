import Foundation
import ManifoldInference

// MARK: - TurnPersistencePort
//
// Issue #1957 Tier 4: `ConversationTurnExecutor` mixed context assembly,
// dispatch, persistence writes, event emission, and session branching behind
// one broad `ConversationPersistencePort` dependency. This narrower seam is
// the persistence surface actually touched by the shared generation inner
// loop (`runGenerationTurn` and `fetchAndPrepareTurnHistory`) — reading and
// writing the *current turn's* message/session state. Flow-specific setup
// (message-batch edits, session creation/copy for branch, trailing-message
// deletes) stays on the broader `ConversationPersistencePort`, which those
// flows still depend on directly.
//
// `package`, not `public`, per docs/API-DESIGN.md's default — no companion
// package, manifold-eval, or consumer app conforms to or consumes this type
// directly today.

/// Narrow persistence seam consumed by the turn-loop's shared generation
/// inner loop: the per-turn history fetch, the mid-stream handoff write, the
/// assistant-message insert, and the post-turn session touch.
///
/// `ConversationPersistencePort` conforms to this protocol so
/// `ConversationTurnExecutor` can depend on the narrow surface inside its
/// generation loop while flow-specific setup (send/regenerate/edit/branch)
/// keeps using the full port.
package protocol TurnPersistencePort: Sendable {
    /// Persists a new message (typically the finalized assistant turn).
    func insertMessage(_ message: ChatMessage) async throws

    /// Generation-bound history fetch with orphan tool calls healed. See
    /// `HealedHistoryFetch.swift` for the seam contract.
    func fetchHealedMessages(sessionID: UUID) async throws -> [ChatMessage]

    /// Bounded generation context. This is separate from the complete healed
    /// history used by compression and replacement flows.
    func fetchRecentHealedMessages(sessionID: UUID, limit: Int) async throws -> [ChatMessage]

    /// Fetches the storage-agnostic session record used for multi-agent
    /// state (`activeAgentID`, `agents`) during the turn.
    func fetchSession(sessionID: UUID) async -> ChatSession?

    /// Swaps the session's active agent when a mid-stream handoff fires.
    /// Best-effort: returns `false` and logs on failure.
    func setActiveAgent(sessionID: UUID, agentID: UUID?) async -> Bool

    /// Bumps the session's `updatedAt` after a successful turn. Best-effort:
    /// returns `false` and logs on failure.
    func touchSession(sessionID: UUID) async -> Bool
}

extension TurnPersistencePort {
    package func fetchRecentHealedMessages(sessionID: UUID, limit: Int) async throws -> [ChatMessage] {
        guard limit > 0 else { return [] }
        let history = try await fetchHealedMessages(sessionID: sessionID)
        return Array(history.suffix(limit))
    }
}

extension ConversationPersistencePort: TurnPersistencePort {}
