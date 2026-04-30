import XCTest
import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatTestSupport

/// Real-clock tests for `PerceivedLatencyBackend`.
///
/// Delays are kept small (≤ 100 ms) so these tests stay CI-friendly while
/// still exercising the timing paths. Tolerances bias towards the lower bound
/// to catch regressions that would accidentally deliver tokens too fast;
/// upper bounds are generous to survive scheduler jitter on busy CI runners.
final class PerceivedLatencyBackendTests: XCTestCase {

    private let modelURL = URL(fileURLWithPath: "/tmp/fake-model")

    func test_timeToFirstToken_respectsConfiguredDelay() async throws {
        let ttft: Duration = .milliseconds(50)
        let backend = PerceivedLatencyBackend(
            coldStartDelay: .milliseconds(0),
            timeToFirstToken: ttft,
            interTokenJitter: .milliseconds(1)...(.milliseconds(1)),
            tokensToYield: ["a", "b", "c"]
        )
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let clock = ContinuousClock()
        let start = clock.now
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        var firstTokenAt: ContinuousClock.Instant?
        for try await event in stream.events {
            if case .token = event {
                firstTokenAt = clock.now
                break
            }
        }
        let elapsed = start.duration(to: try XCTUnwrap(firstTokenAt))
        XCTAssertGreaterThanOrEqual(
            elapsed, ttft,
            "First token arrived before configured TTFT (\(elapsed) < \(ttft))"
        )
        // Upper bound: generous but still a regression if we blow past it.
        XCTAssertLessThan(elapsed, ttft + .milliseconds(500))
    }

    func test_coldStartDelay_paidOnFirstLoadOnly() async throws {
        let coldStart: Duration = .milliseconds(50)
        let backend = PerceivedLatencyBackend(
            coldStartDelay: coldStart,
            timeToFirstToken: .milliseconds(0),
            interTokenJitter: .milliseconds(0)...(.milliseconds(0)),
            tokensToYield: ["hi"]
        )

        let clock = ContinuousClock()
        let firstLoadStart = clock.now
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        let firstLoadElapsed = firstLoadStart.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(firstLoadElapsed, coldStart)

        // Second load should be fast — cold start already paid.
        let secondLoadStart = clock.now
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        let secondLoadElapsed = secondLoadStart.duration(to: clock.now)
        XCTAssertLessThan(
            secondLoadElapsed, coldStart,
            "Cold start should only be paid on the first loadModel call"
        )
    }

    func test_yieldsAllTokens_inOrder() async throws {
        let backend = PerceivedLatencyBackend(
            coldStartDelay: .milliseconds(0),
            timeToFirstToken: .milliseconds(5),
            interTokenJitter: .milliseconds(1)...(.milliseconds(3)),
            tokensToYield: ["Hello", ", ", "world", "!"]
        )
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        let stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())

        var collected: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { collected.append(t) }
        }
        XCTAssertEqual(collected, ["Hello", ", ", "world", "!"])
    }

    /// Back-to-back `generate()` calls must each produce a fresh stream and
    /// leave `isGenerating == false` between runs. Catches regressions in
    /// the lifecycle helper's task-slot clearing.
    func test_backToBackGenerate_eachCallProducesFreshStream() async throws {
        let backend = PerceivedLatencyBackend(
            coldStartDelay: .milliseconds(0),
            timeToFirstToken: .milliseconds(1),
            interTokenJitter: .milliseconds(0)...(.milliseconds(0)),
            tokensToYield: ["a", "b"]
        )
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        var first: [String] = []
        let stream1 = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        for try await event in stream1.events {
            if case .token(let t) = event { first.append(t) }
        }
        XCTAssertEqual(first, ["a", "b"])
        XCTAssertFalse(backend.isGenerating)

        var second: [String] = []
        let stream2 = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        for try await event in stream2.events {
            if case .token(let t) = event { second.append(t) }
        }
        XCTAssertEqual(second, ["a", "b"], "Second run must yield identical tokens")
        XCTAssertFalse(backend.isGenerating)
    }

    func test_cancellationStops_generation() async throws {
        let backend = PerceivedLatencyBackend(
            coldStartDelay: .milliseconds(0),
            timeToFirstToken: .milliseconds(5),
            interTokenJitter: .milliseconds(50)...(.milliseconds(50)),
            tokensToYield: Array(repeating: "x", count: 50)
        )
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())
        var count = 0
        for try await event in stream.events {
            if case .token = event {
                count += 1
                if count == 2 {
                    backend.stopGeneration()
                }
            }
        }
        XCTAssertLessThan(count, 50, "stopGeneration() should truncate the stream")
        XCTAssertFalse(backend.isGenerating)
    }
}
