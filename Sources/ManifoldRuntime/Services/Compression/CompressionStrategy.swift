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
/// ## System-prompt budgeting
///
/// A strategy sees only the `history` array. The session system prompt lives
/// on `ChatSession.systemPrompt` and is *not* part of `history`, so the budget
/// is sized against `contextSize` minus a fixed response buffer. Any `.system`
/// role or `.memory` kind records that *are* in `history` are treated as
/// load-bearing and preserved verbatim by every strategy.
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
    ///   - tokenizer: Optional tokenizer for cost estimation; heuristic when `nil`.
    ///   - generate: Inference call for strategies that summarise. Zero-inference
    ///     strategies ignore it. A closure that yields empty text signals "no
    ///     usable summariser" — summarising strategies fall back accordingly.
    /// - Returns: The replacement history, oldest-first. Never empty when
    ///   `history` is non-empty.
    func compress(
        history: [ChatMessage],
        contextSize: Int,
        tokenizer: (any TokenizerProvider)?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage]
}

// MARK: - Shared helpers

extension CompressionStrategy {
    /// Tokens reserved for the model's own response when sizing history.
    var responseBuffer: Int { 512 }

    /// Per-message token estimate.
    func estimateTokens(_ message: ChatMessage, tokenizer: (any TokenizerProvider)?) -> Int {
        ContextWindowManager.estimateTokenCount(message.content, tokenizer: tokenizer)
    }

    /// Total tokens across a message set.
    func estimateTokens(_ messages: [ChatMessage], tokenizer: (any TokenizerProvider)?) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1, tokenizer: tokenizer) }
    }

    /// Token budget available for history: context window minus the response
    /// buffer. The session system prompt is not visible here (it is not part
    /// of `history`), so it is not subtracted.
    func historyBudget(contextSize: Int, tokenizer: (any TokenizerProvider)?) -> Int {
        max(0, contextSize - responseBuffer)
    }

    /// `true` for records that must survive compression regardless of budget:
    /// `.system`-role prompt fragments and `.memory` summarisation artifacts
    /// (a prior compression brief must not be evicted by a later pass).
    ///
    // TODO: per-message pinning is not visible to a `[ChatMessage]`-only
    // policy — `ChatSession.pinnedMessageIDs` lives on the session. When the
    // seam grows a pinned-IDs channel, honor it here.
    func isLoadBearing(_ message: ChatMessage) -> Bool {
        if message.role == .system { return true }
        if case .memory = message.kind { return true }
        return false
    }
}
