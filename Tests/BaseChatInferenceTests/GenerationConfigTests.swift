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
            "jsonMode": false,
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
}
