import Foundation
import BaseChatInference

/// Composes a list of ``PromptContextProvider``s into a single sorted
/// ``[PromptSlot]`` for prompt assembly.
///
/// The pipeline is a passive merge: it asks each registered provider for its
/// slots, concatenates the results, and sorts by
/// ``PromptSlotPosition/sortIndex(messageCount:)``. Provider errors propagate
/// out of ``assemble(messageCount:)`` and abort assembly — the pipeline does
/// not return a partial result.
///
/// Providers are queried sequentially in registration order. Concurrent fan-out
/// would invent ordering risk for ties (positions that share a sort index rely
/// on the input array's order to remain stable across runs); the sequential
/// hop is cheap because providers are typically I/O-light.
///
/// ## Topology
///
/// `PromptContextPipeline` is the slot-merge layer. It does not perform budget
/// allocation, token counting, or message trimming — that work belongs to
/// `PromptAssembler` (in `BaseChatInference`). Consumers that want a richer
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
        var merged: [PromptSlot] = []
        for provider in providers {
            let contribution = try await provider.contributeSlots(messageCount: messageCount)
            merged.append(contentsOf: contribution)
        }
        return merged.sorted { lhs, rhs in
            lhs.position.sortIndex(messageCount: messageCount) <
                rhs.position.sortIndex(messageCount: messageCount)
        }
    }
}
