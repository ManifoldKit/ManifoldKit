import XCTest
import ManifoldInference
import ManifoldTestSupport

/// Tests verifying that `MockInferenceBackend.thinkingTokensToYield` emits
/// events in the correct order: `.thinkingToken` × N → `.thinkingComplete` → `.token` × M.
final class MockInferenceBackendThinkingTests: XCTestCase {

    // MARK: - Event ordering

    func test_thinkingTokens_emittedBeforeVisibleTokens() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.thinkingTokensToYield = ["step1 ", "step2"]
        mock.tokensToYield = ["answer"]

        let stream = try mock.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        // Expected: .thinkingToken("step1 "), .thinkingToken("step2"),
        //           .thinkingComplete, .token("answer")
        XCTAssertEqual(events.count, 4,
            "Should emit 2 thinkingToken + 1 thinkingComplete + 1 token = 4 events")

        guard events.count == 4 else { return }

        if case .thinkingToken(let t) = events[0] {
            XCTAssertEqual(t, "step1 ")
        } else {
            XCTFail("events[0] must be .thinkingToken(\"step1 \"), got \(events[0])")
        }

        if case .thinkingToken(let t) = events[1] {
            XCTAssertEqual(t, "step2")
        } else {
            XCTFail("events[1] must be .thinkingToken(\"step2\"), got \(events[1])")
        }

        if case .thinkingComplete = events[2] {
            // expected
        } else {
            XCTFail("events[2] must be .thinkingComplete, got \(events[2])")
        }

        if case .token(let t) = events[3] {
            XCTAssertEqual(t, "answer")
        } else {
            XCTFail("events[3] must be .token(\"answer\"), got \(events[3])")
        }

        // Sabotage check: if the mock emitted .token before .thinkingToken, the
        // index-based assertions at [0] and [3] would both fail.
    }

    // MARK: - No thinkingComplete when thinkingTokens is empty

    func test_emptyThinkingTokens_noThinkingCompleteEmitted() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.thinkingTokensToYield = []
        mock.tokensToYield = ["hello"]

        let stream = try mock.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        let completions = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }
        XCTAssertEqual(completions.count, 0,
            "No .thinkingComplete must be emitted when thinkingTokensToYield is empty")

        // Sabotage check: always emitting .thinkingComplete would yield count=1
        // and break this assertion, exposing spurious finalize calls in the UI.
    }

    // MARK: - thinkingComplete fires exactly once regardless of token count

    func test_thinkingComplete_firesExactlyOnce_forMultipleThinkingTokens() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.thinkingTokensToYield = ["a", "b", "c", "d", "e"]
        mock.tokensToYield = ["result"]

        let stream = try mock.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        let completions = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }
        XCTAssertEqual(completions.count, 1,
            "Exactly one .thinkingComplete must be emitted regardless of how many thinkingTokensToYield there are")

        // Sabotage check: emitting .thinkingComplete once per thinking token would yield 5
        // here and cause spurious UI finalizations.
    }

    // MARK: - Only visible tokens when thinkingTokens is empty

    func test_onlyVisibleTokens_whenNoThinking() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.thinkingTokensToYield = []
        mock.tokensToYield = ["Hello", " world"]

        let stream = try mock.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var allEvents: [GenerationEvent] = []
        for try await event in stream.events {
            allEvents.append(event)
        }

        let thinkingEvents = allEvents.filter {
            if case .thinkingToken = $0 { return true }
            if case .thinkingComplete = $0 { return true }
            return false
        }
        XCTAssertTrue(thinkingEvents.isEmpty,
            "No thinking events must appear when thinkingTokensToYield is empty")

        let tokens = allEvents.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(tokens, ["Hello", " world"])
    }
}
