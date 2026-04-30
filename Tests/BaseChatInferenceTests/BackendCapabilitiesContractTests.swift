import XCTest
@testable import BaseChatInference

/// Contract tests for new `BackendCapabilities` flags introduced in #663.
final class BackendCapabilitiesContractTests: XCTestCase {

    // MARK: - supportsKVCachePersistence defaults to false

    func test_supportsKVCachePersistence_defaultsFalse() {
        let caps = BackendCapabilities()
        XCTAssertFalse(caps.supportsKVCachePersistence)
    }

    // MARK: - supportsGrammarConstrainedSampling defaults to false

    func test_supportsGrammarConstrainedSampling_defaultsFalse() {
        let caps = BackendCapabilities()
        XCTAssertFalse(caps.supportsGrammarConstrainedSampling)
    }

    // MARK: - supportsThinking defaults to false

    func test_supportsThinking_defaultsFalse() {
        let caps = BackendCapabilities()
        XCTAssertFalse(caps.supportsThinking,
                       "supportsThinking must default to false so cloud backends remain source-compatible")
    }

    // MARK: - supportsVision defaults to false

    func test_supportsVision_defaultsFalse() {
        let caps = BackendCapabilities()
        XCTAssertFalse(caps.supportsVision,
                       "supportsVision must default to false so text-only backends never advertise image input accidentally")
    }

    // MARK: - Codable forward-compat: old JSON missing new keys defaults both to false

    func test_codable_forwardCompat_missingNewKeys_defaultsToFalse() throws {
        // This is the minimal valid BackendCapabilities payload from before #663.
        let json = """
        {
            "supportedParameters": ["temperature"],
            "maxContextTokens": 4096,
            "maxOutputTokens": 2048,
            "requiresPromptTemplate": false,
            "supportsSystemPrompt": true,
            "supportsStreaming": true,
            "supportsToolCalling": false,
            "supportsStructuredOutput": false,
            "supportsNativeJSONMode": false,
            "cancellationStyle": "cooperative",
            "supportsTokenCounting": false,
            "memoryStrategy": "resident",
            "isRemote": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BackendCapabilities.self, from: json)

        XCTAssertFalse(decoded.supportsKVCachePersistence,
                       "supportsKVCachePersistence must default to false for old payloads")
        XCTAssertFalse(decoded.supportsGrammarConstrainedSampling,
                       "supportsGrammarConstrainedSampling must default to false for old payloads")
        XCTAssertFalse(decoded.supportsThinking,
                       "supportsThinking must default to false for old payloads")
        XCTAssertFalse(decoded.supportsVision,
                       "supportsVision must default to false for old payloads")
    }

    // MARK: - Full round-trip with new flags set to true

    func test_codable_roundTrip_newFlagsTrue() throws {
        let caps = BackendCapabilities(
            supportsKVCachePersistence: true,
            supportsGrammarConstrainedSampling: true,
            supportsThinking: true,
            supportsVision: true
        )

        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(BackendCapabilities.self, from: data)

        XCTAssertTrue(decoded.supportsKVCachePersistence)
        XCTAssertTrue(decoded.supportsGrammarConstrainedSampling)
        XCTAssertTrue(decoded.supportsThinking)
        XCTAssertTrue(decoded.supportsVision)
    }
}
