import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

final class GenerationConfigTests: XCTestCase {

    // MARK: - Default Values

    func test_defaultInit_temperature() {
        let config = GenerationConfig()
        XCTAssertEqual(config.temperature, 0.7, accuracy: 0.001)
    }

    func test_defaultInit_topP() {
        let config = GenerationConfig()
        XCTAssertEqual(config.topP, 0.9, accuracy: 0.001)
    }

    func test_defaultInit_repeatPenalty() {
        let config = GenerationConfig()
        XCTAssertEqual(config.repeatPenalty, 1.1, accuracy: 0.001)
    }

    func test_defaultInit_maxOutputTokens() {
        let config = GenerationConfig()
        XCTAssertEqual(config.maxOutputTokens, 2048)
    }

    func test_defaultInit_hints_jsonMode_isFalse() {
        // jsonMode moved off GenerationConfig into GenerationRuntimeHints (#2152).
        XCTAssertFalse(GenerationRuntimeHints().jsonMode)
    }

    func test_defaultInit_streamPrefillProgress_isFalse() {
        let config = GenerationConfig()
        XCTAssertFalse(config.streamPrefillProgress)
    }

    // MARK: - Custom Init

    func test_customInit_propagatesAllValues() {
        let config = GenerationConfig(
            temperature: 1.2,
            topP: 0.95,
            repeatPenalty: 1.5,
            maxOutputTokens: 2048
        )

        XCTAssertEqual(config.temperature, 1.2, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(config.repeatPenalty, 1.5, accuracy: 0.001)
        XCTAssertEqual(config.maxOutputTokens, 2048)
    }

    func test_customInit_partialOverride() {
        let config = GenerationConfig(temperature: 0.0, maxOutputTokens: 1024)

        XCTAssertEqual(config.temperature, 0.0, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.9, accuracy: 0.001, "Non-overridden topP should use default")
        XCTAssertEqual(config.repeatPenalty, 1.1, accuracy: 0.001, "Non-overridden repeatPenalty should use default")
        XCTAssertEqual(config.maxOutputTokens, 1024, "maxOutputTokens should match provided value")
    }

    func test_customInit_maxOutputTokens_customValue() {
        let config = GenerationConfig(maxOutputTokens: 4096)
        XCTAssertEqual(config.maxOutputTokens, 4096)
    }

    func test_customInit_maxOutputTokens_nil() {
        let config = GenerationConfig(maxOutputTokens: nil)
        XCTAssertNil(config.maxOutputTokens)
    }

    func test_maxOutputTokens_isMutable() {
        var config = GenerationConfig()
        config.maxOutputTokens = 512
        XCTAssertEqual(config.maxOutputTokens, 512)
    }

    func test_hints_jsonMode_isMutable() {
        var hints = GenerationRuntimeHints()
        hints.jsonMode = true
        XCTAssertTrue(hints.jsonMode)
    }

    // MARK: - Honest (lossless) Codable round-trip (#2152)

    /// After the runtime-hint split, `GenerationConfig` must round-trip through
    /// Codable with NO dropped fields — every field it declares survives
    /// encode → decode. Set every field to a non-default value and assert
    /// equality after a full cycle.
    func test_codableRoundtrip_preservesEveryField_noDrops() throws {
        var config = GenerationConfig(
            temperature: 0.33,
            topP: 0.44,
            repeatPenalty: 1.23,
            topK: 55,
            minP: 0.05,
            repetitionPenalty: 1.15,
            repetitionContextSize: 128,
            presencePenalty: 0.7,
            presenceContextSize: 96,
            frequencyPenalty: 0.6,
            frequencyContextSize: 72,
            llamaDRY: LlamaDRYSamplerOptions(multiplier: 0.9),
            llamaXTC: LlamaXTCSamplerOptions(probability: 0.2),
            llamaMirostatV2: LlamaMirostatV2SamplerOptions(tau: 4.0),
            seed: 987_654,
            maxOutputTokens: 321,
            tools: [],
            toolChoice: .required,
            maxThinkingTokens: 64,
            streamPrefillProgress: true,
            maxToolIterations: 7,
            grammar: "root ::= \"x\"",
            stopSequences: ["</s>", "STOP"],
            yieldEveryNTokens: 16,
            requiredCapabilities: [.toolCalling]
        )
        config.presenceContextSize = 96

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertEqual(decoded, config, "GenerationConfig must be losslessly Codable — no field may be dropped on round-trip")
    }

    /// The six extracted fields must NOT reappear on `GenerationConfig`'s wire
    /// form. Encoding a fully-populated config yields JSON with none of the
    /// former runtime-hint keys.
    func test_codable_omitsExtractedRuntimeHintKeys() throws {
        let config = GenerationConfig(temperature: 0.7, maxToolIterations: 3)
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in ["jsonMode", "thinkingMarkers", "structuredOutput", "documents", "maxRunTokens", "captureRenderedPrompt"] {
            XCTAssertNil(json[key], "\(key) must not appear on GenerationConfig's Codable payload — it moved to GenerationRuntimeHints")
        }
    }

    func test_streamPrefillProgress_isMutable() {
        var config = GenerationConfig()
        config.streamPrefillProgress = true
        XCTAssertTrue(config.streamPrefillProgress)
    }

    // MARK: - Mock Backend Captures maxOutputTokens

    func test_mockBackend_capturesMaxOutputTokens() async throws {
        let backend = MockInferenceBackend()
        try await backend.loadModel(from: URL(string: "file:///mock")!, plan: .testStub(effectiveContextSize: 512))

        let config = GenerationConfig(maxOutputTokens: 1024)
        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: config)
        for try await _ in stream.events {}

        XCTAssertEqual(backend.lastConfig?.maxOutputTokens, 1024)
    }

