import XCTest
import ManifoldInference
import ManifoldTestSupport

/// Shared conformance tests that verify the `stopGeneration()` contract
/// documented on `InferenceBackend`.
///
/// Any test target can call these helpers with a concrete backend instance
/// to verify it honours the protocol contract. Lives in the test tree (not
/// `ManifoldTestSupport`) so that non-test consumers of `ManifoldTestSupport`
/// — such as the `fuzz-chat` executable — don't have to drag XCTest into
/// their link graph.
public enum StopGenerationContractTests {

    /// Verifies that `isGenerating` is `false` after `stopGeneration()` and
    /// that a subsequent `generate()` call succeeds cleanly.
    ///
    /// The backend must already have a model loaded before calling this.
    public static func verifyStopLeavesBackendReusable(
        _ backend: some InferenceBackend,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let config = GenerationConfig(maxOutputTokens: 64)

        // 1. Start generation and immediately stop.
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: config
        )
        backend.stopGeneration()

        // 2. isGenerating must be false after stop.
        XCTAssertFalse(
            backend.isGenerating,
            "isGenerating must be false after stopGeneration()",
            file: file,
            line: line
        )

        // Drain the stream so the backend's internal task completes.
        for try await _ in stream.events {}

        // 3. A new generate() call must work without errors.
        let secondStream = try backend.generate(
            prompt: "World",
            systemPrompt: nil,
            config: config
        )

        var tokens: [String] = []
        for try await event in secondStream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        XCTAssertFalse(
            tokens.isEmpty,
            "Second generate() after stop must produce tokens",
            file: file,
            line: line
        )

        XCTAssertFalse(
            backend.isGenerating,
            "isGenerating must be false after second stream completes",
            file: file,
            line: line
        )
    }
}

/// Runs the shared `stopGeneration()` contract tests against MockInferenceBackend.
final class StopGenerationContractMockTests: XCTestCase {

    func test_mockBackend_honoursStopGenerationContract() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["one", "two", "three"]

        try await StopGenerationContractTests.verifyStopLeavesBackendReusable(backend)
    }

    func test_stopGeneration_whenIdle_isNoOp() {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true

        // Stopping with no generation in progress must not crash or corrupt state.
        backend.stopGeneration()

        XCTAssertFalse(backend.isGenerating)
        XCTAssertTrue(backend.isModelLoaded)
        XCTAssertEqual(backend.stopCallCount, 1)
    }
}
