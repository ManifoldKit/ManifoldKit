import Foundation
import ManifoldInference

/// Batteries-included compression policy. Pairs a ``CompressionStrategy`` with
/// a utilisation threshold and conforms to **both** compression seams —
/// ``CompressionPolicy`` (post-turn) and ``PreTurnCompressionPolicy``
/// (pre-turn) — so one value drives either, or both, without a bespoke
/// conformance.
///
/// Construct via the strategy factories rather than the initializer, and inject
/// the policy through ``ConversationRuntimeOptions`` (or the matching
/// `ConversationRuntime` init parameter) — there is no mutable
/// `runtime.compressionPolicy` property:
///
/// ```swift
/// // Zero-inference, smart selection. Compress at 75% context utilisation.
/// let options = ConversationRuntimeOptions(
///     compressionPolicy: .extractive(threshold: 0.75, contextSize: 8_192)
/// )
///
/// // Cheapest baseline: drop oldest, keep system/summary records + newest.
/// let truncating = ConversationRuntimeOptions(
///     compressionPolicy: .truncating(threshold: 0.90, contextSize: 4_096)
/// )
///
/// // Inference-backed summary of old turns, kept-recent tail. Prefer the
/// // POST-turn seam: anchored runs a full summariser round-trip, and on the
/// // pre-turn seam that latency lands before the user's message even renders.
/// let anchored = ConversationRuntimeOptions(
///     compressionPolicy: .anchored(threshold: 0.85, contextSize: 8_192)
/// )
///
/// // For the PRE-turn seam, prefer a zero-inference strategy so turn setup
/// // pays no summariser latency:
/// let preTurn = ConversationRuntimeOptions(
///     preTurnCompressionPolicy: .extractive(threshold: 0.85, contextSize: 8_192)
/// )
/// ```
///
/// ## Budget realism (#1957)
///
/// The protocol `compress` signatures now pass the turn's real wire
/// `systemPrompt`, so this policy's history budget is
/// `contextSize − reservedTokens − systemPromptTokens` — `reservedTokens` is
/// **response headroom only** (no more blind system-prompt allowance folded
/// in), and `systemPromptTokens` is the ACTUAL wire system prompt measured
/// with `tokenizer`.
///
/// **Migration:** if you previously inflated `reservedTokens` to cover an
/// estimated system prompt (the Fireside pattern), pass `systemPrompt` **and
/// shrink `reservedTokens`** to response-only headroom. Keeping the inflated
/// reservation while also subtracting `systemPrompt` double-counts.
///
/// ### Residual: construction-time tokenizer / model swap
///
/// The tokenizer stays **construction-injected** (pass a real `tokenizer:` to
/// the factories for a guaranteed budget); there is no call-time tokenizer
/// override. With `tokenizer: nil` the whole budget, system prompt included,
/// is **advisory** (a chars/4 heuristic that can diverge from the backend's
/// real token count that drives the trigger). The same hole applies on
/// **model swap**: a `DefaultCompressionPolicy` built against backend A's
/// tokenizer keeps that tokenizer after the host switches to backend B —
/// rebuild the policy (or accept advisory chars/4) when the active model's
/// tokenizer changes.
///
/// ## Trigger asymmetry
///
/// ``CompressionPolicy/shouldCompress(promptTokens:contextSize:contextUtilization:)``
/// receives utilisation directly. ``PreTurnCompressionPolicy`` does not — its
/// `shouldCompressBeforeTurn` sees only `messageCount` and `lastPromptTokens`,
/// so this policy stores `contextSize` and computes utilisation from
/// `lastPromptTokens / contextSize`. The two can disagree at the boundary by a
/// rounding margin: a post-turn caller that hands in an already-rounded
/// utilisation may cross the threshold while the pre-turn recompute from raw
/// `lastPromptTokens` stays just below it.
///
/// ## Outcome observability (#2203) and message pinning (#2204)
///
/// `compress`/`compressBeforeTurn` still return bare `[ChatMessage]` — the
/// `CompressionPolicy`/`PreTurnCompressionPolicy` protocol shape is unchanged
/// — but the factories accept `onOutcome` and `isPinned` so a consumer that
/// constructs a `DefaultCompressionPolicy` directly (this is the layer
/// Fireside's `DefaultCompressionPolicy` adoption, roryford/fireside#910,
/// consumes) can observe what happened and pin messages without record-shape
/// heuristics or squatting on the `.memory` kind namespace:
///
/// ```swift
/// let policy = DefaultCompressionPolicy.anchored(
///     threshold: 0.85, contextSize: 8_192,
///     isPinned: { message in session.pinnedMessageIDs.contains(message.id) },
///     onOutcome: { outcome in
///         switch outcome {
///         case .summarized(let tokens): logSummary(tokens: tokens)
///         case .fallbackUsed(let reason): logFallback(reason: reason)
///         case .cancelled: break // turn cancelled mid-summarise; not an error
///         case .skippedInsufficientBudget, .nothingToSummarize, .notNeeded: break
///         case .reduced(let strategyName): logReduced(strategyName)
///         }
///     }
/// )
/// ```
///
/// `isPinned` is evaluated fresh on every `compress` call (it's a closure,
/// not a captured snapshot) — capture a live source of truth (e.g. the
/// session object itself) rather than a `Set<UUID>` copy that goes stale.
public struct DefaultCompressionPolicy: CompressionPolicy, PreTurnCompressionPolicy {
    private let strategy: any CompressionStrategy

