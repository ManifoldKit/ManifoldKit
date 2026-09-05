import Foundation
import ManifoldInference

/// Single seam for "fetch canonical history, healed for generation".
///
/// Every fetch whose result is (directly or indirectly) handed to a backend
/// `generate()` call must come through here, not through the raw
/// `fetchMessages` — otherwise a transcript ending in an orphan
/// ``MessagePart/toolCall`` (the turn was cancelled mid-tool, or the process
/// was killed before the tool result was persisted) reaches the wire with an
/// unanswered `tool_use`, which cloud APIs reject outright (#629).
///
/// Healing here is unconditional protocol correctness, not host policy: it
/// must not depend on an optional `HistoryShaper` being installed, and it runs
/// *before* any downstream shaping/compression/trimming so those stages
/// operate on an already-well-formed transcript. ``TranscriptHealer`` inserts
/// the synthesised ``ToolResult`` into the same ``ChatMessage`` as the orphan
/// call — never a new message — so message counts, message IDs, and
/// message-granularity trimming are all unaffected, and healing is idempotent.
///
/// Generation-bound callers (keep this list current):
/// - ``ConversationTurnExecutor`` `fetchAndPrepareTurnHistory` — the turn loop.
/// - ``TurnCompressionCoordinator`` pre-turn and post-turn compression — the
///   fetched history feeds the policy's summarisation `generate` closure.
///   Note: compress-and-replace persists the policy's output, so records the
///   policy retains verbatim are written back healed. That is deliberate —
///   healing is idempotent and the replacement transcript becomes permanently
///   well-formed.
/// - ``SummarisationHook`` `performSummarisation` — folded turns are handed to
///   the summariser's backend call. Deletion targets are resolved by message
///   ID, which healing preserves.
///
/// Bookkeeping fetches (locate/delete/slice by ID in the regenerate / edit /
/// branch flows) intentionally stay on the raw `fetchMessages` — they never
/// reach a backend, and each flow re-enters `fetchAndPrepareTurnHistory` for
/// the actual generation. `ManifoldMCPHost`'s reads are a separate,
/// non-generation surface and are out of scope here.
extension MessageStore {
    /// Fetches the session's canonical history with orphan tool calls healed.
    func fetchHealedMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        TranscriptHealer.heal(try await fetchMessages(for: sessionID))
    }

    /// Bounded generation context for callers that never mutate the complete
    /// transcript. Whole-history replacement flows keep using
    /// ``fetchHealedMessages(for:)``.
    package func fetchRecentHealedMessages(
        for sessionID: UUID,
        limit: Int
    ) async throws -> [ChatMessage] {
        let page = try await fetchMessageHistoryPage(for: sessionID, cursor: nil, limit: limit)
        return TranscriptHealer.heal(page.messages)
    }
}
