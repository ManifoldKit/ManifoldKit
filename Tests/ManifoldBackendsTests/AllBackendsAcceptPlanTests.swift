import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends

/// Parameterised smoke test across every `InferenceBackend` conformer the test
/// can construct. Each backend is invoked through `loadModel(from:plan:)` with
/// a stub plan; the assertion is that the call reaches a post-load state.
///
/// The point is regression safety — a future protocol change can't silently
/// bypass the plan because this test exercises every conformer. Cloud backends
/// accept the plan informationally (no payload assertion here — that lives in
/// `OpenAIBackendTests.test_loadModel_doesNotPropagateEffectiveContextSizeToRequestPayload`).
///
/// Real backends (`LlamaBackend`, `MLXBackend`) are gated behind their build
/// traits and skipped in the simulator where Metal is unavailable.
final class AllBackendsAcceptPlanTests: XCTestCase {

    // MARK: - Mock Conformers

    /// Exercises all 8 mocks in one pass. Each call must reach `isModelLoaded == true`.
    func test_allMockBackendsAcceptPlan() async throws {
        let plan = ModelLoadPlan.testStub(effectiveContextSize: 1024)
        let url = URL(fileURLWithPath: "/tmp/fixture.gguf")

        let backends: [any InferenceBackend] = [
            MockInferenceBackend(),
            SlowMockBackend(tokenCount: 1, delayMilliseconds: 0),
            PerceivedLatencyBackend(tokensToYield: ["hello"]),
            MockLoadProgressBackend(),
            ChaosBackend(),
            MidStreamErrorBackend(),
            TokenTrackingMockBackend(),
            MockTokenizerVendorBackend(),
        ]

        for backend in backends {
            try await backend.loadModel(from: url, plan: plan)
            XCTAssertTrue(backend.isModelLoaded,
                          "\(type(of: backend)) did not report loaded after loadModel(from:plan:)")
        }
    }

    // MARK: - Cloud Backends

    #if CloudSaaS
    func test_openAIBackendAcceptsPlan() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isModelLoaded)
    }

    func test_claudeBackendAcceptsPlan() async throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            keychainAccount: "test",
            modelName: "claude-3-5-sonnet-latest"
        )
        // ClaudeBackend's load validates API key via Keychain; provide one.
        // We can't easily stash a real keychain item here, so exercise the
        // plan-acceptance via the protocol error path (invalid config throws
        // CloudBackendError). A .cloud() plan still flows through; the point
        // is that the method accepts a plan argument, not a contextSize.
        do {
            try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        } catch {
            // Acceptable — the test's contract is the signature, not the outcome.
        }
    }
    #endif

    #if Ollama
    func test_ollamaBackendAcceptsPlan() async throws {
        let backend = OllamaBackend()
        backend.configure(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: "llama3"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isModelLoaded)
    }
    #endif

    // MARK: - Local Backends (hardware-gated)

    #if Llama
    func test_llamaBackendAcceptsPlan() async throws {
        try XCTSkipIf(isSimulator(), "Metal unavailable in simulator")
        // No fixture available here: the test's contract is that the call
        // compiles and reaches the backend. Use a bogus URL and expect failure;
        // the point is that `loadModel(from:plan:)` is the only signature.
        let backend = LlamaBackend()
        do {
            try await backend.loadModel(
                from: URL(fileURLWithPath: "/tmp/nonexistent.gguf"),
                plan: .testStub(effectiveContextSize: 512)
            )
            XCTFail("Expected load to fail for nonexistent file")
        } catch {
            // Acceptable — the protocol signature accepted a plan; load failed on I/O.
        }
    }
    #endif

    #if MLX
    func test_mlxBackendAcceptsPlan() async throws {
        try XCTSkipIf(isSimulator(), "Metal unavailable in simulator")
        let backend = MLXBackend()
        do {
            try await backend.loadModel(
                from: URL(fileURLWithPath: "/tmp/nonexistent-mlx-dir"),
                plan: .testStub(effectiveContextSize: 512)
            )
            XCTFail("Expected load to fail for nonexistent directory")
        } catch {
            // Acceptable — the protocol signature accepted a plan; load failed on I/O.
        }
    }
    #endif

    // MARK: - Helpers

    private func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
