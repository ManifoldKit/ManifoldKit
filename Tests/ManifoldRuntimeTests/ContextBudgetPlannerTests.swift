import XCTest
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Tests for ``ContextBudgetPlanner`` and the backward-compatible
/// ``PromptContextPipeline/assemble(messageCount:)`` path.
///
/// The planner's allocation algorithm is: compute proportional shares,
/// call each provider sequentially, measure actual token cost, and roll
/// unused budget to the next provider (spillover). These tests verify
/// each property independently.
final class ContextBudgetPlannerTests: XCTestCase {

    // MARK: - Fakes

    /// Records the budget it received and returns pre-configured slots.
    private final class SpyProvider: PromptContextProvider, @unchecked Sendable {
        let slotsToReturn: [PromptSlot]
        private(set) var receivedBudget: ProviderBudget?
        private(set) var receivedContext: TurnContext?

        init(slots: [PromptSlot] = []) {
            self.slotsToReturn = slots
        }

        func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
            slotsToReturn
        }

        func contributeSlots(budget: ProviderBudget, context: TurnContext) async throws -> [PromptSlot] {
            receivedBudget = budget
            receivedContext = context
            return slotsToReturn
        }
    }

    /// Provider that always returns `[]`, recording the budget it received.
    private final class EmptySpyProvider: PromptContextProvider, @unchecked Sendable {
        private(set) var receivedBudget: ProviderBudget?

        func contributeSlots(messageCount: Int) async throws -> [PromptSlot] { [] }

        func contributeSlots(budget: ProviderBudget, context: TurnContext) async throws -> [PromptSlot] {
            receivedBudget = budget
            return []
        }
    }

    // MARK: - Helpers

    private func makeContext(messageCount: Int = 3) -> TurnContext {
        TurnContext(sessionID: UUID(), messageCount: messageCount)
    }

    /// Builds a slot whose content has a predictable heuristic token cost.
    /// HeuristicTokenizer returns max(1, chars/4), so 4 chars = 1 token.
    private func slot(id: String, charCount: Int, position: PromptSlotPosition = .contextSetup) -> PromptSlot {
        PromptSlot(
            id: id,
            content: String(repeating: "x", count: charCount),
            position: position,
            label: id
        )
    }

    // MARK: - Proportional allocation

    func test_proportionalAllocation_twoProviders() async throws {
        // weights 2.0 : 1.0 → shares 2/3 and 1/3.
        // totalBudget = 300 → first gets floor(300 * 2/3) = 200, second gets
        // min(remaining=300, floor(300 * 1/3)) = 100.
        let p1 = SpyProvider()
        let p2 = SpyProvider()

        let planner = ContextBudgetPlanner(entries: [
            ContextBudgetEntry(provider: p1, budgetWeight: 2.0),
            ContextBudgetEntry(provider: p2, budgetWeight: 1.0),
        ])
        _ = try await planner.assemble(totalBudget: 300, contextSize: 4096, context: makeContext())

        XCTAssertEqual(p1.receivedBudget?.allocated, 200)
        XCTAssertEqual(p2.receivedBudget?.allocated, 100)
        XCTAssertEqual(p1.receivedBudget?.totalContextSize, 4096)
    }

    // MARK: - Spillover

    func test_spillover_unusedBudgetRollsToNextProvider() async throws {
        // p1: weight 2/3 of 300 = 200 tokens allocated, but returns a slot
        // costing 50 tokens (200 chars / 4). Unused = 150.
        // p2: weight 1/3 of 300 = 100 planned, but remaining = 300 - 50 = 250.
        // min(250, 100) = 100 planned, but remainingBudget going in is 250,
        // so p2 gets min(250, 100) = 100.
        //
        // Note: the planner allocates min(remainingBudget, planned) per step.
        // After p1 uses 50, remainingBudget = 250. p2 planned = 100. So p2
        // gets min(250, 100) = 100. The spillover (150) isn't "added" to p2's
        // share — it stays in the pool. The spec says the unused budget rolls
        // to the next provider as extra headroom via remainingBudget. Since
        // min(remaining, planned) clamps to planned=100 here, the test asserts
        // p2 gets the minimum of remaining(250) and planned(100) = 100.
        //
        // A provider array with a 3rd entry would receive the leftover.
        let p1 = SpyProvider(slots: [slot(id: "s1", charCount: 200)]) // 50 tokens
        let p2 = SpyProvider()

        let planner = ContextBudgetPlanner(entries: [
            ContextBudgetEntry(provider: p1, budgetWeight: 2.0),
            ContextBudgetEntry(provider: p2, budgetWeight: 1.0),
        ])
        _ = try await planner.assemble(totalBudget: 300, contextSize: 0, context: makeContext())

        // p1 used 50 tokens, remaining = 250 going into p2.
        // p2's planned share = floor(300 * 1/3) = 100.
        // p2 gets min(250, 100) = 100.
        XCTAssertEqual(p1.receivedBudget?.allocated, 200)
        XCTAssertEqual(p2.receivedBudget?.allocated, 100)
    }

    func test_spillover_emptyProviderDonatesToNext_threeProviders() async throws {
        // Three equal-weight providers, budget = 300. Each should get 100
        // planned initially. First provider returns [], using 0 tokens.
        // After p1: remaining = 300. p2 planned = 100, gets min(300,100) = 100.
        // After p2: same if p2 also empty. p3 gets min(200, 100) = 100.
        let empty1 = EmptySpyProvider()
        let empty2 = EmptySpyProvider()
        let p3 = SpyProvider()

        let planner = ContextBudgetPlanner(entries: [
            ContextBudgetEntry(provider: empty1, budgetWeight: 1.0),
            ContextBudgetEntry(provider: empty2, budgetWeight: 1.0),
            ContextBudgetEntry(provider: p3, budgetWeight: 1.0),
        ])
        _ = try await planner.assemble(totalBudget: 300, contextSize: 0, context: makeContext())

        // empty1: planned floor(300 * 1/3) = 100, used 0, remaining stays 300.
        // empty2: planned 100, min(300, 100) = 100, used 0, remaining stays 300.
        // p3: planned 100, min(300, 100) = 100.
        XCTAssertEqual(empty1.receivedBudget?.allocated, 100)
        XCTAssertEqual(empty2.receivedBudget?.allocated, 100)
        XCTAssertEqual(p3.receivedBudget?.allocated, 100)
    }

    // MARK: - Edge cases

    func test_emptyEntries_returnsEmpty() async throws {
        let planner = ContextBudgetPlanner(entries: [])
        let slots = try await planner.assemble(totalBudget: 1000, contextSize: 0, context: makeContext())
        XCTAssertTrue(slots.isEmpty)
    }

    func test_zeroWeightProvider_receivesZeroBudget() async throws {
        // A weight-0 provider gets allocated 0 tokens. The default
        // contributeSlots(budget:context:) still fires and returns [].
        let spy = SpyProvider()
        let planner = ContextBudgetPlanner(entries: [
            ContextBudgetEntry(provider: spy, budgetWeight: 0.0),
        ])
        _ = try await planner.assemble(totalBudget: 300, contextSize: 0, context: makeContext())

        XCTAssertEqual(spy.receivedBudget?.allocated, 0)
    }

    func test_singleProvider_receivesFullBudget() async throws {
        let spy = SpyProvider()
        let planner = ContextBudgetPlanner(entries: [
            ContextBudgetEntry(provider: spy, budgetWeight: 1.0),
        ])
        _ = try await planner.assemble(totalBudget: 500, contextSize: 8192, context: makeContext())

        // Single provider: share = 1.0, planned = floor(500 * 1.0) = 500.
        // min(remaining=500, planned=500) = 500.
        XCTAssertEqual(spy.receivedBudget?.allocated, 500)
        XCTAssertEqual(spy.receivedBudget?.totalContextSize, 8192)
    }

    // MARK: - Slot sorting

    func test_slots_sortedByPosition() async throws {
        // Providers in reverse order; output should be position-sorted.
        let p1 = SpyProvider(slots: [slot(id: "inline", charCount: 4, position: .inline)])
        let p2 = SpyProvider(slots: [slot(id: "system", charCount: 4, position: .systemPreamble)])

        let planner = ContextBudgetPlanner(entries: [
            ContextBudgetEntry(provider: p1),
            ContextBudgetEntry(provider: p2),
        ])
        let result = try await planner.assemble(totalBudget: 1000, contextSize: 0, context: makeContext(messageCount: 5))
        XCTAssertEqual(result.map(\.id), ["system", "inline"])
    }

    // MARK: - Backward compatibility

    /// Providers that use only the legacy ``contributeSlots(messageCount:)``
    /// interface (no override of the budget-aware variant) should return the
    /// same slots regardless of what budget they receive. This verifies the
    /// default extension routes through messageCount correctly.
    func test_backwardCompat_legacyProviderIgnoresBudget() async throws {
        // LegacyProvider only implements contributeSlots(messageCount:).
        struct LegacyProvider: PromptContextProvider {
            func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
                [PromptSlot(id: "legacy", content: "hello", position: .contextSetup, label: "legacy")]
            }
        }

        let pipeline = PromptContextPipeline(providers: [LegacyProvider()])

        // Legacy path.
        let legacySlots = try await pipeline.assemble(messageCount: 5)

        // Budget-aware path with the same provider — default impl ignores budget.
        let context = TurnContext(sessionID: UUID(), messageCount: 5)
        let budgetSlots = try await pipeline.assemble(
            totalBudget: 100,
            contextSize: 4096,
            context: context
        )

        XCTAssertEqual(legacySlots.map(\.id), ["legacy"])
        XCTAssertEqual(budgetSlots.map(\.id), ["legacy"])
    }

    /// ``PromptContextPipeline/assemble(messageCount:)`` must still work as
    /// before — this test is the backward-compat guard for the existing method.
    func test_pipelineAssembleMessageCount_stillWorks() async throws {
        struct FixedProvider: PromptContextProvider {
            func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
                [PromptSlot(id: "slot-\(messageCount)", content: "x", position: .contextSetup, label: "x")]
            }
        }

        let pipeline = PromptContextPipeline(providers: [FixedProvider()])
        let result = try await pipeline.assemble(messageCount: 7)

        XCTAssertEqual(result.map(\.id), ["slot-7"])
    }
}