    /// Context-utilisation ratio at or above which compression triggers.
    public let threshold: Double
    /// Backend context window (tokens). Held as configuration because the
    /// pre-turn seam does not pass it and the strategy needs it to size budget.
    public let contextSize: Int
    /// Tokens reserved out of `contextSize` before history is sized: response
    /// headroom only (#1957) — the session's real system-prompt cost is
    /// measured separately from the `systemPrompt` passed into `compress`
    /// and subtracted on top of this reservation, not folded into it.
    public let reservedTokens: Int
    private let tokenizer: (any TokenizerProvider)?
    /// Predicate honored alongside `.system`-role / `.memory`-kind records as
    /// load-bearing (#2204) — lets a consumer pin a message through
    /// compression without mutating it or squatting on the `.memory` kind
    /// namespace the anchored strategy uses for its own summary records.
    /// `nil` (the default) preserves pre-#2204 behavior.
    private let isPinned: (@Sendable (ChatMessage) -> Bool)?
    /// Fires with the ``CompressionOutcome`` classification every time
    /// `compress`/`compressBeforeTurn` runs, including the budget-skip case
    /// this policy handles itself (#2203). `nil` (the default) is a no-op.
    private let onOutcome: (@Sendable (CompressionOutcome) -> Void)?

    /// Default reservation when a caller doesn't override it.
    ///
    /// The legacy value was a bare `512`, which only covered a short response
    /// and left **nothing** for the session system prompt. Since #1957 the
    /// real system prompt is measured separately and subtracted from the
    /// history budget on top of this reservation (`compress` now receives
    /// `systemPrompt`), so `reservedTokens` need only cover response headroom
    /// — but `2048` is kept as the default because it still matches the
    /// `maxOutputTokens ?? 2048` default that `GenerationQueue` /
    /// `PromptAssembler` already reserve at the wire layer, so the trigger and
    /// the budget agree on roughly the same headroom, and the extra margin is
    /// cheap insurance against a system prompt measured with the chars/4
    /// heuristic (no `tokenizer` injected) underestimating its real cost.
    /// Reasoning models that emit thousands of thinking tokens should raise
    /// this further (see ``scaledReservedTokens(forContextSize:base:)``) — a
    /// too-small reserve is the classic thinking-model overflow.
    public static let defaultReservedTokens = 2_048

    /// A context-scaled reservation: never below `base`, and at least ~12.5% of
    /// the window so large contexts leave proportional response/thinking
    /// headroom. Capped at half the window so a tiny `base` can't starve
    /// history on small contexts. Use this for reasoning models.
    public static func scaledReservedTokens(
        forContextSize contextSize: Int,
        base: Int = defaultReservedTokens
    ) -> Int {
        let scaled = max(base, contextSize / 8)
        return min(scaled, max(base, contextSize / 2))
    }

