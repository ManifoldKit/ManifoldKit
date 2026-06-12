import Foundation
// HeuristicTokenizer is @_spi(BackendInternals) — part of the published
// backend seam (#1749); in-package consumers import the SPI explicitly.
@_spi(BackendInternals) import ManifoldContract

/// Manages context window budgeting and message trimming.
///
/// Uses a simple character-count heuristic (~4 chars per token) for estimation.
/// A real tokenizer can replace this in a future cycle.
///
/// ## Reservation policy (audit as of 2026-04-20, updated post-#587 fix)
///
/// The trim budget is computed as
/// `available = maxTokens - systemPromptTokens - responseBuffer`, where
/// `responseBuffer` is supplied by the caller. The manager itself has no
/// knowledge of ``GenerationConfig`` — callers derive the buffer from the
/// config before calling in.
///
/// ### Per-caller reservation (post issue #587)
///
/// - `ManifoldUI.GenerationQueue` derives `responseBuffer` from
///   `maxOutputTokens() ?? 2048` + `maxThinkingTokens() ?? 0`, wired up from
///   `ChatViewModel.maxOutputTokens` / `maxThinkingTokens` host-facing settings.
/// - `ManifoldInference.PromptAssembler` still uses a hardcoded default of `512`
///   when no `responseBuffer` is supplied — that default only governs callers
///   that don't pass their own value (tests, diagnostic tooling). Production
///   callers all supply an explicit buffer.
/// - `ManifoldInference.GenerationQueue.exactPreflightAndTrim` reserves
///   `(config.maxOutputTokens ?? 2048) + (config.maxThinkingTokens ?? 0)`.
///   `nil` on `maxThinkingTokens` reserves **zero** rather than a default slice
///   — see "Default policy" below.
/// - `ManifoldBackends.OllamaBackend` reserves thinking budget at the wire layer
///   by sending `num_predict = (maxOutputTokens ?? 2048) + (maxThinkingTokens ??
///   2048)`. That keeps the server from cutting a reasoning model off mid-think,
///   but does **not** feed back into the client-side prompt-trim budget above.
/// - `ManifoldBackends.LlamaGenerationDriver` enforces `config.maxThinkingTokens`
///   as a cap on emitted reasoning tokens only; it does not influence prompt
///   trimming, which happens upstream in the coordinator.
/// - MLX and Foundation backends ignore `maxThinkingTokens` entirely.
///
/// ### Default policy for `maxThinkingTokens == nil`
///
/// A `nil` value is treated as "no client-side cap" rather than "substitute a
/// default reservation". The reservation contribution from thinking is `0`
/// when the caller doesn't set an explicit `N`. Rationale: reserving a
/// non-zero default would silently eat N tokens of every prompt even on
/// non-thinking models where the reservation never gets used — principle of
/// least surprise. Callers driving a reasoning model should set
/// `maxThinkingTokens: N` explicitly; the trim math then reserves `N`
/// tokens so there is headroom for the reasoning block alongside the visible
/// response.
///
/// ### Remaining gaps (tracked separately from #587)
///
/// - ``BackendCapabilities`` still has no `defaultMaxThinkingTokens`. When
///   that lands, coordinators can substitute a per-backend value when the
///   host passes `nil` (Ollama uses `2048` implicitly in `buildRequest`).
/// - P4 introduces `maxThinkingTokens == 0` semantics (Ollama sends
///   `think: false` and drops the thinking component from `num_predict`).
///   Tracked on the upcoming Ollama PR.
public enum ContextWindowManager {

    /// Estimates the token count of a string.
    ///
    /// When a ``TokenizerProvider`` is supplied, it is used for an accurate count.
    /// Otherwise falls back to the ~4 chars-per-token heuristic.
    public static func estimateTokenCount(_ text: String, tokenizer: TokenizerProvider? = nil) -> Int {
        if let tokenizer {
            return tokenizer.tokenCount(text)
        }
        return HeuristicTokenizer().tokenCount(text)
    }

