#if Llama
import XCTest
import ManifoldInference
import ManifoldBackends
@_spi(Testing) import ManifoldLlama
import ManifoldTestSupport

/// Auto-discovery tests for `LlamaBackend`'s thinking-marker plumbing.
///
/// The hardcoded `.qwen3` fallback in `LlamaGenerationDriver` was removed in
/// favour of two cooperating sources of marker data:
///
///   1. `LlamaModelLoader.readChatTemplateMetadata` reads the GGUF's
///      `tokenizer.chat_template` at load time and runs it through
///      `ThinkingMarkers.fromChatTemplate` — the result is cached on the
///      backend as `_autoDetectedThinkingMarkers`.
///   2. `GenerationConfig.thinkingMarkers` always overrides the cached
///      auto-detected value.
///
/// The pure-Swift mapping from chat template to marker preset is exercised by
/// `PromptTemplateDetectorTests`; this file pins the integration on real GGUFs.
final class LlamaThinkingMarkerAutoDiscoveryTests: XCTestCase {

    /// When a real chat GGUF is available on disk, loading it through
    /// `LlamaBackend` exercises `readChatTemplateMetadata` end-to-end. The
    /// outcome depends on the model: a thinking-capable GGUF (DeepSeek-R1,
    /// Qwen3, etc.) leaves `_autoDetectedThinkingMarkers` non-nil; a plain
    /// chat model leaves it nil. Either is a valid pass — what matters is
    /// that the load path runs the metadata-read code without throwing or
    /// crashing on a real `llama_model_meta_val_str` call.
    ///
    /// Sabotage check: changing the metadata key in `readChatTemplateMetadata`
    /// from `"tokenizer.chat_template"` to a typo would produce nil for every
    /// model and silently regress a feature this fixture is meant to guard. A
    /// stronger test would require staging a known reasoning GGUF, which we
    /// can't do in CI; we accept the weaker smoke check here and rely on the
    /// pure-Swift fingerprint tests in `PromptTemplateDetectorTests` for
    /// per-family precision.
    func test_loadModel_runsChatTemplateAutoDiscovery_withoutCrashing() async throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaBackend requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaBackend requires Metal (unavailable in simulator)")
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No chat GGUF available. Set LLAMA_TEST_MODEL=<path> or place a `.gguf` in ~/Documents/Models/ to run this smoke test.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        XCTAssertTrue(backend.isModelLoaded,
                      "Load must succeed for the auto-discovery smoke check to be meaningful")
        // We don't assert a specific marker value: most chat-only GGUFs have no
        // thinking markers and will produce nil. The contract under test is
        // "load doesn't crash on the metadata read"; a crash here would surface
        // as a `try await loadModel` failure or a process-level abort.
    }
}
#endif
