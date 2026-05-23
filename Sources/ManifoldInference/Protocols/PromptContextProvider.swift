import Foundation

/// A source of prompt context slots for assembly into a generation request.
///
/// Conformers contribute slots based on conversation state; ``PromptContextPipeline``
/// (in `ManifoldCore`) composes multiple providers into a single sorted
/// ``[PromptSlot]``.
///
/// This is a low-level boundary primitive. Consumers that need richer aggregate
/// types (budget accounting, cost tracking) layer those on top in their own
/// modules — see Fireside's `ContextContribution` for prior art.
public protocol PromptContextProvider: Sendable {
    /// Slots to inject into the next prompt.
    ///
    /// - Parameter messageCount: The conversation message count at assembly time.
    ///   Enables ``PromptSlotPosition/atDepth(_:)`` to compute its sort index.
    /// - Returns: The slots this provider contributes for the upcoming turn.
    /// - Throws: Errors propagate to ``PromptContextPipeline`` and abort assembly;
    ///   surfaces that need partial-failure semantics compose at the use-case
    ///   layer instead.
    func contributeSlots(messageCount: Int) async throws -> [PromptSlot]

    /// Budget-aware variant. Called by ``ContextBudgetPlanner`` and the
    /// ``PromptContextPipeline/assemble(totalBudget:contextSize:context:)``
    /// overload. The default implementation delegates to
    /// ``contributeSlots(messageCount:)`` so existing conformers require no
    /// changes — the budget parameter is ignored by the default.
    ///
    /// Override this when the provider needs to vary how many or which slots
    /// it returns based on remaining token capacity, e.g. truncating a
    /// retrieved passage list or skipping low-priority lore when the budget
    /// is tight.
    func contributeSlots(budget: ProviderBudget, context: TurnContext) async throws -> [PromptSlot]
}

extension PromptContextProvider {
    public func contributeSlots(budget: ProviderBudget, context: TurnContext) async throws -> [PromptSlot] {
        try await contributeSlots(messageCount: context.messageCount)
    }
}
