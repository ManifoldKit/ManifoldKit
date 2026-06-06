import XCTest
@testable import ManifoldModelCatalog

/// Verifies that ``ModelCapabilityProbe`` detects vision/audio capability
/// from the durable JSON keys (`vision_config`, `audio_config`,
/// `max_position_embeddings`) rather than any model-type allowlist.
///
/// Each test writes a minimal `config.json` to a temp directory, probes it,
/// and asserts the returned ``ModelCapabilities``. Fixtures are intentionally
/// minimal — they capture only the keys the probe inspects so a future
/// regression that starts depending on `model_type` (or any other field)
/// fails here.
final class ModelCapabilityProbeTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeFixtureDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCapabilityProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeConfig(_ json: String, to directory: URL, named name: String = "config.json") throws {
        let url = directory.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - LLM (text-only)

    func testProbe_LLM_reportsNoVisionNoAudio() throws {
        let dir = try makeFixtureDirectory()
        // Plain LLM: no vision_config, no audio_config. Includes
        // max_position_embeddings so contextLength surfaces.
        try writeConfig(#"""
        {
            "model_type": "llama",
            "hidden_size": 4096,
            "max_position_embeddings": 8192
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsVision)
        XCTAssertFalse(caps.supportsAudio)
        XCTAssertEqual(caps.contextLength, 8192)
    }

    // MARK: - VLM (vision)

    func testProbe_VLM_reportsVision() throws {
        let dir = try makeFixtureDirectory()
        // VLM: presence of vision_config is the only durable signal we rely on.
        // model_type is intentionally something the probe has never seen so the
        // test fails if a hardcoded allowlist sneaks back in.
        try writeConfig(#"""
        {
            "model_type": "made_up_vlm_2099",
            "max_position_embeddings": 32768,
            "vision_config": {
                "hidden_size": 1152,
                "num_hidden_layers": 27
            }
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsVision)
        XCTAssertFalse(caps.supportsAudio)
        XCTAssertEqual(caps.contextLength, 32768)
    }

    // MARK: - ALM (audio)

    func testProbe_ALM_reportsAudio() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "made_up_alm_2099",
            "max_position_embeddings": 4096,
            "audio_config": {
                "sampling_rate": 16000,
                "num_mel_bins": 80
            }
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsVision)
        XCTAssertTrue(caps.supportsAudio)
        XCTAssertEqual(caps.contextLength, 4096)
    }

    // MARK: - Context length fallback

