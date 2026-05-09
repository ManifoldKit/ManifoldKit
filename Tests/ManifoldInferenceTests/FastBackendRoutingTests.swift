import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Coverage for the optional fast-backend routing primitive added on
/// ``InferenceService``. The helper exists so lightweight subtasks
/// (summarisation, session naming) can opt into a small, fast model
/// without touching the user-facing chat dispatch path.
@MainActor
final class FastBackendRoutingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeConfig() -> GenerationConfig {
        GenerationConfig()
    }

    // MARK: - Tests

    func test_runFastOrPrimary_routesToFastBackend_whenSetAndPreferFastTrue() async throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        primary.tokensToYield = ["primary"]

        let fast = MockInferenceBackend()
        fast.isModelLoaded = true
        fast.tokensToYield = ["fast"]

        let service = InferenceService(backend: primary, name: "Primary")
        service.fastBackend = fast

        let stream = try service.runFastOrPrimary(
            prompt: "summarise the conversation",
            systemPrompt: nil,
            config: makeConfig(),
            preferFast: true
        )

        var visible = ""
        for try await event in stream.events {
            if case let .token(t) = event { visible += t }
        }

        XCTAssertEqual(visible, "fast")
        XCTAssertEqual(fast.generateCallCount, 1, "fast backend should have served the call")
        XCTAssertEqual(primary.generateCallCount, 0, "primary must not see the call when fast succeeds")
    }

    func test_runFastOrPrimary_fallsBackToPrimary_whenFastBackendThrows() async throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        primary.tokensToYield = ["primary"]

        let fast = MockInferenceBackend()
        fast.isModelLoaded = true
        // Synchronous throw out of generate(...) — Goose-style fallback applies.
        fast.shouldThrowOnGenerate = InferenceError.inferenceFailure("simulated fast failure")

        let service = InferenceService(backend: primary, name: "Primary")
        service.fastBackend = fast

        let stream = try service.runFastOrPrimary(
            prompt: "summarise",
            systemPrompt: nil,
            config: makeConfig(),
            preferFast: true
        )

        var visible = ""
        for try await event in stream.events {
            if case let .token(t) = event { visible += t }
        }

        XCTAssertEqual(visible, "primary", "fallback should have produced primary's tokens")
        XCTAssertEqual(fast.generateCallCount, 1, "fast backend must be tried first")
        XCTAssertEqual(primary.generateCallCount, 1, "primary backend must run after fast fails")
    }

    func test_runFastOrPrimary_skipsFastBackend_whenPreferFastFalse() async throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        primary.tokensToYield = ["primary"]

        let fast = MockInferenceBackend()
        fast.isModelLoaded = true
        fast.tokensToYield = ["fast"]

        let service = InferenceService(backend: primary, name: "Primary")
        service.fastBackend = fast

        let stream = try service.runFastOrPrimary(
            prompt: "user-priority work",
            systemPrompt: nil,
            config: makeConfig(),
            preferFast: false
        )

        for try await _ in stream.events {}

        XCTAssertEqual(fast.generateCallCount, 0, "preferFast=false must bypass the fast slot")
        XCTAssertEqual(primary.generateCallCount, 1, "primary must serve the call directly")
    }

    func test_runFastOrPrimary_usesPrimary_whenFastBackendNil() async throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        primary.tokensToYield = ["primary"]

        let service = InferenceService(backend: primary, name: "Primary")
        XCTAssertNil(service.fastBackend, "precondition: fastBackend defaults to nil")

        let stream = try service.runFastOrPrimary(
            prompt: "hi",
            systemPrompt: nil,
            config: makeConfig(),
            preferFast: true
        )

        for try await _ in stream.events {}

        XCTAssertEqual(primary.generateCallCount, 1, "primary must serve the call when no fast backend is wired")
    }

    /// Sabotage check on the fallback path: the fallback only runs because the
    /// fast backend's *synchronous* throw is caught. If we accidentally let
    /// the throw escape, the primary never runs and the test catches it.
    /// Asserts fallback executed by checking both backends saw a call.
    func test_runFastOrPrimary_fallback_runsBothBackendsExactlyOnce() async throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        primary.tokensToYield = ["ok"]

        let fast = MockInferenceBackend()
        fast.isModelLoaded = true
        fast.shouldThrowOnGenerate = InferenceError.inferenceFailure("fail")

        let service = InferenceService(backend: primary, name: "Primary")
        service.fastBackend = fast

        let stream = try service.runFastOrPrimary(
            prompt: "x",
            systemPrompt: nil,
            config: makeConfig(),
            preferFast: true
        )
        for try await _ in stream.events {}

        XCTAssertEqual(fast.generateCallCount, 1)
        XCTAssertEqual(primary.generateCallCount, 1)
    }
}