    // MARK: - mlx-swift-lm parity knobs (#750)

    func test_defaultInit_minP_isNil() {
        let config = GenerationConfig()
        XCTAssertNil(config.minP)
    }

    func test_defaultInit_repetitionPenalty_isNil() {
        let config = GenerationConfig()
        XCTAssertNil(config.repetitionPenalty)
    }

    func test_defaultInit_seed_isNil() {
        let config = GenerationConfig()
        XCTAssertNil(config.seed)
    }

    func test_customInit_propagatesParityKnobs() {
        let config = GenerationConfig(
            minP: 0.05,
            repetitionPenalty: 1.2,
            seed: 42
        )

        XCTAssertEqual(config.minP, 0.05)
        XCTAssertEqual(config.repetitionPenalty, 1.2)
        XCTAssertEqual(config.seed, 42)
    }

    func test_customInit_propagatesStreamPrefillProgress() {
        let config = GenerationConfig(streamPrefillProgress: true)
        XCTAssertTrue(config.streamPrefillProgress)
    }

    func test_minP_isMutable() {
        var config = GenerationConfig()
        config.minP = 0.1
        XCTAssertEqual(config.minP, 0.1)
    }

    func test_repetitionPenalty_isMutable() {
        var config = GenerationConfig()
        config.repetitionPenalty = 1.15
        XCTAssertEqual(config.repetitionPenalty, 1.15)
    }

    func test_seed_isMutable() {
        var config = GenerationConfig()
        config.seed = 1337
        XCTAssertEqual(config.seed, 1337)
    }

    // MARK: - Codable round-trip for parity knobs

    func test_codableRoundtrip_preservesParityKnobs() throws {
        var original = GenerationConfig(temperature: 0.5)
        original.minP = 0.07
        original.repetitionPenalty = 1.3
        original.seed = 9_999_999_999  // exceeds UInt32 to assert UInt64 storage
        original.streamPrefillProgress = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertEqual(decoded.minP, 0.07)
        XCTAssertEqual(decoded.repetitionPenalty, 1.3)
        XCTAssertEqual(decoded.seed, 9_999_999_999)
        XCTAssertTrue(decoded.streamPrefillProgress)
    }

