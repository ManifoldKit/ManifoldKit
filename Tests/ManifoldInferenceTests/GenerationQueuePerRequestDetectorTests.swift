import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Concurrency regression coverage for #1494: the handoff detector and
/// pre-tool-use hook must be captured **per request** at enqueue time rather
/// than read from shared mutable `GenerationQueue` state at drain time.
///
/// The old shape set `handoffDetector` / `preToolUseHook` on the shared
/// service before each `enqueue`. With concurrent in-flight turns the second
/// turn's set clobbered the first's between enqueue and stream consumption.
/// Capturing the closures on the `QueuedRequest` makes each request's routing
/// independent of any later mutation.
@MainActor
final class GenerationQueuePerRequestDetectorTests: XCTestCase {

    private var provider: FakeGenerationContextProvider!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
    }

    override func tearDown() async throws {
        provider = nil
        try await super.tearDown()
    }

    private func makeQueue() -> GenerationQueue {
        let queue = GenerationQueue()
        provider.bind(to: queue)
        return queue
    }

    private func collectEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func handoffTargets(in events: [GenerationEvent]) -> [UUID] {
        events.compactMap { event -> UUID? in
            if case let .handoffRequested(handoff) = event { return handoff.targetAgentID }
            return nil
        }
    }

    /// Two requests enqueued back-to-back, each carrying its own per-request
    /// handoff detector that maps the identical scripted `transfer` tool call
    /// to a *different* target agent. Each request's stream must surface the
    /// handoff its own detector produced — proving the detector is pinned to
    /// the request, not to shared queue state that the second enqueue would
    /// otherwise clobber.
    func test_perRequestHandoffDetector_eachRequestUsesItsOwnDetector() async throws {
        let targetA = UUID()
        let targetB = UUID()

        // A deliberately "wrong" queue-level detector. If the dispatch loop
        // fell back to shared state instead of the per-request closure, both
        // streams would route here and the per-target assertions would fail.
        let wrongTarget = UUID()
        // The handoff short-circuits each request's dispatch loop after one
        // turn (the runtime re-derives the prompt next turn), so each request
        // consumes exactly one scripted turn. Requests drain FIFO: the first
        // transfer turn belongs to request A, the second to request B.
        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "t-A", toolName: "transfer", arguments: "{}")],
            [ToolCall(id: "t-B", toolName: "transfer", arguments: "{}")],
        ]
        provider.backend.tokensToYieldPerTurn = [[], []]

        let queue = makeQueue()
        queue.handoffDetector = { @Sendable _, call in .handoff(AgentHandoff(targetAgentID: wrongTarget)) }

        let detectorA: @Sendable (UUID?, ToolCall) -> HandoffDetectionResult = { _, _ in
            .handoff(AgentHandoff(targetAgentID: targetA))
        }
        let detectorB: @Sendable (UUID?, ToolCall) -> HandoffDetectionResult = { _, _ in
            .handoff(AgentHandoff(targetAgentID: targetB))
        }

        // Enqueue both before draining either: request B's detector is set on
        // the request that comes after A's enqueue, mirroring the concurrent
        // turn interleave the issue describes.
        let (_, streamA) = try queue.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "go A")],
            config: GenerationQueue.makeEnqueueConfig(
                temperature: 0.7, topP: 0.9, repeatPenalty: 1.1,
                topK: nil, minP: nil, presencePenalty: nil, frequencyPenalty: nil,
                seed: nil, maxOutputTokens: 32, maxThinkingTokens: nil,
                grammar: nil, tools: [], toolChoice: .auto,
                maxToolIterations: 4
            ),
            handoffDetector: detectorA
        )
        let (_, streamB) = try queue.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "go B")],
            config: GenerationQueue.makeEnqueueConfig(
                temperature: 0.7, topP: 0.9, repeatPenalty: 1.1,
                topK: nil, minP: nil, presencePenalty: nil, frequencyPenalty: nil,
                seed: nil, maxOutputTokens: 32, maxThinkingTokens: nil,
                grammar: nil, tools: [], toolChoice: .auto,
                maxToolIterations: 4
            ),
            handoffDetector: detectorB
        )

        let eventsA = try await collectEvents(streamA)
        let eventsB = try await collectEvents(streamB)

        XCTAssertEqual(handoffTargets(in: eventsA), [targetA],
                       "request A's stream must route through detector A's target")
        XCTAssertEqual(handoffTargets(in: eventsB), [targetB],
                       "request B's stream must route through detector B's target")

        // Sabotage check: reverting `runToolDispatchLoop` to read `self.handoffDetector`
        // instead of `request.handoffDetector ?? handoffDetector` routes both
        // streams to `wrongTarget`, failing both assertions above.
    }

    /// A `nil` per-request detector falls back to the queue-level detector so
    /// legacy single-turn callers that still call `setHandoffDetector(_:)`
    /// keep working.
    func test_nilPerRequestDetector_fallsBackToQueueLevel() async throws {
        let fallbackTarget = UUID()
        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "t-1", toolName: "transfer", arguments: "{}")],
        ]
        provider.backend.tokensToYieldPerTurn = [[]]

        let queue = makeQueue()
        queue.handoffDetector = { @Sendable _, _ in .handoff(AgentHandoff(targetAgentID: fallbackTarget)) }

        let (_, stream) = try queue.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "go")],
            config: GenerationQueue.makeEnqueueConfig(
                temperature: 0.7, topP: 0.9, repeatPenalty: 1.1,
                topK: nil, minP: nil, presencePenalty: nil, frequencyPenalty: nil,
                seed: nil, maxOutputTokens: 32, maxThinkingTokens: nil,
                grammar: nil, tools: [], toolChoice: .auto,
                maxToolIterations: 4
            )
            // No per-request detector — must fall back to the queue-level one.
        )

        let events = try await collectEvents(stream)
        XCTAssertEqual(handoffTargets(in: events), [fallbackTarget],
                       "nil per-request detector must fall back to the queue-level detector")
    }
}
