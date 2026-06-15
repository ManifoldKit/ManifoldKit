import Foundation
import ManifoldInference

/// Zero-inference sliding window. Keeps every load-bearing record
/// (`.system` / `.memory`) plus the newest messages that fit the budget,
/// dropping the oldest. The cheapest possible strategy and a safe default when
/// no summariser is available.
struct TruncatingCompressionStrategy: CompressionStrategy {
    let name = "truncating"

    func compress(
        history: [ChatMessage],
        contextSize: Int,
        reservedTokens: Int,
        tokenizer: (any TokenizerProvider)?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        guard !history.isEmpty else { return [] }

        let budget = historyBudget(contextSize: contextSize, reservedTokens: reservedTokens)
        if estimateTokens(history, tokenizer: tokenizer) <= budget {
            return history
        }

        var kept = Set<Int>()
        var used = 0

        // Load-bearing records are always retained.
        for (i, message) in history.enumerated() where isLoadBearing(message) {
            kept.insert(i)
            used += estimateTokens(message, tokenizer: tokenizer)
        }

        // Fill remaining budget with the newest non-kept messages.
        for i in stride(from: history.count - 1, through: 0, by: -1) {
            if kept.contains(i) { continue }
            let cost = estimateTokens(history[i], tokenizer: tokenizer)
            if kept.isEmpty || used + cost <= budget {
                kept.insert(i)
                used += cost
            }
        }

        // Invariant: never drop the newest message.
        kept.insert(history.count - 1)

        return kept.sorted().map { history[$0] }
    }
}
