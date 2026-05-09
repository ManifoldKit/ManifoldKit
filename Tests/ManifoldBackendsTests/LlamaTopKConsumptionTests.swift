#if Llama
import XCTest
@testable import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldLlama

/// Regression coverage for the `top_k` consumption fix.
///
/// Before this PR, `LlamaGenerationDriver` hardcoded `llama_sampler_init_top_k(40)`
/// and silently ignored ``GenerationConfig/topK``. The fix makes `topK` actually
/// flow through to the sampler chain. The test exploits the strongest property of
/// `topK = 1`: it forces greedy sampling, which makes generation fully deterministic
/// regardless of `seed` or `temperature`.
///
/// Sabotage check: revert `LlamaGenerationDriver.swift` to `llama_sampler_init_top_k(40)`.
/// With `top_k = 40`, two runs at `temperature = 1.0` with different seeds produce
/// distinct token streams and `test_topK1_isGreedyAcrossSeeds` will fail.
///
/// Requires Apple Silicon and a real GGUF — gated and skipped otherwise.
final class LlamaTopKConsumptionTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
    }

    /// `topK = 1` collapses sampling to greedy — output is identical across seeds.
    func test_topK1_isGreedyAcrossSeeds() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        var configA = GenerationConfig(temperature: 1.0, topK: 1, maxOutputTokens: 24)
        configA.seed = 42
        var configB = configA
        configB.seed = 1337

        let outputA = try await collectTokens(backend: backend, prompt: "Tell me a fact:", config: configA)
        backend.resetConversation()
        let outputB = try await collectTokens(backend: backend, prompt: "Tell me a fact:", config: configB)

        XCTAssertFalse(outputA.isEmpty, "Greedy sampling must still produce tokens")
        XCTAssertEqual(outputA, outputB,
                       "topK=1 forces greedy sampling — different seeds must produce identical streams. "
                     + "Got A=\(outputA.debugDescription) B=\(outputB.debugDescription). "
                     + "If this fails, topK is being ignored and the hardcoded top_k=40 is back.")
    }

    // MARK: - Helpers

    private func collectTokens(
        backend: LlamaBackend,
        prompt: String,
        config: GenerationConfig
    ) async throws -> String {
        let stream = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
        var text = ""
        for try await event in stream.events {
            if case .token(let chunk) = event {
                text += chunk
            }
        }
        return text
    }
}
#endif
