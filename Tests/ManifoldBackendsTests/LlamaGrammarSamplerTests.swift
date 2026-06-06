#if Llama
import XCTest
@testable import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldLlama

/// Tests for GBNF grammar-constrained sampling in LlamaBackend/LlamaGenerationDriver.
///
/// Tests 1–2 require a real GGUF model on disk and Apple Silicon — they are gated with
/// `HardwareRequirements.findGGUFModel()` and `XCTSkipIf`. Test 3 checks the static
/// capability flag and does not require a loaded model or Metal.
///
/// All tests require the `Llama` compilation condition, which is gated by the `#if Llama`
/// wrapper at the file level and enforced by `XCTSkipUnless` in `setUp()`.
final class LlamaGrammarSamplerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
    }

    // MARK: - 1. Grammar constrains output to digit-only strings

    /// Verifies that a GBNF grammar of `root ::= [0-9]+` forces the sampler to emit
    /// only digit characters across every generated token.
    ///
    /// The grammar sampler is inserted into the chain BEFORE the dist sampler in
    /// `LlamaGenerationDriver.run`, so it prunes all non-digit continuations from the
    /// logit distribution before final token selection. Under a correct implementation
    /// every character in the collected output must satisfy `Character.isNumber`.
    ///
    /// Sabotage check: remove the grammar sampler insertion block from
    /// `LlamaGenerationDriver.run`. The model is free to emit non-digit tokens, and
    /// this assertion will fail for most natural-language models.
    func test_grammar_constrainsOutput() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Set LLAMA_TEST_MODEL=<path> or place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        // GBNF grammar that accepts only one or more decimal digits.
        let digitsOnlyGrammar = "root ::= [0-9]+"

        var config = GenerationConfig(temperature: 0.1, maxOutputTokens: 16)
        config.grammar = digitsOnlyGrammar

        let stream = try backend.generate(
            prompt: "Give me a random number.",
            systemPrompt: nil,
            config: config
        )

        var collectedText = ""
        for try await event in stream.events {
            if case .token(let text) = event {
                collectedText += text
            }
        }

        XCTAssertFalse(collectedText.isEmpty,
                       "Grammar-constrained generation must produce at least one token")

        let allDigits = collectedText.allSatisfy { $0.isNumber }
        XCTAssertTrue(allDigits,
                      "Grammar 'root ::= [0-9]+' must constrain output to digits only; "
                    + "got: \(collectedText.debugDescription)")
    }

    // MARK: - 2. Cancel during grammar-constrained generation cleans up properly

    /// Verifies that cancelling mid-stream during grammar-constrained generation does
    /// not corrupt the backend — a subsequent non-grammar generation must succeed.
    ///
    /// The grammar sampler is part of the sampler chain and is freed by the existing
    /// `defer { llama_sampler_free(sampler) }` in `LlamaGenerationDriver.run`. This
    /// test confirms that path is exercised on cancellation without crashing or
    /// leaving the backend in a state that refuses the next generation.
    ///
    /// Sabotage check: change the `defer { llama_sampler_free(sampler) }` in the
    /// driver to a no-op. The grammar sampler is leaked. On Apple platforms this
    /// typically does not crash on first run, so the sabotage is observable by
    /// verifying the second generation still succeeds — the backend's KV clear at
    /// the top of `run()` already resets decode state regardless of the grammar.
    func test_grammar_cancelCleansTeardown() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Set LLAMA_TEST_MODEL=<path> or place a `.gguf` in ~/Documents/Models/ to run this test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        // Start a grammar-constrained generation and cancel it after a few tokens.
        var grammarConfig = GenerationConfig(temperature: 0.1, maxOutputTokens: 64)
        grammarConfig.grammar = "root ::= [0-9]+"

        let stream1 = try backend.generate(
            prompt: "Give me a number.",
            systemPrompt: nil,
            config: grammarConfig
        )

        // Consume a few events then stop — we want to prove cancellation mid-stream.
        var tokenCount = 0
        for try await event in stream1.events {
            if case .token = event { tokenCount += 1 }
            if tokenCount >= 2 { break }
        }

        backend.stopGeneration()

        // Drain so isGenerating flips false.
        for try await _ in stream1.events { }

        let waitDeadline = ContinuousClock.now + .seconds(2)
        while backend.isGenerating && ContinuousClock.now < waitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(backend.isGenerating,
                       "isGenerating must be false after cancel + drain")

        // Follow-up non-grammar generation must succeed without crashing.
        let stream2 = try backend.generate(
            prompt: "Say hello.",
            systemPrompt: nil,
            config: GenerationConfig(temperature: 0.3, maxOutputTokens: 16)
        )

        var secondRunTokenCount = 0
        for try await event in stream2.events {
            if case .token = event { secondRunTokenCount += 1 }
            else if case .thinkingToken = event { secondRunTokenCount += 1 }
        }

        XCTAssertGreaterThan(secondRunTokenCount, 0,
                             "Non-grammar generation after grammar-constrained cancel must succeed — "
                           + "a crash or zero tokens here means the sampler teardown was incomplete")
    }

    // MARK: - 3. Capability flag is true without requiring a loaded model

    /// Verifies that `LlamaBackend().capabilities.supportsGrammarConstrainedSampling`
    /// is `true` even before any model is loaded (no manifest → modelID defaults to
    /// `""`, which does not contain "gemma", so grammar is enabled).
    ///
    /// Callers read this flag before constructing `GenerationConfig.grammar` so they
    /// need a reliable pre-load answer for non-Gemma models.
    ///
    /// Sabotage check: change `supportsGrammar = !modelID.lowercased().contains("gemma")`
    /// to `supportsGrammar = false` in `LlamaBackend.capabilities`. This assertion fails.
    func test_grammar_capabilityFlagIsTrue() {
        let backend = LlamaBackend()
        XCTAssertTrue(backend.capabilities.supportsGrammarConstrainedSampling,
                      "LlamaBackend must report supportsGrammarConstrainedSampling = true when no "
                    + "model is loaded — an unloaded backend has an empty modelID which is not Gemma")
    }

    // MARK: - 4. Grammar capability is disabled for Gemma models

    /// Verifies that `supportsGrammarConstrainedSampling` is `false` when the loaded
    /// manifest's `modelIdentifier` contains "gemma" (case-insensitive).
    ///
    /// Gemma's tokenizer does not produce valid output under GBNF grammar constraints
    /// in llama.cpp — the generation stream is empty, causing the FiresideMemory
    /// extraction pipeline to heuristic-fallback with 0 entities on every turn.
    /// Disabling grammar for Gemma models forces callers to use JSON-mode-only
    /// parsing, which works correctly for them.
    ///
    /// Sabotage check: remove `.lowercased().contains("gemma")` from the detection
    /// logic in `LlamaBackend.capabilities`. A loaded Gemma manifest would incorrectly
    /// advertise grammar support and this assertion would fail.
    func test_grammar_capabilityFlagIsFalse_forGemmaModel() {
        // Simulate a loaded Gemma manifest by directly setting _manifest via the
        // internal test hook. We construct a minimal ModelManifest whose
        // modelIdentifier contains "gemma".
        let backend = LlamaBackend()
        backend.injectManifestForTesting(
            ModelManifest(
                contextWindow: 8192,
                supportsTools: false,
                supportsThinking: false,
                thinkingMarkers: nil,
                supportsSeed: false,
                supportedSamplingParameters: [.temperature, .topP],
                modelIdentifier: "gemma-3-4b-q4_k_m",
                producerKind: .local
            )
        )
        XCTAssertFalse(backend.capabilities.supportsGrammarConstrainedSampling,
                       "LlamaBackend must report supportsGrammarConstrainedSampling = false "
                     + "for Gemma models — their tokenizer is incompatible with GBNF in llama.cpp")
    }
}
#endif
