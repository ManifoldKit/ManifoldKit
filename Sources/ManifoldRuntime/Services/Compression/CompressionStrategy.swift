import Foundation
import ManifoldInference

/// A pure, stateless algorithm that reduces a chat history to fit a token
/// budget. Strategies are the reusable core shared by both compression seams
/// (``CompressionPolicy`` post-turn and ``PreTurnCompressionPolicy``
/// pre-turn); ``DefaultCompressionPolicy`` wraps a strategy with the trigger
/// thresholds each protocol needs.
///
/// Unlike the ``CompressionPolicy``/``PreTurnCompressionPolicy`` `compress`
/// methods — which receive only `history` + `sessionID` — a strategy also
/// takes the `contextSize` and `tokenizer` it sizes against. The policy holds
/// those as configuration and forwards them, because the protocol `compress`
/// signatures intentionally do not.
///
/// ## System-prompt budgeting (seam constraint)
///
/// A strategy sees only the `history` array. The session system prompt lives
/// on `ChatSession.systemPrompt` and is *not* part of `history`, and the
/// `CompressionPolicy` / `PreTurnCompressionPolicy` protocol `compress`
/// signatures pass **neither** a system prompt nor a tokenizer — so a strategy
/// cannot subtract a *real* system-prompt token count and cannot read a live
/// tokenizer. Both are therefore **configuration** on ``DefaultCompressionPolicy``
/// (set via the factories) and forwarded in: `reservedTokens` (response
/// headroom + a system-prompt allowance) and an optional `tokenizer`. The
/// budget is `contextSize − reservedTokens`. Any `.system`-role or `.memory`-kind
/// records that *are* in `history` are treated as load-bearing and preserved
/// verbatim by every strategy.
///
/// Strategies are `Sendable` value types: `generate` is a parameter, never
/// stored, so there is no mutable summariser handle to guard.
protocol CompressionStrategy: Sendable {
    /// Stable identifier recorded for diagnostics (e.g. `"truncating"`).
    var name: String { get }

    /// Reduce `history` to fit `contextSize`.
    ///
    /// - Parameters:
    ///   - history: Full message history, oldest-first.
    ///   - contextSize: Backend context window in tokens.
    ///   - reservedTokens: Tokens carved out of `contextSize` before history is
    ///     sized — response headroom **plus** a system-prompt allowance (the
    ///     real prompt isn't visible here). Single source of truth for the
    ///     reservation across all strategies.
    ///   - tokenizer: Optional tokenizer for cost estimation; heuristic
    ///     (chars/4) when `nil`, in which case the budget is **advisory**, not
    ///     guaranteed to match the backend's real token count.
    ///   - generate: Inference call for strategies that summarise. Zero-inference
    ///     strategies ignore it. A closure that yields empty text signals "no
    ///     usable summariser" — summarising strategies fall back accordingly.
    /// - Returns: The replacement history, oldest-first. Never empty when
    ///   `history` is non-empty.
    func compress(
        history: [ChatMessage],
        contextSize: Int,
        reservedTokens: Int,
        tokenizer: (any TokenizerProvider)?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage]
}

// MARK: - Shared helpers

extension CompressionStrategy {
    /// Per-message token estimate — sums across ALL content parts (text,
    /// reasoning, image/audio, tool-call/-result), not just `.text`, so a
    /// multimodal or tool-only message isn't counted as zero (#1885 finding 9).
    func estimateTokens(_ message: ChatMessage, tokenizer: (any TokenizerProvider)?) -> Int {
        ContextWindowManager.estimateTokenCount(message, tokenizer: tokenizer)
    }

    /// Total tokens across a message set.
    func estimateTokens(_ messages: [ChatMessage], tokenizer: (any TokenizerProvider)?) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1, tokenizer: tokenizer) }
    }

    /// Token budget available for history: context window minus `reservedTokens`
    /// (response headroom + system-prompt allowance). The session system prompt
    /// is not visible here, so its real cost can't be subtracted — the
    /// allowance baked into `reservedTokens` covers it. Returns `0` when the
    /// reservation meets or exceeds the window; callers must guard that case
    /// (`reservedTokens >= contextSize`) and skip compression rather than churn
    /// against a zero budget.
    func historyBudget(contextSize: Int, reservedTokens: Int) -> Int {
        max(0, contextSize - reservedTokens)
    }

    /// `true` for records that must survive compression regardless of budget:
    /// `.system`-role prompt fragments and `.memory` summarisation artifacts
    /// (a prior compression brief must not be evicted by a later pass).
    ///
    // TODO(#1885): honor per-message pins. The data already exists —
    // `ChatSession.pinnedMessageIDs` holds the pinned IDs — but the
    // `CompressionPolicy.compress(history:sessionID:generate:)` /
    // `PreTurnCompressionPolicy.compressBeforeTurn(...)` signatures pass only a
    // `[ChatMessage]` and the `sessionID`, not the pinned-ID set. Threading the
    // pins through is a PROTOCOL-SIGNATURE change (a new parameter or a session
    // handle), so it is deliberately out of scope for this PR; see the note on
    // the `CompressionPolicy` protocol doc.
    func isLoadBearing(_ message: ChatMessage) -> Bool {
        if message.role == .system { return true }
        if case .memory = message.kind { return true }
        return false
    }
}
