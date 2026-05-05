#if MLX
import XCTest
import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for MLXBackend state, capabilities, and lifecycle.
///
/// Hardware-gated tests (those that require a real model load) are skipped in CI.
/// Full load→unload cycles are covered by `BaseChatE2ETests` on Apple Silicon.
final class MLXBackendTests: XCTestCase {

    // MARK: - State on Init (no hardware gate)

    func test_init_isNotLoaded() {
        let b = MLXBackend()
        XCTAssertFalse(b.isModelLoaded)
    }

    func test_init_isNotGenerating() {
        let b = MLXBackend()
        XCTAssertFalse(b.isGenerating)
    }

    // MARK: - Capabilities (no hardware gate)

    func test_capabilities_doesNotRequirePromptTemplate() {
        XCTAssertFalse(MLXBackend().capabilities.requiresPromptTemplate)
    }

    func test_capabilities_supportsSystemPrompt() {
        XCTAssertTrue(MLXBackend().capabilities.supportsSystemPrompt)
    }

    func test_capabilities_supportsTemperature() {
        XCTAssertTrue(MLXBackend().capabilities.supportedParameters.contains(.temperature))
    }

    func test_capabilities_supportsAdditivePenaltyKnobs() {
        let caps = MLXBackend().capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.topK))
        XCTAssertTrue(caps.supportedParameters.contains(.minP))
        XCTAssertTrue(caps.supportedParameters.contains(.repetitionPenalty))
        XCTAssertTrue(caps.supportedParameters.contains(.presencePenalty))
        XCTAssertTrue(caps.supportedParameters.contains(.frequencyPenalty))
    }

    // MARK: - Load Options Plumbing (no hardware gate)

    func test_loadOptions_defaultUsesBackendTunedDefaults() {
        let opts = MLXBackend().loadOptionsForTesting
        XCTAssertEqual(opts.kvCacheQuantization, .q8)
        XCTAssertEqual(opts.flashAttention, BackendLoadOptions.platformDefaultFlashAttention)
        XCTAssertNil(opts.prefillBatchSize)
    }

    func test_setLoadOptions_persistsForNextLoad() {
        let backend = MLXBackend()
        backend.setLoadOptions(BackendLoadOptions(
            kvCacheQuantization: .q4,
            flashAttention: true,
            prefillBatchSize: 2048
        ))
        let opts = backend.loadOptionsForTesting
        XCTAssertEqual(opts.kvCacheQuantization, .q4)
        XCTAssertTrue(opts.flashAttention,
                      "flashAttention must round-trip through state even though MLX silently ignores it on the generate path")
        XCTAssertEqual(opts.prefillBatchSize, 2048)
    }

    func test_capabilities_contextSize() {
        XCTAssertEqual(MLXBackend().capabilities.maxContextTokens, 8192)
    }

    func test_capabilities_supportsKVCachePersistence_onlyWhenEnabled() {
        XCTAssertFalse(MLXBackend().capabilities.supportsKVCachePersistence)
        XCTAssertTrue(MLXBackend(enableKVCacheReuse: true).capabilities.supportsKVCachePersistence)
    }

    func test_capabilities_supportsVision_falseBeforeLoad() {
        XCTAssertFalse(MLXBackend().capabilities.supportsVision)
    }

    // MARK: - Lifecycle (no hardware gate)

    func test_generate_beforeLoad_throws() {
        XCTAssertThrowsError(
            try MLXBackend().generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        )
    }

    func test_unloadModel_beforeLoad_doesNotCrash() {
        MLXBackend().unloadModel()
    }

    func test_stopGeneration_beforeLoad_doesNotCrash() {
        MLXBackend().stopGeneration()
    }

    func test_unloadModel_afterMockInjection_doesNotCrash() {
        let backend = MLXBackend(enableKVCacheReuse: true)
        backend._inject(MockMLXModelContainer())
        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
    }

    // MARK: - Hardware-gated

    func test_loadModel_invalidDirectory_throws() async throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "MLX requires Apple Silicon")
        let b = MLXBackend()
        let badURL = URL(fileURLWithPath: "/nonexistent-mlx-model-\(UUID().uuidString)")
        do {
            try await b.loadModel(from: badURL, plan: .testStub(effectiveContextSize: 512))
            XCTFail("Should throw for invalid model directory")
        } catch {
            XCTAssertFalse(b.isModelLoaded)
        }
    }

    func test_unloadModel_afterLoad_clearsState() async throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "MLX requires Apple Silicon")
        // Full load→unload→verify is covered in BaseChatE2ETests on Apple Silicon.
        throw XCTSkip("Full load→unload cycle covered in BaseChatE2ETests on Apple Silicon")
    }

    // MARK: - Architecture preflight (no hardware gate)

    /// Writes a throwaway `config.json` into a temp directory so we can exercise
    /// `MLXBackend.validateArchitecture` without invoking the real MLX load path
    /// (which would trip the metallib guard in `swift test`).
    private func writeTempConfig(_ json: [String: Any]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-arch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: dir.appendingPathComponent("config.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func test_validateArchitecture_acceptsQwen3() throws {
        let url = try writeTempConfig(["model_type": "qwen3"])
        XCTAssertNoThrow(try MLXBackend.validateArchitecture(at: url))
    }

    func test_validateArchitecture_acceptsGemma4() throws {
        // mlx-community/gemma-4-* ships `model_type: "gemma4"` (added to
        // mlx-swift-lm's LLMTypeRegistry in 3.31.3). Sabotage check: removing
        // "gemma4" from `supportedLMArchitectures` makes this throw.
        let url = try writeTempConfig(["model_type": "gemma4"])
        XCTAssertNoThrow(try MLXBackend.validateArchitecture(at: url))
    }

    func test_validateArchitecture_acceptsQwen25VL() throws {
        let url = try writeTempConfig([
            "model_type": "qwen2_5_vl",
            "vision_config": ["hidden_size": 1]
        ])
        XCTAssertNoThrow(try MLXBackend.validateArchitecture(at: url))
    }

    func test_validateArchitecture_acceptsLlamaViaArchitectures() throws {
        // HF repos that omit `model_type` but ship `architectures: ["LlamaForCausalLM"]`
        // must still pass — snake_case prefix match keeps older snapshots working.
        let url = try writeTempConfig(["architectures": ["LlamaForCausalLM"]])
        XCTAssertNoThrow(try MLXBackend.validateArchitecture(at: url))
    }

    func test_validateArchitecture_rejectsVisionEncoder() throws {
        let url = try writeTempConfig(["model_type": "clip"])
        XCTAssertThrowsError(try MLXBackend.validateArchitecture(at: url)) { error in
            guard case InferenceError.unsupportedModelArchitecture(let arch) = error else {
                return XCTFail("Expected .unsupportedModelArchitecture, got \(error)")
            }
            XCTAssertEqual(arch, "clip")
        }
        // Sabotage confirmation: adding "clip" to `supportedLMArchitectures`
        // makes this assertion fail (no throw) — verified locally before commit.
    }

    func test_validateArchitecture_rejectsEmbeddings() throws {
        let url = try writeTempConfig(["model_type": "bert"])
        XCTAssertThrowsError(try MLXBackend.validateArchitecture(at: url)) { error in
            guard case InferenceError.unsupportedModelArchitecture = error else {
                return XCTFail("Expected .unsupportedModelArchitecture, got \(error)")
            }
        }
    }

    func test_validateArchitecture_rejectsVisionViaArchitectures() throws {
        // `model_type` missing, `architectures` says CLIPModel — must still be refused.
        let url = try writeTempConfig(["architectures": ["CLIPModel"]])
        XCTAssertThrowsError(try MLXBackend.validateArchitecture(at: url)) { error in
            guard case InferenceError.unsupportedModelArchitecture = error else {
                return XCTFail("Expected .unsupportedModelArchitecture, got \(error)")
            }
        }
    }

    func test_validateArchitecture_missingConfigIsNoOp() throws {
        // A directory with no config.json must not throw — the subsequent MLX load
        // path will surface the real "missing config" diagnostic instead.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-arch-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try MLXBackend.validateArchitecture(at: dir))
    }

    // MARK: - VLM Factory Routing (issue #752, no hardware gate)

    func test_requiresVLMFactory_whenTextConfigEnablesMoE_returnsTrue() throws {
        // mlx-community/gemma-4-26b-a4b-it-4bit ships
        //   { "text_config": { "enable_moe_block": true, … } }
        // and only loads correctly via VLMModelFactory in mlx-swift-lm 3.31.3.
        // Sabotage check: flipping `requiresVLMFactory` to always return false
        // makes this assertion fail (verified locally before commit).
        let url = try writeTempConfig([
            "text_config": ["enable_moe_block": true]
        ])
        XCTAssertTrue(MLXBackend.requiresVLMFactory(at: url))
    }

    func test_requiresVLMFactory_whenVisionConfigPresent_returnsTrue() throws {
        let url = try writeTempConfig([
            "model_type": "qwen2_5_vl",
            "vision_config": ["hidden_size": 1]
        ])
        XCTAssertTrue(MLXBackend.requiresVLMFactory(at: url))
    }

    func test_requiresVLMFactory_whenTextConfigOmitsMoE_returnsFalse() throws {
        // Dense Gemma 4 variants (e.g. gemma-4-e4b-it-4bit) ship
        //   { "text_config": { "enable_moe_block": false, … } }
        // and must stay on LLMModelFactory to avoid loading vision-tower
        // weights into resident memory.
        let url = try writeTempConfig([
            "text_config": ["enable_moe_block": false]
        ])
        XCTAssertFalse(MLXBackend.requiresVLMFactory(at: url))
    }

    func test_requiresVLMFactory_whenConfigHasNoTextConfig_returnsFalse() throws {
        // Regular LLMs (qwen3, llama, mistral, …) have a flat config.json with
        // no `text_config` block. They route through LLMModelFactory.
        let url = try writeTempConfig(["model_type": "qwen3"])
        XCTAssertFalse(MLXBackend.requiresVLMFactory(at: url))
    }

    func test_requiresVLMFactory_whenConfigMissing_returnsFalse() throws {
        // Conservative fallback matches `validateArchitecture` — let the MLX
        // load path produce the real diagnostic for missing config.json.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-vlm-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(MLXBackend.requiresVLMFactory(at: dir))
    }
}

// MARK: - Backend Contract

extension MLXBackendTests {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { MLXBackend() }
    }
}
#endif
