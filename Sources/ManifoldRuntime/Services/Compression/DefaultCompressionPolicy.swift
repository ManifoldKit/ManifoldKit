import Foundation
import ManifoldInference

/// Batteries-included compression policy. Pairs a ``CompressionStrategy`` with
/// a utilisation threshold and conforms to **both** compression seams —
/// ``CompressionPolicy`` (post-turn) and ``PreTurnCompressionPolicy``
/// (pre-turn) — so one value drives either, or both, without a bespoke
/// conformance.
///
/// Construct via the strategy factories rather than the initializer:
///
/// ```swift
/// // Zero-inference, smart selection. Compress at 75% context utilisation.
/// runtime.compressionPolicy = .extractive(threshold: 0.75, contextSize: 8_192)
///
/// // Inference-backed summary of old turns, kept-recent tail. Pre-turn seam.
/// runtime.preTurnCompressionPolicy = .anchored(threshold: 0.85, contextSize: 8_192)
///
/// // Cheapest baseline: drop oldest, keep system/summary records + newest.
/// runtime.compressionPolicy = .truncating(threshold: 0.90, contextSize: 4_096)
/// ```
///
/// ## Trigger asymmetry
///
/// ``CompressionPolicy/shouldCompress(promptTokens:contextSize:contextUtilization:)``
/// receives utilisation directly. ``PreTurnCompressionPolicy`` does not — its
/// `shouldCompressBeforeTurn` sees only `messageCount` and `lastPromptTokens`,
/// so this policy stores `contextSize` and computes utilisation from
/// `lastPromptTokens / contextSize`. Given equivalent inputs the two seams
/// agree.
public struct DefaultCompressionPolicy: CompressionPolicy, PreTurnCompressionPolicy {
    private let strategy: any CompressionStrategy

    /// Context-utilisation ratio at or above which compression triggers.
    public let threshold: Double
    /// Backend context window (tokens). Held as configuration because the
    /// pre-turn seam does not pass it and the strategy needs it to size budget.
    public let contextSize: Int
    private let tokenizer: (any TokenizerProvider)?

    init(
        strategy: any CompressionStrategy,
        threshold: Double,
        contextSize: Int,
        tokenizer: (any TokenizerProvider)?
    ) {
        self.strategy = strategy
        self.threshold = threshold
        self.contextSize = contextSize
        self.tokenizer = tokenizer
    }

    // MARK: - Factories

    /// Zero-inference sliding window: keep system/summary records + the newest
    /// messages that fit, drop the oldest.
    public static func truncating(
        threshold: Double = 0.90,
        contextSize: Int,
        tokenizer: (any TokenizerProvider)? = nil
    ) -> DefaultCompressionPolicy {
        DefaultCompressionPolicy(
            strategy: TruncatingCompressionStrategy(),
            threshold: threshold, contextSize: contextSize, tokenizer: tokenizer
        )
    }

    /// Zero-inference scored selection (recency / length / keyword density).
    /// `headBudgetFraction > 0` pins the oldest messages to counter the
    /// "lost in the middle" effect.
    public static func extractive(
        threshold: Double = 0.75,
        headBudgetFraction: Double = 0.0,
        contextSize: Int,
        tokenizer: (any TokenizerProvider)? = nil
    ) -> DefaultCompressionPolicy {
        DefaultCompressionPolicy(
            strategy: ExtractiveCompressionStrategy(headBudgetFraction: headBudgetFraction),
            threshold: threshold, contextSize: contextSize, tokenizer: tokenizer
        )
    }

    /// Inference-backed summary of old turns prepended to a verbatim recent
    /// tail. Falls back to extractive when no summary can be produced.
    ///
    /// - Parameter summarizerInputWindow: the summariser's REAL window, used to
    ///   size how much old text it reads — set this to the backend's true
    ///   context size when `contextSize` is a small overflow trigger.
    public static func anchored(
        threshold: Double = 0.85,
        contextSize: Int,
        summarizerInputWindow: Int? = nil,
        summaryTemplate: String? = nil,
        tokenizer: (any TokenizerProvider)? = nil
    ) -> DefaultCompressionPolicy {
        DefaultCompressionPolicy(
            strategy: AnchoredCompressionStrategy(
                summarizerInputWindow: summarizerInputWindow,
                summaryTemplate: summaryTemplate
            ),
            threshold: threshold, contextSize: contextSize, tokenizer: tokenizer
        )
    }

    // MARK: - CompressionPolicy (post-turn)

    public func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
        contextSize > 0 && contextUtilization >= threshold
    }

    public func compress(
        history: [ChatMessage],
        sessionID: UUID,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        try await strategy.compress(
            history: history, contextSize: contextSize,
            tokenizer: tokenizer, generate: generate
        )
    }

    // MARK: - PreTurnCompressionPolicy (pre-turn)

    public func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
        guard contextSize > 0, let promptTokens = lastPromptTokens else { return false }
        return Double(promptTokens) / Double(contextSize) >= threshold
    }

    public func compressBeforeTurn(
        history: [ChatMessage],
        sessionID: UUID,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        try await compress(history: history, sessionID: sessionID, generate: generate)
    }
}