    func test_codableDecode_legacyPayload_omittingParityKnobs() throws {
        // Older payloads that predate #750 do not carry minP/repetitionPenalty/seed.
        // The decoder must default them to nil rather than throwing.
        let legacyJSON = """
        {
            "temperature": 0.7,
            "topP": 0.9,
            "repeatPenalty": 1.1,
            "tools": [],
            "toolChoice": {"type": "auto"},
            "maxToolIterations": 10
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertNil(decoded.minP)
        XCTAssertNil(decoded.repetitionPenalty)
        XCTAssertNil(decoded.seed)
        XCTAssertFalse(decoded.streamPrefillProgress)
    }

    // MARK: - Additive penalty knobs + per-penalty windows

    func test_defaultInit_presencePenalty_isNil() {
        XCTAssertNil(GenerationConfig().presencePenalty)
    }

    func test_defaultInit_frequencyPenalty_isNil() {
        XCTAssertNil(GenerationConfig().frequencyPenalty)
    }

    func test_defaultInit_repetitionContextSize_isNil() {
        XCTAssertNil(GenerationConfig().repetitionContextSize)
    }

    func test_defaultInit_presenceContextSize_isNil() {
        XCTAssertNil(GenerationConfig().presenceContextSize)
    }

    func test_defaultInit_frequencyContextSize_isNil() {
        XCTAssertNil(GenerationConfig().frequencyContextSize)
    }

    func test_defaultInit_llamaDRY_isNil() {
        XCTAssertNil(GenerationConfig().llamaDRY)
    }

    func test_defaultInit_llamaXTC_isNil() {
        XCTAssertNil(GenerationConfig().llamaXTC)
    }

    func test_defaultInit_llamaMirostatV2_isNil() {
        XCTAssertNil(GenerationConfig().llamaMirostatV2)
    }

    func test_customInit_propagatesAdditivePenaltyKnobs() {
        let config = GenerationConfig(
            repetitionContextSize: 128,
            presencePenalty: 0.4,
            presenceContextSize: 32,
            frequencyPenalty: 0.6,
            frequencyContextSize: 16,
            llamaDRY: LlamaDRYSamplerOptions(multiplier: 0.8),
            llamaXTC: LlamaXTCSamplerOptions(probability: 0.5),
            llamaMirostatV2: LlamaMirostatV2SamplerOptions(tau: 6.0)
        )

        XCTAssertEqual(config.repetitionContextSize, 128)
        XCTAssertEqual(config.presencePenalty, 0.4)
        XCTAssertEqual(config.presenceContextSize, 32)
        XCTAssertEqual(config.frequencyPenalty, 0.6)
        XCTAssertEqual(config.frequencyContextSize, 16)
        XCTAssertEqual(config.llamaDRY, LlamaDRYSamplerOptions(multiplier: 0.8))
        XCTAssertEqual(config.llamaXTC, LlamaXTCSamplerOptions(probability: 0.5))
        XCTAssertEqual(config.llamaMirostatV2, LlamaMirostatV2SamplerOptions(tau: 6.0))
    }

    func test_llamaDRY_defaultsMatchLlamaCppCommonParams() {
        let options = LlamaDRYSamplerOptions()

        XCTAssertEqual(options.multiplier, 0.0)
        XCTAssertEqual(options.base, 1.75)
        XCTAssertEqual(options.allowedLength, 2)
        XCTAssertEqual(options.penaltyLastN, -1)
        XCTAssertEqual(options.sequenceBreakers, ["\n", ":", "\"", "*"])
    }

    func test_llamaXTC_defaultsMatchLlamaCppCommonParams() {
        let options = LlamaXTCSamplerOptions()

        XCTAssertEqual(options.probability, 0.0)
        XCTAssertEqual(options.threshold, 0.10)
        XCTAssertEqual(options.minKeep, 1)
        XCTAssertNil(options.seed)
    }

    func test_llamaMirostatV2_defaultsMatchLlamaCppCommonParams() {
        let options = LlamaMirostatV2SamplerOptions()

        XCTAssertEqual(options.tau, 5.0)
        XCTAssertEqual(options.eta, 0.1)
        XCTAssertNil(options.seed)
    }

    func test_codableRoundtrip_preservesAdditivePenaltyKnobs() throws {
        var original = GenerationConfig(temperature: 0.7)
        original.presencePenalty = 0.25
        original.frequencyPenalty = 0.5
        original.repetitionContextSize = 96
        original.presenceContextSize = 48
        original.frequencyContextSize = 24
        original.llamaDRY = LlamaDRYSamplerOptions(
            multiplier: 0.7,
            base: 1.9,
            allowedLength: 3,
            penaltyLastN: 256,
            sequenceBreakers: ["\n", "</s>"]
        )
        original.llamaXTC = LlamaXTCSamplerOptions(
            probability: 0.4,
            threshold: 0.15,
            minKeep: 2,
            seed: 12_345
        )
        original.llamaMirostatV2 = LlamaMirostatV2SamplerOptions(
            tau: 6.5,
            eta: 0.2,
            seed: 777
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertEqual(decoded.presencePenalty, 0.25)
        XCTAssertEqual(decoded.frequencyPenalty, 0.5)
        XCTAssertEqual(decoded.repetitionContextSize, 96)
        XCTAssertEqual(decoded.presenceContextSize, 48)
        XCTAssertEqual(decoded.frequencyContextSize, 24)
        XCTAssertEqual(decoded.llamaDRY, original.llamaDRY)
        XCTAssertEqual(decoded.llamaXTC, original.llamaXTC)
        XCTAssertEqual(decoded.llamaMirostatV2, original.llamaMirostatV2)
    }

    func test_codableDecode_legacyPayload_omittingAdditivePenaltyKnobs() throws {
        // Payloads written before this PR don't carry the additive-penalty fields.
        // Forward-compat: every new field must default to nil rather than throw.
        let legacyJSON = """
        {
            "temperature": 0.7,
            "topP": 0.9,
            "repeatPenalty": 1.1,
            "tools": [],
            "toolChoice": {"type": "auto"},
            "maxToolIterations": 10
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertNil(decoded.presencePenalty)
        XCTAssertNil(decoded.frequencyPenalty)
        XCTAssertNil(decoded.repetitionContextSize)
        XCTAssertNil(decoded.presenceContextSize)
        XCTAssertNil(decoded.frequencyContextSize)
        XCTAssertNil(decoded.llamaDRY)
        XCTAssertNil(decoded.llamaXTC)
        XCTAssertNil(decoded.llamaMirostatV2)
    }

    func test_codable_omitsAdditivePenaltyKnobsWhenNil() throws {
        // Defaults stay out of the wire payload to keep on-disk presets compact.
        let config = GenerationConfig()
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["presencePenalty"])
        XCTAssertNil(json["frequencyPenalty"])
        XCTAssertNil(json["repetitionContextSize"])
        XCTAssertNil(json["presenceContextSize"])
        XCTAssertNil(json["frequencyContextSize"])
        XCTAssertNil(json["llamaDRY"])
        XCTAssertNil(json["llamaXTC"])
        XCTAssertNil(json["llamaMirostatV2"])
    }