    init(
        strategy: any CompressionStrategy,
        threshold: Double,
        contextSize: Int,
        reservedTokens: Int,
        tokenizer: (any TokenizerProvider)?,
        isPinned: (@Sendable (ChatMessage) -> Bool)? = nil,
        onOutcome: (@Sendable (CompressionOutcome) -> Void)? = nil
    ) {
        self.strategy = strategy
        self.threshold = threshold
        self.contextSize = contextSize
        self.reservedTokens = reservedTokens
        self.tokenizer = tokenizer
        self.isPinned = isPinned
        self.onOutcome = onOutcome
    }

    // MARK: - Factories

    /// Zero-inference sliding window: keep system/summary records + the newest
    /// messages that fit, drop the oldest.
    ///
    /// - Parameters:
    ///   - reservedTokens: Response headroom only — tokens carved from
    ///     `contextSize` before history is sized (default
    ///     ``defaultReservedTokens``). System-prompt cost is subtracted
    ///     separately from the `systemPrompt` passed to `compress` (#1957);
    ///     do not fold an estimated system allowance in here or you
    ///     double-count.
    ///   - tokenizer: Inject the backend's tokenizer for a guaranteed budget;
    ///     `nil` (default) makes the budget advisory (chars/4 heuristic).
    ///   - isPinned: Predicate marking a message load-bearing regardless of
    ///     role/kind (#2204), e.g.
    ///     `{ message in session.pinnedMessageIDs.contains(message.id) }`.
    ///   - onOutcome: Fires with the ``CompressionOutcome`` classification on
    ///     every `compress` call (#2203).
    public static func truncating(
        threshold: Double = 0.90,
        contextSize: Int,
        reservedTokens: Int = defaultReservedTokens,
        tokenizer: (any TokenizerProvider)? = nil,
        isPinned: (@Sendable (ChatMessage) -> Bool)? = nil,
        onOutcome: (@Sendable (CompressionOutcome) -> Void)? = nil
    ) -> DefaultCompressionPolicy {
        DefaultCompressionPolicy(
            strategy: TruncatingCompressionStrategy(),
            threshold: threshold, contextSize: contextSize,
            reservedTokens: reservedTokens, tokenizer: tokenizer,
            isPinned: isPinned, onOutcome: onOutcome
        )
    }

    /// Zero-inference scored selection (recency / length / keyword density).
    /// `headBudgetFraction > 0` pins the oldest messages to counter the
    /// "lost in the middle" effect.
    ///
    /// - Parameters:
    ///   - reservedTokens: Response headroom only (#1957) — see
    ///     ``truncating(threshold:contextSize:reservedTokens:tokenizer:isPinned:onOutcome:)``.
    ///   - isPinned: Predicate marking a message load-bearing regardless of
    ///     role/kind (#2204), e.g.
    ///     `{ message in session.pinnedMessageIDs.contains(message.id) }`.
    ///   - onOutcome: Fires with the ``CompressionOutcome`` classification on
    ///     every `compress` call (#2203).
    public static func extractive(
        threshold: Double = 0.75,
        headBudgetFraction: Double = 0.0,
        contextSize: Int,
        reservedTokens: Int = defaultReservedTokens,
        tokenizer: (any TokenizerProvider)? = nil,
        isPinned: (@Sendable (ChatMessage) -> Bool)? = nil,
        onOutcome: (@Sendable (CompressionOutcome) -> Void)? = nil
    ) -> DefaultCompressionPolicy {
        DefaultCompressionPolicy(
            strategy: ExtractiveCompressionStrategy(headBudgetFraction: headBudgetFraction),
            threshold: threshold, contextSize: contextSize,
            reservedTokens: reservedTokens, tokenizer: tokenizer,
            isPinned: isPinned, onOutcome: onOutcome
        )
    }

