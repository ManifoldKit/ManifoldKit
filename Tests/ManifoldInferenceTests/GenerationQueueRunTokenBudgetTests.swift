import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Unit tests for the run-level token ceiling (`GenerationConfig.maxRunTokens`)
/// enforced at the tool-iteration boundary inside the dispatch loop (#1939
/// item 3).
///
/// The ceiling is the token-spend sibling of `maxToolIterations`: where that
/// bounds the *count* of tool round-trips, this bounds the cumulative
/// prompt + completion tokens reported across them. Enforcement is at the
/// iteration boundary (after a generation's terminal `.usage` lands, before
/// the next generation dispatches) — never mid-stream, since cloud backends
/// only report usage at end-of-generation.
@MainActor
final class GenerationQueueRunTokenBudgetTests: XCTestCase {

    @MainActor
    private final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        private(set) var callCount = 0
        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "test", parameters: .object([:]))
        }
        nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            await MainActor.run { self.callCount += 1 }
            return ToolResult(callId: "", content: "ok", errorKind: nil)
        }
    }

    private var provider: FakeGenerationContextProvider!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
    }

    override func tearDown() async throws {
        provider = nil
        try await super.tearDown()
    }

    private func collectEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }
        return events
    }

    private func makeCall(id: String, name: String, arguments: String) -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: arguments)
    }

    /// The model emits a fresh tool call every turn (so the iteration count
    /// alone would not stop it inside the budget window), and each generation
    /// reports 100 tokens of usage. With a 250-token ceiling the loop must
    /// abort at the boundary once the cumulative total (300 after three turns)
    /// crosses 250 — emitting `.runTokenBudgetExceeded` and a terminal
    /// completion with `.runTokenBudget`.
    func test_runTokenBudget_aborts_atIterationBoundary_whenCumulativeUsageExceedsCeiling() async throws {
        let executor = RecordingExecutor(name: "spam")
        let registry = ToolRegistry()
        registry.register(executor)

        // Distinct args per turn so the repeat-call short-circuit never fires.
        provider.backend.scriptedToolCallsPerTurn = (0..<20).map { idx in
            [makeCall(id: "s-\(idx)", name: "spam", arguments: #"{"i":\#(idx)}"#)]
        }
        // 100 tokens reported per turn (60 prompt + 40 completion).
        provider.backend.usageToYieldPerTurn = Array(repeating: (prompt: 60, completion: 40), count: 20)

        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)

        // High iteration cap so the iteration limit does not pre-empt the token
        // ceiling; 250-token budget crosses after the third turn (cumulative
        // 300 >= 250 checked at the start of the fourth iteration).
        var config = GenerationConfig(maxOutputTokens: 8, maxToolIterations: 50)
        config.maxRunTokens = 250

        let (_, stream) = try coordinator.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "go")],
            config: config
        )
        let events = try await collectEvents(stream)

        let budgetEvents = events.compactMap { event -> (Int, Int)? in
            if case .runTokenBudgetExceeded(let used, let limit) = event { return (used, limit) }
            return nil
        }
        // Sabotage check: raising maxRunTokens above the scripted sum (e.g.
        // 10_000) drops this to zero — the loop runs to the iteration cap or
        // organic stop instead.
        XCTAssertEqual(budgetEvents.count, 1, "exactly one run-token-budget diagnostic")
        XCTAssertEqual(budgetEvents.first?.1, 250, "diagnostic carries the configured limit")
        XCTAssertGreaterThanOrEqual(budgetEvents.first?.0 ?? 0, 250, "abort total met or exceeded the ceiling")

        // Executor ran exactly three times: usage crosses 250 after turn 3, so
        // the boundary check at the top of iteration 4 aborts before dispatch.
        XCTAssertEqual(executor.callCount, 3, "loop aborts at the boundary after the budget is crossed")

        let completions = events.compactMap { event -> GenerationCompletion? in
            if case .generationCompleted(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.reason, .runTokenBudget)

        // The completion is terminal and follows the diagnostic.
        if case .generationCompleted = events.last {} else {
            XCTFail("`.generationCompleted` must be the last event; got \(String(describing: events.last))")
        }
        let budgetIdx = events.firstIndex { if case .runTokenBudgetExceeded = $0 { return true } else { return false } }
        let completedIdx = events.firstIndex { if case .generationCompleted = $0 { return true } else { return false } }
        XCTAssertNotNil(budgetIdx)
        if let budgetIdx, let completedIdx {
            XCTAssertLessThan(budgetIdx, completedIdx, "completion follows the budget diagnostic")
        }
    }

    /// When usage stays under the ceiling the loop terminates organically and
    /// never emits the budget diagnostic.
    func test_runTokenBudget_doesNotFire_whenCumulativeUsageStaysUnderCeiling() async throws {
        let executor = RecordingExecutor(name: "spam")
        let registry = ToolRegistry()
        registry.register(executor)

        // One tool turn, then a quiet final turn (no tool call) → organic stop.
        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "s-0", name: "spam", arguments: #"{"i":0}"#)],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["done"]]
        provider.backend.usageToYieldPerTurn = [(prompt: 60, completion: 40), (prompt: 10, completion: 5)]

        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)

        var config = GenerationConfig(maxOutputTokens: 8, maxToolIterations: 50)
        config.maxRunTokens = 10_000 // generous — never reached (cumulative 115)

        let (_, stream) = try coordinator.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "go")],
            config: config
        )
        let events = try await collectEvents(stream)

        let budgetEvents = events.filter { if case .runTokenBudgetExceeded = $0 { return true } else { return false } }
        XCTAssertTrue(budgetEvents.isEmpty, "budget diagnostic must not fire under the ceiling")

        let completions = events.compactMap { event -> GenerationCompletion? in
            if case .generationCompleted(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(completions.first?.reason, .stop, "organic stop, not a budget abort")
    }

    /// A `nil` (default) ceiling never aborts, even when usage is large —
    /// preserving the existing zero-config behaviour.
    func test_runTokenBudget_nilCeiling_neverAborts() async throws {
        let executor = RecordingExecutor(name: "spam")
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "s-0", name: "spam", arguments: #"{"i":0}"#)],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["done"]]
        provider.backend.usageToYieldPerTurn = [(prompt: 9_999, completion: 9_999), (prompt: 1, completion: 1)]

        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)

        // maxRunTokens defaults to nil.
        let config = GenerationConfig(maxOutputTokens: 8, maxToolIterations: 50)
        XCTAssertNil(config.maxRunTokens)

        let (_, stream) = try coordinator.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "go")],
            config: config
        )
        let events = try await collectEvents(stream)

        let budgetEvents = events.filter { if case .runTokenBudgetExceeded = $0 { return true } else { return false } }
        XCTAssertTrue(budgetEvents.isEmpty, "nil ceiling disables the run-token guard entirely")
    }
}
