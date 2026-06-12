#if Llama
import XCTest
import ManifoldInference
import ManifoldTestSupport
import ManifoldBackends
@_spi(Testing) import ManifoldLlama

/// Verifies that ``GenerationConfig/seed`` makes ``LlamaBackend`` token streams
/// reproducible across runs. The driver feeds the seed into
/// `llama_sampler_init_dist`, so two `generate()` calls with identical prompt /
/// config / model state must produce the same token sequence.
///
/// Requires Apple Silicon and a real GGUF on disk — gated by
/// ``HardwareRequirements`` and skipped otherwise.
final class LlamaSeedDeterminismTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
    }

    /// Two generations with the same `seed` produce identical token streams.
    ///
    /// We collect the full visible token sequence for two consecutive runs against
    /// the same loaded model. Under a correct seed implementation, `outputA == outputB`.
    ///
    /// Sabotage check: replace the seed plumbing in `LlamaGenerationDriver.run` with
    /// `UInt32.random(in: 0...UInt32.max)` (the prior behaviour). The two runs will
    /// diverge after the first sampled token and this assertion will fail.
    func test_sameSeed_producesIdenticalOutput() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Set LLAMA_TEST_MODEL=<path> or place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        var config = GenerationConfig(temperature: 0.8, maxOutputTokens: 16)
        config.seed = 42

        let outputA = try await collectTokens(backend: backend, prompt: "List three colours:", config: config)
        backend.resetConversation()
        let outputB = try await collectTokens(backend: backend, prompt: "List three colours:", config: config)

        XCTAssertFalse(outputA.isEmpty, "Seeded generation must produce at least one token")
        XCTAssertEqual(outputA, outputB,
                       "Identical seeds must produce identical token streams; "
                     + "got A=\(outputA.debugDescription) B=\(outputB.debugDescription)")
    }

    /// Different seeds with non-zero temperature produce distinct outputs.
    ///
    /// This guards against the trivial implementation that ignores the seed and
    /// always uses the same internal state — it would silently make the previous
    /// test pass by emitting identical streams regardless of the seed value.
    ///
    /// Sabotage check: hardcode the seed in `LlamaGenerationDriver.run` to a constant
    /// (e.g. `42`) instead of reading from `config.seed`. Both runs use the same
    /// internal seed and this assertion will fail.
    func test_differentSeeds_produceDifferentOutput() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Set LLAMA_TEST_MODEL=<path> or place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        var configA = GenerationConfig(temperature: 1.0, maxOutputTokens: 24)
        configA.seed = 42
        var configB = configA
        configB.seed = 1337

        let outputA = try await collectTokens(backend: backend, prompt: "Tell me a fact:", config: configA)
        backend.resetConversation()
        let outputB = try await collectTokens(backend: backend, prompt: "Tell me a fact:", config: configB)

        XCTAssertFalse(outputA.isEmpty)
        XCTAssertFalse(outputB.isEmpty)
        XCTAssertNotEqual(outputA, outputB,
                          "Different seeds at temperature=1.0 should diverge; "
                        + "got matching streams: \(outputA.debugDescription)")
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
        // The stream's last element fires from `continuation.finish()`, but
        // `LlamaBackend` clears `isGenerating` in the generation task's `defer`,
        // which has no happens-before relationship with the consumer loop exiting
        // above. Without awaiting the task to settle, the *next* generate() can
        // race the defer and throw `.alreadyGenerating` (observed under
        // full-suite load). Awaiting the in-flight task guarantees the defer has
        // run and `isGenerating == false` before the caller starts gen #2.
        await backend.awaitGenerationSettled()
        return text
    }
}
#endif