    /// Inference-backed summary of old turns prepended to a verbatim recent
    /// tail. Falls back to extractive when no summary can be produced.
    ///
    /// Prefer the **post-turn** seam for anchored: it runs a full summariser
    /// round-trip, and on the pre-turn seam that latency is paid before the
    /// user's just-typed message renders.
    ///
    /// - Parameters:
    ///   - reservedTokens: Response headroom only (#1957) — see
    ///     ``truncating(threshold:contextSize:reservedTokens:tokenizer:isPinned:onOutcome:)``.
    ///     Also threaded to the summariser as its response buffer.
    ///   - summarizerInputWindow: the summariser's REAL window, used to size how
    ///     much old text it reads — set this to the backend's true context size
    ///     when `contextSize` is a small overflow trigger.
    ///   - summaryTemplate: custom prompt. Note the coupling with
    ///     `parseSummaryResponse`: a custom template should emit
    ///     `UPPERCASE-FIELD: value` lines (≥2) or the parser degrades to a
    ///     raw-truncated brief. `{old_text}` is the substitution placeholder.
    ///   - isPinned: Predicate marking a message load-bearing regardless of
    ///     role/kind (#2204), e.g.
    ///     `{ message in session.pinnedMessageIDs.contains(message.id) }`.
    ///   - onOutcome: Fires with the ``CompressionOutcome`` classification on
    ///     every `compress` call — distinguishes summarized / fallback /
    ///     cancelled / nothing-to-summarize (#2203).
    public static func anchored(
        threshold: Double = 0.85,
        contextSize: Int,
        reservedTokens: Int = defaultReservedTokens,
        summarizerInputWindow: Int? = nil,
        summaryTemplate: String? = nil,
        tokenizer: (any TokenizerProvider)? = nil,
        isPinned: (@Sendable (ChatMessage) -> Bool)? = nil,
        onOutcome: (@Sendable (CompressionOutcome) -> Void)? = nil
    ) -> DefaultCompressionPolicy {
        DefaultCompressionPolicy(
            strategy: AnchoredCompressionStrategy(
                summarizerResponseBuffer: reservedTokens,
                summarizerInputWindow: summarizerInputWindow,
                summaryTemplate: summaryTemplate
            ),
            threshold: threshold, contextSize: contextSize,
            reservedTokens: reservedTokens, tokenizer: tokenizer,
            isPinned: isPinned, onOutcome: onOutcome
        )
    }

    // MARK: - CompressionPolicy (post-turn)

    public func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
        contextSize > 0 && contextUtilization >= threshold
    }

    public func compress(
        history: [ChatMessage],
        sessionID: UUID,
        systemPrompt: String?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        // Guard the degenerate window: if the reservation (response headroom
        // + the REAL system-prompt cost, #1957) meets or exceeds the context
        // the history budget is zero, and every pass would report "over
        // budget" forever (the 512-token simulator cap is the canonical
        // trap). Skip rather than churn.
        let systemPromptTokens = ContextWindowManager.estimateTokenCount(systemPrompt ?? "", tokenizer: tokenizer)
        guard contextSize > reservedTokens + systemPromptTokens else {
            Log.inference.warning(
                "[Compression] contextSize \(contextSize) <= reservedTokens \(reservedTokens) + systemPromptTokens \(systemPromptTokens); skipping compression (no usable history budget)"
            )
            onOutcome?(.skippedInsufficientBudget)
            return history
        }
        let result = try await strategy.compress(
            history: history, contextSize: contextSize,
            reservedTokens: reservedTokens, systemPrompt: systemPrompt, tokenizer: tokenizer,
            isPinned: isPinned ?? { _ in false }, generate: generate
        )
        onOutcome?(result.outcome)
        return result.messages
    }

    // MARK: - PreTurnCompressionPolicy (pre-turn)

    public func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
        guard contextSize > 0, let promptTokens = lastPromptTokens else { return false }
        return Double(promptTokens) / Double(contextSize) >= threshold
    }

    public func compressBeforeTurn(
        history: [ChatMessage],
        sessionID: UUID,
        systemPrompt: String?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        try await compress(history: history, sessionID: sessionID, systemPrompt: systemPrompt, generate: generate)
    }
}
