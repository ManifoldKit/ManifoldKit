import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

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

    func test_defaultInit_jsonMode() {
        let config = GenerationConfig()
        XCTAssertFalse(config.jsonMode)
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
            maxOutputTokens: 2048,
            jsonMode: true
        )

        XCTAssertEqual(config.temperature, 1.2, accuracy: 0.001)
        XCTAssertEqual(config.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(config.repeatPenalty, 1.5, accuracy: 0.001)
        XCTAssertEqual(config.maxOutputTokens, 2048)
        XCTAssertTrue(config.jsonMode)
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

    func test_jsonMode_isMutable() {
        var config = GenerationConfig()
        config.jsonMode = true
        XCTAssertTrue(config.jsonMode)
    }

    func test_codable_omitsJsonMode_evenWhenTrue() throws {
        let config = GenerationConfig(jsonMode: true)

        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["jsonMode"])
    }

    func test_codable_decode_resetsRuntimeOnlyJsonModeToFalse() throws {
        let payload = """
        {
            "temperature": 0.7,
            "topP": 0.9,
            "repeatPenalty": 1.1,
            "maxTokens": 512,
            "jsonMode": true
        }
        """
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertFalse(decoded.jsonMode)
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

    func test_customInit_propagatesAdditivePenaltyKnobs() {
        let config = GenerationConfig(
            repetitionContextSize: 128,
            presencePenalty: 0.4,
            presenceContextSize: 32,
            frequencyPenalty: 0.6,
            frequencyContextSize: 16,
            llamaDRY: LlamaDRYSamplerOptions(multiplier: 0.8)
        )

        XCTAssertEqual(config.repetitionContextSize, 128)
        XCTAssertEqual(config.presencePenalty, 0.4)
        XCTAssertEqual(config.presenceContextSize, 32)
        XCTAssertEqual(config.frequencyPenalty, 0.6)
        XCTAssertEqual(config.frequencyContextSize, 16)
        XCTAssertEqual(config.llamaDRY, LlamaDRYSamplerOptions(multiplier: 0.8))
    }

    func test_llamaDRY_defaultsMatchLlamaCppCommonParams() {
        let options = LlamaDRYSamplerOptions()

        XCTAssertEqual(options.multiplier, 0.0)
        XCTAssertEqual(options.base, 1.75)
        XCTAssertEqual(options.allowedLength, 2)
        XCTAssertEqual(options.penaltyLastN, -1)
        XCTAssertEqual(options.sequenceBreakers, ["\n", ":", "\"", "*"])
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

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertEqual(decoded.presencePenalty, 0.25)
        XCTAssertEqual(decoded.frequencyPenalty, 0.5)
        XCTAssertEqual(decoded.repetitionContextSize, 96)
        XCTAssertEqual(decoded.presenceContextSize, 48)
        XCTAssertEqual(decoded.frequencyContextSize, 24)
        XCTAssertEqual(decoded.llamaDRY, original.llamaDRY)
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
            llamaDRY: LlamaDRYSamplerOptions(multiplier: 0.6)
        )
        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: config)
        for try await _ in stream.events {}

        XCTAssertEqual(backend.lastConfig?.repetitionContextSize, 80)
        XCTAssertEqual(backend.lastConfig?.presencePenalty, 0.3)
        XCTAssertEqual(backend.lastConfig?.presenceContextSize, 40)
        XCTAssertEqual(backend.lastConfig?.frequencyPenalty, 0.7)
        XCTAssertEqual(backend.lastConfig?.frequencyContextSize, 20)
        XCTAssertEqual(backend.lastConfig?.llamaDRY, LlamaDRYSamplerOptions(multiplier: 0.6))
    }
}