    /// Resolves the effective context size from available sources.
    ///
    /// Priority: session override > model metadata > backend capabilities > default.
    public static func resolveContextSize(
        sessionOverride: Int?,
        modelContextLength: Int?,
        backendMaxTokens: Int?,
        defaultSize: Int = 2048
    ) -> Int {
        sessionOverride ?? modelContextLength ?? backendMaxTokens ?? defaultSize
    }

    /// Trims messages to fit within the context budget.
    ///
    /// Keeps the most recent messages, trimming from the oldest. Always preserves
    /// at least the last user message even if it exceeds the budget.
    ///
    /// - Parameters:
    ///   - messages: All messages to consider, in chronological order.
    ///   - systemPrompt: Optional system prompt that consumes part of the budget.
    ///   - maxTokens: Total context window size in tokens.
    ///   - responseBuffer: Tokens reserved for the model's response.
    ///   - tokenizer: Optional tokenizer for accurate counts. Falls back to heuristic.
    /// - Returns: The subset of messages that fit within the budget.
    public static func trimMessages(
        _ messages: [ChatMessage],
        systemPrompt: String?,
        maxTokens: Int,
        responseBuffer: Int = 512,
        tokenizer: TokenizerProvider? = nil
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }

        let systemTokens = estimateTokenCount(systemPrompt ?? "", tokenizer: tokenizer)
        let available = maxTokens - systemTokens - responseBuffer

        guard available > 0 else {
            // Budget completely consumed by system prompt — return just the last user message
            if let lastUser = messages.last(where: { $0.role == .user }) {
                return [lastUser]
            }
            return Array(messages.suffix(1))
        }

        // Walk backwards from newest, tracking the earliest index to keep.
        // Avoids building a reversed array and re-reversing it.
        var firstKeptIndex = messages.endIndex
        var usedTokens = 0

        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let messageTokens = estimateTokenCount(messages[i].content, tokenizer: tokenizer)
            if usedTokens + messageTokens > available && firstKeptIndex < messages.endIndex {
                break
            }
            firstKeptIndex = i
            usedTokens += messageTokens
        }

        return Array(messages[firstKeptIndex...])
    }

    /// Calculates a context budget breakdown.
    public static func calculateBudget(
        systemPrompt: String?,
        messages: [ChatMessage],
        maxTokens: Int,
        responseBuffer: Int = 512,
        tokenizer: TokenizerProvider? = nil
    ) -> ContextBudget {
        let systemTokens = estimateTokenCount(systemPrompt ?? "", tokenizer: tokenizer)
        let messageTokens = messages.reduce(0) { $0 + estimateTokenCount($1.content, tokenizer: tokenizer) }
        let availableForHistory = maxTokens - systemTokens - responseBuffer

        return ContextBudget(
            maxTokens: maxTokens,
            systemPromptTokens: systemTokens,
            messageTokens: messageTokens,
            availableForHistory: max(0, availableForHistory),
            responseBuffer: responseBuffer
        )
    }
}

/// Breakdown of context token budget allocation.
public struct ContextBudget {
    public let maxTokens: Int
    public let systemPromptTokens: Int
    public let messageTokens: Int
    public let availableForHistory: Int
    public let responseBuffer: Int

    public init(
        maxTokens: Int,
        systemPromptTokens: Int,
        messageTokens: Int,
        availableForHistory: Int,
        responseBuffer: Int
    ) {
        self.maxTokens = maxTokens
        self.systemPromptTokens = systemPromptTokens
        self.messageTokens = messageTokens
        self.availableForHistory = availableForHistory
        self.responseBuffer = responseBuffer
    }

    /// Ratio of used tokens to max tokens (0.0 to 1.0+).
    public var usageRatio: Double {
        guard maxTokens > 0 else { return 0 }
        return Double(systemPromptTokens + messageTokens) / Double(maxTokens)
    }
}