    func testProbe_fallsBackToNCtxWhenMaxPositionEmbeddingsAbsent() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "gpt2",
            "n_ctx": 1024
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertEqual(caps.contextLength, 1024)
    }

    func testProbe_returnsNilContextWhenNeitherKeyPresent() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "mystery" }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertNil(caps.contextLength)
    }

    // MARK: - preprocessor_config.json optional

    func testProbe_succeedsWhenPreprocessorConfigPresent() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "made_up_vlm",
            "max_position_embeddings": 8192,
            "vision_config": { "hidden_size": 768 }
        }
        """#, to: dir)
        try writeConfig(#"""
        { "image_processor_type": "CLIPImageProcessor", "size": 224 }
        """#, to: dir, named: "preprocessor_config.json")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsVision)
        XCTAssertEqual(caps.contextLength, 8192)
    }

    // MARK: - Null / non-object key handling

    func testProbe_treatsExplicitNullVisionConfigAsAbsent() throws {
        // JSONSerialization turns `"vision_config": null` into NSNull, which is
        // `!= nil` and would falsely flag vision support if the probe just
        // checked key presence. Real VLM configs emit an *object*, never null.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "llama",
            "max_position_embeddings": 8192,
            "vision_config": null,
            "audio_config": null
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsVision)
        XCTAssertFalse(caps.supportsAudio)
        XCTAssertEqual(caps.contextLength, 8192)
    }

    func testProbe_treatsScalarVisionConfigAsAbsent() throws {
        // Defensive: a malformed config.json that puts a scalar where an object
        // is expected should not be treated as multimodal. Better to under-
        // report capability than to mis-route a load through VLMModelFactory.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "llama",
            "vision_config": "broken",
            "audio_config": 42
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsVision)
        XCTAssertFalse(caps.supportsAudio)
    }

    // MARK: - Nested text_config.max_position_embeddings

    func testProbe_readsContextLengthFromNestedTextConfig() throws {
        // PaliGemma-style layout: top-level config has no max_position_embeddings;
        // the language model's context lives inside text_config. Without the
        // fallback, the probe would return nil for these very common VLMs.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "paligemma",
            "vision_config": { "hidden_size": 1152 },
            "text_config": {
                "model_type": "gemma",
                "max_position_embeddings": 8192
            }
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsVision)
        XCTAssertEqual(caps.contextLength, 8192)
    }

    func testProbe_prefersTopLevelContextOverTextConfig() throws {
        // When both are present, top-level wins — consistent with HF's own
        // resolution order and with how mlx-swift-lm reads the config.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "made_up_vlm",
            "max_position_embeddings": 16384,
            "vision_config": { "hidden_size": 1152 },
            "text_config": { "max_position_embeddings": 4096 }
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertEqual(caps.contextLength, 16384)
    }

    // MARK: - Error paths

    func testProbe_throwsWhenConfigMissing() throws {
        let dir = try makeFixtureDirectory()
        XCTAssertThrowsError(try ModelCapabilityProbe.probe(modelDirectory: dir)) { error in
            guard case ModelCapabilityProbeError.configNotFound = error else {
                return XCTFail("expected configNotFound, got \(error)")
            }
        }
    }

    // MARK: - Code generation inference

    func testProbe_codeGeneration_defaultsFalseForPlainLLM() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "llama", "max_position_embeddings": 8192 }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsCodeGeneration)
        XCTAssertFalse(caps.supportsMultilingual)
    }

    func testProbe_codeGeneration_trueWhenReadmeTagsIncludeCode() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "qwen2", "max_position_embeddings": 32768 }
        """#, to: dir)
        // HF coder cards include a `code` (and often `code-generation`) tag.
        try writeConfig(#"""
        ---
        language:
          - en
        tags:
          - code
          - text-generation
        pipeline_tag: text-generation
        ---

        # Qwen2.5-Coder-7B
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsCodeGeneration)
    }

    func testProbe_codeGeneration_trueWhenPipelineTagContainsCode() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "llama", "max_position_embeddings": 8192 }
        """#, to: dir)
        try writeConfig(#"""
        ---
        pipeline_tag: text-to-code
        ---
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsCodeGeneration)
    }

    func testProbe_codeGeneration_trueWhenArchitectureContainsCoder() throws {
        // Fallback path: no README, but `architectures` advertises a coder class.
        // Substring is "coder" specifically to avoid matching "decoder".
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "deepseek",
            "architectures": ["DeepseekCoderForCausalLM"],
            "max_position_embeddings": 16384
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsCodeGeneration)
    }

    func testProbe_codeGeneration_falseForDecoderOnlyArchitecture() throws {
        // Guard: "decoder" in the class name must NOT trip the "coder" needle.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "llama",
            "architectures": ["LlamaDecoderForCausalLM"],
            "max_position_embeddings": 8192
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsCodeGeneration)
    }

    func testProbe_codeGeneration_trueFromConfigTags() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "llama",
            "tags": ["code-generation"],
            "max_position_embeddings": 8192
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsCodeGeneration)
    }

    func testProbe_codeGeneration_falseForEncoderTag() throws {
        // Regression: "encoder" contains "code" as a substring but is NOT a
        // code-generation signal. Whole-token matching must reject it.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "bert", "max_position_embeddings": 512 }
        """#, to: dir)
        try writeConfig(#"""
        ---
        tags:
          - encoder
          - feature-extraction
        pipeline_tag: feature-extraction
        ---
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsCodeGeneration)
    }

    func testProbe_codeGeneration_falseForEncoderDecoderTag() throws {
        // Regression: "encoder-decoder" tokenizes to ["encoder", "decoder"];
        // neither is a code-generation token. Must stay false.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "t5", "max_position_embeddings": 1024 }
        """#, to: dir)
        try writeConfig(#"""
        ---
        tags:
          - encoder-decoder
        ---
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsCodeGeneration)
    }

    func testProbe_codeGeneration_trueForTextToCodePipeline() throws {
        // Confirms whole-token matching still accepts hyphenated code tags.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "llama", "max_position_embeddings": 8192 }
        """#, to: dir)
        try writeConfig(#"""
        ---
        pipeline_tag: text-to-code
        ---
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsCodeGeneration)
    }

    // MARK: - Multilingual inference

    func testProbe_multilingual_trueWhenReadmeListsTwoOrMoreLanguages() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "llama", "max_position_embeddings": 8192 }
        """#, to: dir)
        try writeConfig(#"""
        ---
        language:
          - en
          - fr
          - de
        ---
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsMultilingual)
    }

    func testProbe_multilingual_falseForSingleLanguage() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "llama", "max_position_embeddings": 8192 }
        """#, to: dir)
        try writeConfig(#"""
        ---
        language:
          - en
        ---
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsMultilingual)
    }

    func testProbe_multilingual_trueFromExplicitTag() throws {
        // Some HF cards declare `language: multilingual` plus a `multilingual`
        // tag rather than enumerating every language. Honour the tag.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "xlmr", "max_position_embeddings": 512 }
        """#, to: dir)
        try writeConfig(#"""
        ---
        tags:
          - multilingual
        ---
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsMultilingual)
    }

    func testProbe_multilingual_trueFromInlineFlowList() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "llama", "max_position_embeddings": 8192 }
        """#, to: dir)
        try writeConfig(#"""
        ---
        language: [en, es, pt]
        ---
        """#, to: dir, named: "README.md")

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsMultilingual)
    }

    func testProbe_multilingual_falseWhenReadmeMissing() throws {
        // No README at all and no config-level language array — the probe
        // must report nothing rather than guessing from `model_type`.
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        { "model_type": "qwen2", "max_position_embeddings": 32768 }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertFalse(caps.supportsMultilingual)
    }

    func testProbe_multilingual_trueFromConfigLanguageArray() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"""
        {
            "model_type": "llama",
            "language": ["en", "fr"],
            "max_position_embeddings": 8192
        }
        """#, to: dir)

        let caps = try ModelCapabilityProbe.probe(modelDirectory: dir)

        XCTAssertTrue(caps.supportsMultilingual)
    }

    func testProbe_throwsWhenConfigIsNotAJSONObject() throws {
        let dir = try makeFixtureDirectory()
        try writeConfig(#"["not", "an", "object"]"#, to: dir)
        XCTAssertThrowsError(try ModelCapabilityProbe.probe(modelDirectory: dir)) { error in
            guard case ModelCapabilityProbeError.invalidConfigJSON = error else {
                return XCTFail("expected invalidConfigJSON, got \(error)")
            }
        }
    }
}
