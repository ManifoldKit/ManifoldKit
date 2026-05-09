#if Llama
import XCTest
@testable import BaseChatInference
@testable import BaseChatBackends
@testable import BaseChatLlama
@testable import BaseChatTestSupport

/// Preflight-check tests for `LlamaModelLoader` — unsupported GGUF architectures
/// (vision encoders, embedding-only models, speech/diffusion) must throw
/// `InferenceError.unsupportedModelArchitecture` before `generate()` can reach
/// `llama_decode` and crash on a non-LM model. See bundled plan item P2.
final class LlamaArchitecturePreflightTests: XCTestCase {

    // MARK: - Denylist Contents (no hardware required — pure logic)

    /// Vision encoders are the canonical case: a CLIP-L weight dump loaded as a
    /// GGUF has no decode path and will crash inside `llama_decode`.
    ///
    /// Sabotage check: remove `"clip"` from `unsupportedArchitectures` and this
    /// assertion fails — `isUnsupportedArchitecture("clip")` returns false and
    /// the preflight would silently accept a non-LM GGUF.
    func test_denylist_rejectsClipVisionEncoder() {
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("clip"),
                      "CLIP vision encoders must be rejected — they have no causal-LM decode path")
    }

    /// Embedding-only BERT variants expose no generation path.
    func test_denylist_rejectsBertEmbedders() {
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("bert"))
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("nomic-bert"))
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("jina-bert-v2"))
    }

    /// Multimodal LLaVA / mllama checkpoints require a projector + mm path that
    /// llama.cpp's standard decode loop doesn't provide.
    func test_denylist_rejectsMultimodalWrappers() {
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("llava"))
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("mllama"))
    }

    /// Speech and diffusion weight dumps leak into user Models/ folders as .gguf
    /// files often enough to warrant an explicit deny.
    func test_denylist_rejectsSpeechAndDiffusion() {
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("whisper"))
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("stablediffusion"))
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("sd3"))
    }

    /// Case-insensitivity: GGUF authors are inconsistent about casing; `CLIP`
    /// and `clip` must both match.
    func test_denylist_isCaseInsensitive() {
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("CLIP"))
        XCTAssertTrue(LlamaModelLoader.isUnsupportedArchitecture("Bert"))
    }

    // MARK: - Allowlist (things the denylist must NOT reject)

    /// The denylist must not reject legitimate causal-LM architectures — a false
    /// positive here breaks every current and future chat model loaded through
    /// `LlamaBackend`.
    ///
    /// Sabotage check: add `"llama"` to `unsupportedArchitectures` and this
    /// assertion fails — the preflight would refuse to load every Llama family
    /// model.
    func test_denylist_acceptsCausalLMArchitectures() {
        let legitimate = [
            "llama", "llama2", "llama3",
            "qwen", "qwen2", "qwen3",
            "mistral", "mixtral",
            "gemma", "gemma2", "gemma3",
            "phi", "phi3",
            "falcon", "mamba", "gptneox", "gpt2",
            // Even architectures we haven't explicitly tested must default to allow —
            // the denylist-not-allowlist decision hinges on this behaviour.
            "brand-new-arch-that-doesnt-exist-yet",
        ]
        for arch in legitimate {
            XCTAssertFalse(
                LlamaModelLoader.isUnsupportedArchitecture(arch),
                "Legitimate LM architecture '\(arch)' must NOT be on the denylist"
            )
        }
    }

    // MARK: - Real GGUF Load (hardware-gated)

    /// When a real chat GGUF is available on disk, loading it through
    /// `LlamaBackend.loadModel` must succeed — proving the preflight doesn't
    /// reject legitimate chat models.
    ///
    /// This is the positive half of the preflight contract. The negative half
    /// (non-LM GGUF throws `unsupportedModelArchitecture`) cannot be exercised
    /// in CI without bundling a ~50 MB vision-encoder fixture; we rely on the
    /// pure-logic denylist tests above for that coverage.
    ///
    /// Sabotage check: change `isUnsupportedArchitecture` to return `true`
    /// unconditionally. This test then throws `.unsupportedModelArchitecture`
    /// and fails.
    func test_preflight_acceptsRealChatGGUF() async throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaBackend requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaBackend requires Metal (unavailable in simulator)")
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No chat GGUF available in ~/Documents/Models/ — skipping preflight happy-path test")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }

        do {
            try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        } catch InferenceError.unsupportedModelArchitecture(let arch) {
            XCTFail("Real chat GGUF was rejected by the preflight as architecture '\(arch)' — the denylist is too aggressive")
            return
        }

        XCTAssertTrue(backend.isModelLoaded,
                      "A chat GGUF must pass the preflight and load successfully")
    }

    // MARK: - Error Description

    /// The error's `errorDescription` must name the architecture so users can
    /// diagnose which file they need to replace.
    func test_unsupportedArchitectureError_descriptionNamesTheArchitecture() {
        let error = InferenceError.unsupportedModelArchitecture("clip")
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("clip"),
                      "errorDescription must include the architecture string; got: \(message)")
        XCTAssertFalse(error.isRetryable,
                       "Architecture mismatch is permanent — retry can never help")
    }
}
#endif
