import XCTest
import ManifoldInference
import ManifoldTestSupport

/// Regression tests verifying that backends not configured for thinking do not
/// emit `.thinkingToken` or `.thinkingComplete` events, and that the new
/// `GenerationEvent` cases are handled without crashes across the system.
final class NonThinkingBackendRegressionTests: XCTestCase {

    // MARK: - MockInferenceBackend with no thinking config

    func test_mockBackend_withNoThinkingConfig_emitsNoThinkingEvents() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["hello"]
        // thinkingTokensToYield defaults to [] — mock will emit no thinking events.

        let stream = try mock.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var allEvents: [GenerationEvent] = []
        for try await event in stream.events {
            allEvents.append(event)
        }

        let thinkingEvents = allEvents.filter { event in
            if case .thinkingToken = event { return true }
            if case .thinkingComplete = event { return true }
            return false
        }

        XCTAssertTrue(thinkingEvents.isEmpty,
            "A backend with no thinking config must emit zero .thinkingToken or .thinkingComplete events")

        let visibleTokens = allEvents.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(visibleTokens, ["hello"],
            "MockInferenceBackend with no thinking config must still emit all configured .token events")

        // Sabotage check: if MockInferenceBackend always emitted .thinkingComplete after tokens,
        // thinkingEvents would be non-empty and this assertion would fail.
    }

    // MARK: - MockInferenceBackend switch exhaustiveness

    func test_allGenerationEventCases_handledWithoutCrash() async throws {
        // This test exercises every GenerationEvent case through MockInferenceBackend
        // to confirm the stream continuation doesn't crash on new cases.
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["visible"]
        mock.thinkingTokensToYield = ["thought"]

        // Should not throw.
        let stream = try mock.generate(
            prompt: "test",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        // Drain the stream directly (test is async).
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        // Verify the expected event sequence:
        // .thinkingToken("thought"), .thinkingComplete, .token("visible")
        let thinkingTokens = events.compactMap { e -> String? in
            if case .thinkingToken(let t) = e { return t } else { return nil }
        }
        let completions = events.filter {
            if case .thinkingComplete = $0 { return true } else { return false }
        }
        let tokens = events.compactMap { e -> String? in
            if case .token(let t) = e { return t } else { return nil }
        }
        XCTAssertEqual(thinkingTokens, ["thought"])
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(tokens, ["visible"])

        // Sabotage check: if the mock didn't emit .thinkingComplete after thinking tokens,
        // the completions count would be 0 and this test would fail.
    }
}
