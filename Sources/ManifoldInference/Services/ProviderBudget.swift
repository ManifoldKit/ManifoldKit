import Foundation

/// Token budget allocated to a single ``PromptContextProvider`` for one turn.
///
/// `allocated` is advisory — a provider MAY return fewer tokens than allocated
/// (``ContextBudgetPlanner`` rolls unused tokens to the next provider) but
/// should not return more (doing so wastes the overflow on low-priority
/// content).
///
/// `totalContextSize` is the full backend context window, available for
/// providers that need to reason about global utilisation ratios rather
/// than absolute counts.
public struct ProviderBudget: Sendable {
    /// Tokens this provider is allowed to consume this turn.
    public let allocated: Int
    /// Full backend context window size (0 = unknown).
    public let totalContextSize: Int

    public init(allocated: Int, totalContextSize: Int) {
        self.allocated = allocated
        self.totalContextSize = totalContextSize
    }

    /// Sentinel used when no budget accounting is required.
    public static let unlimited = ProviderBudget(allocated: Int.max, totalContextSize: 0)
}