    // MARK: - Mock backend captures additive-penalty fields

    func test_mockBackend_capturesAdditivePenaltyKnobs() async throws {
        let backend = MockInferenceBackend()
        try await backend.loadModel(from: URL(string: "file:///mock")!, plan: .testStub(effectiveContextSize: 512))

        let config = GenerationConfig(
            repetitionContextSize: 80,
            presencePenalty: 0.3,
            presenceContextSize: 40,
            frequencyPenalty: 0.7,
            frequencyContextSize: 20,
            llamaDRY: LlamaDRYSamplerOptions(multiplier: 0.6),
            llamaXTC: LlamaXTCSamplerOptions(probability: 0.3),
            llamaMirostatV2: LlamaMirostatV2SamplerOptions(tau: 4.5)
        )
        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: config)
        for try await _ in stream.events {}

        XCTAssertEqual(backend.lastConfig?.repetitionContextSize, 80)
        XCTAssertEqual(backend.lastConfig?.presencePenalty, 0.3)
        XCTAssertEqual(backend.lastConfig?.presenceContextSize, 40)
        XCTAssertEqual(backend.lastConfig?.frequencyPenalty, 0.7)
        XCTAssertEqual(backend.lastConfig?.frequencyContextSize, 20)
        XCTAssertEqual(backend.lastConfig?.llamaDRY, LlamaDRYSamplerOptions(multiplier: 0.6))
        XCTAssertEqual(backend.lastConfig?.llamaXTC, LlamaXTCSamplerOptions(probability: 0.3))
        XCTAssertEqual(backend.lastConfig?.llamaMirostatV2, LlamaMirostatV2SamplerOptions(tau: 4.5))
    }

    // MARK: - Stop sequences (#1944)

    func test_defaultInit_stopSequences_isEmpty() {
        XCTAssertEqual(GenerationConfig().stopSequences, [])
    }

    func test_customInit_propagatesStopSequences() {
        let config = GenerationConfig(stopSequences: ["</s>", "STOP"])
        XCTAssertEqual(config.stopSequences, ["</s>", "STOP"])
    }

    func test_stopSequences_isMutable() {
        var config = GenerationConfig()
        config.stopSequences = ["\n\n"]
        XCTAssertEqual(config.stopSequences, ["\n\n"])
    }

    func test_codableRoundtrip_preservesStopSequences() throws {
        var original = GenerationConfig()
        original.stopSequences = ["</s>", "User:"]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertEqual(decoded.stopSequences, ["</s>", "User:"])
    }

    func test_codable_omitsStopSequencesWhenEmpty() throws {
        // Empty means "unset" — keep it out of the wire payload to preserve the
        // prior on-disk shape for callers that never set stops.
        let data = try JSONEncoder().encode(GenerationConfig())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["stopSequences"])
    }

    func test_codableDecode_legacyPayload_omittingStopSequences() throws {
        let legacyJSON = """
        {
            "temperature": 0.7,
            "topP": 0.9,
            "repeatPenalty": 1.1,
            "tools": [],
            "toolChoice": {"type": "auto"},
            "maxToolIterations": 10
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertEqual(decoded.stopSequences, [])
    }

    // MARK: - Equatable

    func test_equatable_identicalConfigs_areEqual() {
        let lhs = GenerationConfig(temperature: 0.5, topP: 0.8, maxOutputTokens: 1024)
        let rhs = GenerationConfig(temperature: 0.5, topP: 0.8, maxOutputTokens: 1024)

        XCTAssertEqual(lhs, rhs)
    }

    func test_equatable_oneFieldVariation_isUnequal() {
        let lhs = GenerationConfig(temperature: 0.5, topP: 0.8, maxOutputTokens: 1024)
        let rhs = GenerationConfig(temperature: 0.9, topP: 0.8, maxOutputTokens: 1024)

        XCTAssertNotEqual(lhs, rhs)
    }

    // MARK: - maxToolIterations loud clamp (#2152)

    /// The silent `didSet` clamp was replaced with a loud, `Log`-warned clamp.
    /// A `<= 0` budget passed to `init` still clamps to 1 (reads never observe
    /// a value below 1), and a valid value passes through unchanged.
    func test_maxToolIterations_init_clampsNonPositiveToOne() {
        XCTAssertEqual(GenerationConfig(maxToolIterations: 0).maxToolIterations, 1)
        XCTAssertEqual(GenerationConfig(maxToolIterations: -5).maxToolIterations, 1)
        XCTAssertEqual(GenerationConfig(maxToolIterations: 4).maxToolIterations, 4)
    }

    /// The clamp also fires on later assignment (the property is not a plain
    /// stored var), so mutating to `<= 0` still yields 1.
    func test_maxToolIterations_assignment_clampsNonPositiveToOne() {
        var config = GenerationConfig()
        config.maxToolIterations = 0
        XCTAssertEqual(config.maxToolIterations, 1)
        config.maxToolIterations = 9
        XCTAssertEqual(config.maxToolIterations, 9)
        config.maxToolIterations = -1
        XCTAssertEqual(config.maxToolIterations, 1)
    }

    /// A persisted zero/negative `maxToolIterations` decodes clamped to 1.
    func test_maxToolIterations_decode_clampsNonPositiveToOne() throws {
        let payload = """
        { "temperature": 0.7, "topP": 0.9, "repeatPenalty": 1.1, "maxToolIterations": 0 }
        """
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)
        XCTAssertEqual(decoded.maxToolIterations, 1)
    }

    // MARK: - Hints reach the backend (#2152)

    /// The per-request ``GenerationRuntimeHints`` must cross the
    /// `InferenceBackend` boundary intact — the whole point of the split.
    func test_hints_reachBackend_throughGenerate() throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let hints = GenerationRuntimeHints(jsonMode: true, maxRunTokens: 4096, captureRenderedPrompt: true)

        _ = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: hints
        )

        XCTAssertEqual(backend.lastHints, hints)
        XCTAssertEqual(backend.lastHints?.jsonMode, true)
        XCTAssertEqual(backend.lastHints?.maxRunTokens, 4096)
        XCTAssertEqual(backend.lastHints?.captureRenderedPrompt, true)
    }

    /// The 3-arg convenience overload forwards empty hints.
    func test_generate_threeArgOverload_forwardsEmptyHints() throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true

        _ = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())

        XCTAssertEqual(backend.lastHints, GenerationRuntimeHints())
    }
}
