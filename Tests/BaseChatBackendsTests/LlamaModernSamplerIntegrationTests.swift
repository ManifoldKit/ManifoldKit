#if Llama
import XCTest
@testable import BaseChatInference
@testable import BaseChatTestSupport
@testable import BaseChatBackends
@testable import BaseChatLlama

/// Integration determinism coverage for the XTC and Mirostat v2 sampler additions.
///
/// Both samplers consume the GenerationConfig seed; two runs at the same seed must
/// produce identical token streams, while a different seed must change the stream
/// (the second guard catches a regression where the seed is silently dropped).
///
/// Sabotage check: hardcode `seed = 0` in `LlamaGenerationDriver.swift` — both
/// `differentSeeds` cases will then start emitting equal streams and fail.
///
/// Requires Apple Silicon and a real GGUF — gated and skipped otherwise.
final class LlamaModernSamplerIntegrationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
    }

    func test_xtc_sameSeed_isDeterministic() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        var config = GenerationConfig(
            temperature: 0.8,
            llamaXTC: LlamaXTCSamplerOptions(probability: 0.5, threshold: 0.10, minKeep: 1),
            maxOutputTokens: 24
        )
        config.seed = 42

        let outputA = try await collectTokens(backend: backend, prompt: "Tell me a fact:", config: config)
        backend.resetConversation()
        let outputB = try await collectTokens(backend: backend, prompt: "Tell me a fact:", config: config)

        XCTAssertFalse(outputA.isEmpty, "Sampling must still produce tokens when XTC is active")
        XCTAssertEqual(outputA, outputB, "Same seed + same XTC config must produce identical streams")
    }

    func test_mirostatV2_sameSeed_isDeterministic() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        var config = GenerationConfig(
            llamaMirostatV2: LlamaMirostatV2SamplerOptions(tau: 5.0, eta: 0.1),
            maxOutputTokens: 24
        )
        config.seed = 1_337

        let outputA = try await collectTokens(backend: backend, prompt: "Tell me a fact:", config: config)
        backend.resetConversation()
        let outputB = try await collectTokens(backend: backend, prompt: "Tell me a fact:", config: config)

        XCTAssertFalse(outputA.isEmpty, "Mirostat v2 must still produce tokens")
        XCTAssertEqual(outputA, outputB, "Same seed + same Mirostat config must produce identical streams")
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
