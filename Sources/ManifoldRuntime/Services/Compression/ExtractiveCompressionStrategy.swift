import Foundation
import ManifoldInference

/// Zero-inference scored selection. Reserves a verbatim recency tail (and,
/// optionally, a verbatim head for establishing context), then greedily fills
/// the remaining budget with the highest-scoring older messages. Score blends
/// recency, content length, and capitalized-word density (a cheap proper-noun
/// proxy).
///
/// Adapted from Fireside's `ExtractiveStoryCompressor`. The `headBudgetFraction`
/// knob is new: pinning the oldest messages counters the "lost in the middle"
/// effect, where models attend most to the start and end of context.
struct ExtractiveCompressionStrategy: CompressionStrategy {
    let name = "extractive"

    /// Fraction of the budget reserved for the verbatim recency tail.
    let tailBudgetFraction: Double
    /// Fraction of the budget reserved for a verbatim head (oldest messages).
    /// `0` disables head preservation (Fireside's original behavior).
    let headBudgetFraction: Double
    let recencyWeight: Double
    let lengthWeight: Double
    /// Weight for capitalized-word density. NOTE: this signal assumes
    /// English-like prose where proper nouns and sentence starts are
    /// capitalized. It degrades on all-lowercase text, source code, and
    /// non-cased scripts (CJK), where density trends to ~0 and the term simply
    /// drops out. It is the smallest weight (0.2) precisely so it only *nudges*
    /// selection rather than dominating it.
    let keywordDensityWeight: Double

    /// Combined ceiling for the verbatim head + tail fractions. Past this the
    /// pinned-verbatim core could equal or exceed the whole budget, leaving no
    /// room for scored selection and risking an over-budget result before
    /// scoring even runs.
    static let maxVerbatimCoreFraction = 0.8

    init(
        tailBudgetFraction: Double = 0.40,
        headBudgetFraction: Double = 0.0,
        recencyWeight: Double = 0.5,
        lengthWeight: Double = 0.3,
        keywordDensityWeight: Double = 0.2
    ) {
        self.tailBudgetFraction = tailBudgetFraction
        self.headBudgetFraction = headBudgetFraction
        self.recencyWeight = recencyWeight
        self.lengthWeight = lengthWeight
        self.keywordDensityWeight = keywordDensityWeight
    }

    func compress(
        history: [ChatMessage],
        contextSize: Int,
        reservedTokens: Int,
        tokenizer: (any TokenizerProvider)?,
        isPinned: @Sendable (ChatMessage) -> Bool,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> StrategyCompressionResult {
        guard !history.isEmpty else {
            return StrategyCompressionResult(messages: [], outcome: .notNeeded)
        }

        let budget = historyBudget(contextSize: contextSize, reservedTokens: reservedTokens)
        let tokens = history.map { estimateTokens($0, tokenizer: tokenizer) }
        let originalTokens = tokens.reduce(0, +)

        // Everything fits, or a single message: never evict all history.
        if originalTokens <= budget || history.count == 1 {
            return StrategyCompressionResult(messages: history, outcome: .notNeeded)
        }

        let count = history.count
        var keep = Set<Int>()
        var used = 0

        // Load-bearing records are always kept.
        for i in 0..<count where isLoadBearing(history[i], isPinned: isPinned) {
            keep.insert(i)
            used += tokens[i]
        }

        // Clamp the verbatim core (head + tail) so the two reserved bands can't
        // jointly claim the whole budget and leave nothing for scored selection
        // (or overflow it before scoring runs). Tail keeps priority; head takes
        // whatever remains under the ceiling.
        let coreFraction = min(Self.maxVerbatimCoreFraction, tailBudgetFraction + headBudgetFraction)
        let effectiveTailFraction = min(tailBudgetFraction, coreFraction)
        let effectiveHeadFraction = max(0.0, coreFraction - effectiveTailFraction)

        // --- Verbatim tail (newest) ---
        let tailBudget = Int(Double(budget) * effectiveTailFraction)
        var tailUsed = 0
        for i in stride(from: count - 1, through: 0, by: -1) {
            if keep.contains(i) { continue }
            if tailUsed + tokens[i] <= tailBudget || keep.isEmpty {
                keep.insert(i)
                tailUsed += tokens[i]
                used += tokens[i]
            }
            if tailUsed >= tailBudget { break }
        }
        // Always preserve the newest message.
        if !keep.contains(count - 1) {
            keep.insert(count - 1)
            used += tokens[count - 1]
        }

        // --- Verbatim head (oldest) — anti "lost in the middle" ---
        if effectiveHeadFraction > 0 {
            let headBudget = Int(Double(budget) * effectiveHeadFraction)
            var headUsed = 0
            for i in 0..<count {
                if keep.contains(i) { continue }
                if headUsed + tokens[i] <= headBudget {
                    keep.insert(i)
                    headUsed += tokens[i]
                    used += tokens[i]
                }
                if headUsed >= headBudget { break }
            }
        }

        // --- Score and greedily select the remainder ---
        struct Scored { let index: Int; let score: Double; let tokens: Int }
        var candidates: [Scored] = []
        for i in 0..<count where !keep.contains(i) {
            let recency = count > 1 ? Double(i) / Double(count - 1) : 1.0
            let length = min(1.0, Double(tokens[i]) / 200.0)
            let density = keywordDensity(of: history[i].content)
            let score = recency * recencyWeight + length * lengthWeight + density * keywordDensityWeight
            candidates.append(Scored(index: i, score: score, tokens: tokens[i]))
        }
        candidates.sort { $0.score > $1.score }

        for candidate in candidates {
            if used + candidate.tokens <= budget {
                keep.insert(candidate.index)
                used += candidate.tokens
            }
        }

        // Final budget enforcement: the verbatim tail/head admission can push
        // the union over budget when those bands admit large messages (each
        // band only checks its own sub-budget). Evict kept non-load-bearing
        // messages — oldest first, but never the newest — until the union fits.
        // Load-bearing records are never evicted (they survive regardless of
        // budget by contract).
        if used > budget {
            let newest = count - 1
            for i in 0..<count where keep.contains(i) {
                if used <= budget { break }
                if i == newest { continue }
                if isLoadBearing(history[i], isPinned: isPinned) { continue }
                keep.remove(i)
                used -= tokens[i]
            }
        }

        // Every message survived (all load-bearing/pinned, or the greedy
        // selection happened to re-admit everything) — nothing was actually
        // dropped even though the input was over budget.
        let outcome: CompressionOutcome = keep.count == count ? .nothingToSummarize : .reduced(strategyName: name)
        return StrategyCompressionResult(messages: keep.sorted().map { history[$0] }, outcome: outcome)
    }

    /// Ratio of capitalized words to total words — a rough proper-noun proxy.
    private func keywordDensity(of content: String) -> Double {
        let words = content.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return 0 }
        let capitalized = words.filter { $0.first?.isUppercase == true }.count
        return Double(capitalized) / Double(words.count)
    }
}
