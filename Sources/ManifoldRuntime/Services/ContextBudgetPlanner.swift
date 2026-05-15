import Foundation
import ManifoldInference

/// An entry in a ``ContextBudgetPlanner``.
public struct ContextBudgetEntry: Sendable {
    public let provider: any PromptContextProvider
    /// Relative weight for budget allocation. Higher weight = more tokens.
    /// Default 1.0. All weights are normalised together.
    public let budgetWeight: Double

    public init(provider: any PromptContextProvider, budgetWeight: Double = 1.0) {
        self.provider = provider
        self.budgetWeight = max(0, budgetWeight)
    }
}

/// Allocates a token budget proportionally across providers with spillover.
///
/// ## Allocation algorithm
/// 1. Normalise weights: `share_i = weight_i / sum(weights)`.
/// 2. Allocate `floor(totalBudget * share_i)` to each provider.
/// 3. Call providers sequentially in registration order.
/// 4. Track slots returned by each provider; estimate their token cost via
///    the ``TurnContext`` tokenizer (falls back to ``HeuristicTokenizer``).
/// 5. Roll any unused budget from provider i to provider i+1.
///
/// Spillover means a provider that returns nothing (e.g. no matching entities)
/// donates its entire allocation to the next provider — the same behaviour
/// Fireside's `StoryContextBudget` implements.
public struct ContextBudgetPlanner: Sendable {
    private let entries: [ContextBudgetEntry]

    public init(entries: [ContextBudgetEntry]) {
        self.entries = entries
    }

    /// Plans allocations, calls each provider with its budget, and returns
    /// merged slots sorted by ``PromptSlotPosition/sortIndex(messageCount:)``.
    ///
    /// - Parameters:
    ///   - totalBudget: Total tokens available for all providers combined.
    ///   - contextSize: Full backend context window (forwarded to ``ProviderBudget``).
    ///   - context: Turn-level context passed verbatim to each provider.
    /// - Returns: Merged, sorted slots from all providers.
    /// - Throws: Whatever a provider throws; assembly aborts on first failure.
    public func assemble(
        totalBudget: Int,
        contextSize: Int,
        context: TurnContext
    ) async throws -> [PromptSlot] {
        guard !entries.isEmpty else { return [] }

        let tok: any TokenizerProvider = context.tokenizer ?? HeuristicTokenizer()
        let totalWeight = entries.map(\.budgetWeight).reduce(0, +)
        let safeTotal = max(1.0, totalWeight)

        var merged: [PromptSlot] = []
        var remainingBudget = totalBudget

        for entry in entries {
            let share = entry.budgetWeight / safeTotal
            // Guard against Int overflow when totalBudget is Int.max (the
            // "no budget cap" sentinel). Double(Int.max) rounds up to 2^63,
            // and Int(2^63) traps. Clamp the intermediate Double to
            // Double(Int.max - 1) before converting so the result is always
            // representable regardless of share or totalBudget magnitude.
            let rawShare = Double(totalBudget) * share
            let safePlanned = rawShare >= Double(Int.max) ? Int.max : Int(rawShare)
            let planned = min(remainingBudget, safePlanned)
            let budget = ProviderBudget(allocated: max(0, planned), totalContextSize: contextSize)

            let slots = try await entry.provider.contributeSlots(budget: budget, context: context)

            // Measure actual cost from returned slots so spillover is accurate.
            // When a provider returns fewer tokens than planned, the difference
            // rolls forward and widens the next provider's effective budget.
            let used = slots.reduce(0) { acc, slot in
                let raw = tok.tokenCount(slot.content)
                let capped = slot.tokenBudget.map { min(raw, $0) } ?? raw
                return acc + capped
            }
            remainingBudget = max(0, remainingBudget - used)
            merged.append(contentsOf: slots)
        }

        let mc = context.messageCount
        return merged.sorted {
            $0.position.sortIndex(messageCount: mc) < $1.position.sortIndex(messageCount: mc)
        }
    }
}
