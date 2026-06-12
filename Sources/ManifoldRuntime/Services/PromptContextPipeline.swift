import Foundation
import ManifoldInference

/// Composes a list of ``PromptContextProvider``s into a single sorted
/// ``[PromptSlot]`` for prompt assembly.
///
/// The pipeline is a passive merge: it asks each registered provider for its
/// slots, concatenates the results, and sorts by
/// ``PromptSlotPosition/sortIndex(messageCount:)``. Provider errors propagate
/// out of ``assemble(messageCount:)`` and abort assembly — the pipeline does
/// not return a partial result.
///
/// Providers are queried concurrently (fanned out via a throwing task group),
/// but their contributions are reassembled in registration order before
/// sorting. This preserves the tie-break contract — positions that share a
/// sort index keep registration order — while collapsing wall time from the
/// sum of provider latencies to roughly the slowest single provider. Providers
/// are typically I/O-bound (retrieval, DB reads, RPC), so the fan-out is a
/// direct latency win.
///
/// ## Topology
///
/// `PromptContextPipeline` is the slot-merge layer. It does not perform budget
/// allocation, token counting, or message trimming — that work belongs to
/// `PromptAssembler` (in `ManifoldInference`). Consumers that want a richer
/// aggregate (Fireside's `ContextContribution` with `realCost` accounting) keep
/// that aggregate in their own module. BCK ships the boundary primitive here.
///
/// ## Example
///
/// ```swift
/// let pipeline = PromptContextPipeline(providers: [
///     systemPromptProvider,
///     loreProvider,
///     retrievalProvider,
/// ])
/// let slots = try await pipeline.assemble(messageCount: history.count)
/// ```
///
/// > Note: Phase 1.2 sub-step 2 ships the use case in isolation; sub-step 5
/// > wires it into `ConversationRuntime`.
public final class PromptContextPipeline: Sendable {
    private let providers: [any PromptContextProvider]

    /// Creates a pipeline that queries `providers` in registration order.
    ///
    /// - Parameter providers: The providers to compose. An empty array is a
    ///   valid pipeline that always returns `[]`.
    public init(providers: [any PromptContextProvider]) {
        self.providers = providers
    }

    /// Asks each registered provider for its slots, concatenates the results,
    /// and returns them sorted by
    /// ``PromptSlotPosition/sortIndex(messageCount:)``.
    ///
    /// - Parameter messageCount: The conversation message count at assembly
    ///   time. Forwarded verbatim to every provider so that
    ///   ``PromptSlotPosition/atDepth(_:)`` can compute its sort index against
    ///   the same baseline the consumer is about to render against.
    /// - Returns: All contributed slots, sorted top-to-bottom (lowest sort
    ///   index first). Slots whose positions tie keep their concatenation
    ///   order — this is whatever `Array.sorted(by:)` gives, which is stable
    ///   on the standard library implementation BCK targets.
    /// - Throws: Whatever a provider throws. The pipeline aborts immediately
    ///   on the first failure and does not return a partial result.
    public func assemble(messageCount: Int) async throws -> [PromptSlot] {
        let merged = try await fanOut { provider in
            try await provider.contributeSlots(messageCount: messageCount)
        }
        return merged.sorted { lhs, rhs in
            lhs.position.sortIndex(messageCount: messageCount) <
                rhs.position.sortIndex(messageCount: messageCount)
        }
    }

    /// Budget-aware assembly. Passes each provider a ``ProviderBudget`` with
    /// `allocated = totalBudget` (the full shared budget, not split per-provider).
    ///
    /// This overload is the lightweight path for callers that have a total token
    /// budget but don't need per-provider weight splitting. Providers that
    /// override ``PromptContextProvider/contributeSlots(budget:context:)``
    /// receive the budget and can adjust their output accordingly. Providers
    /// that use the default implementation receive only the message count,
    /// identical to ``assemble(messageCount:)``.
    ///
    /// For proportional per-provider allocation (weight-split with spillover),
    /// use ``ContextBudgetPlanner`` directly instead.
    ///
    /// - Parameters:
    ///   - totalBudget: Token cap available to the whole pipeline this turn.
    ///   - contextSize: Full backend context window (forwarded to ``ProviderBudget``).
    ///   - context: Turn-level context forwarded verbatim to every provider.
    /// - Returns: All contributed slots, sorted top-to-bottom.
    /// - Throws: Whatever a provider throws; assembly aborts on first failure.
    public func assemble(
        totalBudget: Int,
        contextSize: Int,
        context: TurnContext
    ) async throws -> [PromptSlot] {
        let budget = ProviderBudget(allocated: totalBudget, totalContextSize: contextSize)
        let merged = try await fanOut { provider in
            try await provider.contributeSlots(budget: budget, context: context)
        }
        let mc = context.messageCount
        return merged.sorted {
            $0.position.sortIndex(messageCount: mc) < $1.position.sortIndex(messageCount: mc)
        }
    }

    /// Runs `contribute` against every provider concurrently, then reassembles
    /// the per-provider contributions in registration order and flattens them.
    ///
    /// Ordering is preserved by tagging each task with the provider's index and
    /// reordering completion results by that index before flattening — the
    /// task group yields results in completion order, which is non-deterministic.
    /// Restoring registration order keeps the tie-break contract that callers
    /// rely on (slots sharing a sort index stay in registration order).
    ///
    /// `contribute` is `@Sendable`: each provider runs in its own child task, so
    /// the closure and its captures cross the task-group isolation boundary.
    private func fanOut(
        _ contribute: @Sendable @escaping (any PromptContextProvider) async throws -> [PromptSlot]
    ) async throws -> [PromptSlot] {
        // Single-provider (and empty) pipelines skip the task-group overhead.
        if providers.count <= 1 {
            var merged: [PromptSlot] = []
            for provider in providers {
                merged.append(contentsOf: try await contribute(provider))
            }
            return merged
        }

        let indexed = try await withThrowingTaskGroup(
            of: (Int, [PromptSlot]).self
        ) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    (index, try await contribute(provider))
                }
            }
            var collected: [(Int, [PromptSlot])] = []
            collected.reserveCapacity(providers.count)
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        return indexed
            .sorted { $0.0 < $1.0 }
            .flatMap { $0.1 }
    }
}
