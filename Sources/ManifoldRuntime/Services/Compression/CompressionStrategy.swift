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
/// ## System-prompt budgeting (#1957)
///
/// A strategy sees only the `history` array — the session system prompt
/// lives on `ChatSession.systemPrompt` and is *not* part of `history`. Since
/// #1957, `CompressionPolicy` / `PreTurnCompressionPolicy` thread the real
/// `systemPrompt` string down to `DefaultCompressionPolicy`, which forwards
/// it here alongside `reservedTokens` (now response headroom only) and the
/// construction-injected `tokenizer`. The budget is
/// `contextSize − reservedTokens − systemPromptTokens`, where
/// `systemPromptTokens` is measured with the same tokenizer (or the chars/4
/// heuristic when `tokenizer` is `nil`) via ``CompressionStrategy/historyBudget(contextSize:reservedTokens:systemPromptTokens:)``.
/// Any `.system`-role or `.memory`-kind records that *are* in `history` are
/// treated as load-bearing and preserved verbatim by every strategy.
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
    ///     sized — response headroom. Single source of truth for the response
    ///     reservation across all strategies. Does NOT need to cover the
    ///     system prompt any more — pass `systemPrompt` and its real cost is
    ///     subtracted separately (#1957).
    ///   - systemPrompt: The session's resolved system prompt, or `nil`.
    ///     Its real token cost is measured with `tokenizer` and subtracted
    ///     from the history budget alongside `reservedTokens` (#1957).
    ///   - tokenizer: Optional tokenizer for cost estimation; heuristic
    ///     (chars/4) when `nil`, in which case the budget is **advisory**, not
    ///     guaranteed to match the backend's real token count.
    ///   - isPinned: Predicate honored by ``CompressionStrategyExtensions/isLoadBearing(_:isPinned:)``
    ///     alongside the existing `.system`-role / `.memory`-kind rules (#2204).
    ///     Lets a consumer mark a message load-bearing without mutating it or
    ///     squatting on the `.memory` kind namespace — typically
    ///     `{ message in session.pinnedMessageIDs.contains(message.id) }`.
    ///   - generate: Inference call for strategies that summarise. Zero-inference
    ///     strategies ignore it. A closure that yields empty text signals "no
    ///     usable summariser" — summarising strategies fall back accordingly.
    /// - Returns: The replacement history (oldest-first, never empty when
    ///   `history` is non-empty) paired with the ``CompressionOutcome`` that
    ///   classifies what happened (#2203).
    func compress(
        history: [ChatMessage],
        contextSize: Int,
        reservedTokens: Int,
        systemPrompt: String?,
        tokenizer: (any TokenizerProvider)?,
        isPinned: @Sendable (ChatMessage) -> Bool,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> StrategyCompressionResult
}

/// Package-internal pairing of a strategy's replacement history with the
/// outcome that produced it. Not part of the public API — ``CompressionOutcome``
/// (the payload consumers actually see) is public and reaches them via
/// ``DefaultCompressionPolicy``'s `onOutcome` callback, not this wrapper.
struct StrategyCompressionResult: Sendable {
    let messages: [ChatMessage]
    let outcome: CompressionOutcome
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

    /// Token estimate for a raw string (e.g. the session system prompt),
    /// using the same tokenizer (or chars/4 heuristic when `nil`) as message
    /// estimation, so the two stay comparable (#1957).
    func estimateTokens(_ text: String, tokenizer: (any TokenizerProvider)?) -> Int {
        ContextWindowManager.estimateTokenCount(text, tokenizer: tokenizer)
    }

    /// Token budget available for history: context window minus
    /// `reservedTokens` (response headroom) minus `systemPromptTokens` (the
    /// session system prompt's REAL measured cost, #1957 — pass `0` when no
    /// system prompt applies). Returns `0` when the reservation meets or
    /// exceeds the window; callers must guard that case
    /// (`reservedTokens + systemPromptTokens >= contextSize`) and skip
    /// compression rather than churn against a zero budget.
    func historyBudget(contextSize: Int, reservedTokens: Int, systemPromptTokens: Int = 0) -> Int {
        max(0, contextSize - reservedTokens - systemPromptTokens)
    }

    /// `true` for records that must survive compression regardless of budget:
    /// `.system`-role prompt fragments, `.memory` summarisation artifacts (a
    /// prior compression brief must not be evicted by a later pass), and
    /// records the caller marks pinned via `isPinned` (#2204).
    ///
    /// Resolved via `isPinned` rather than a `ChatMessage.isPinned` field or a
    /// `.memory("pinned")` kind tag: the former needs a persistence-schema
    /// migration for a purely UI/consumer concept, the latter squats on the
    /// namespace ``AnchoredCompressionStrategy`` uses for its own
    /// `.memory("summary")` records — exactly the collision #2204 was filed to
    /// avoid. `DefaultCompressionPolicy`'s factories thread the predicate in;
    /// `{ _ in false }` (the default) preserves pre-#2204 behavior.
    func isLoadBearing(_ message: ChatMessage, isPinned: (ChatMessage) -> Bool) -> Bool {
        if message.role == .system { return true }
        if case .memory = message.kind { return true }
        if isPinned(message) { return true }
        return false
    }
}
