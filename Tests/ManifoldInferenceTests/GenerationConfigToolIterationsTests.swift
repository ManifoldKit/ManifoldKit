import XCTest
@testable import ManifoldInference

/// Tests for the ``GenerationConfig/maxToolIterations`` budget introduced
/// alongside ``ToolRegistry`` in wave 1.
final class GenerationConfigToolIterationsTests: XCTestCase {

    // MARK: - Default value

    func test_default_is10() {
        let config = GenerationConfig()
        XCTAssertEqual(config.maxToolIterations, 10)
    }

    func test_customValue_isPreserved() {
        let config = GenerationConfig(maxToolIterations: 3)
        XCTAssertEqual(config.maxToolIterations, 3)
    }

    // MARK: - Clamp

    func test_zero_initArgument_clampedToOne() {
        let config = GenerationConfig(maxToolIterations: 0)
        XCTAssertEqual(config.maxToolIterations, 1)
    }

    func test_negative_initArgument_clampedToOne() {
        let config = GenerationConfig(maxToolIterations: -5)
        XCTAssertEqual(config.maxToolIterations, 1)
    }

    func test_assignmentAfterInit_clampedToOne() {
        var config = GenerationConfig()
        config.maxToolIterations = -1
        XCTAssertEqual(config.maxToolIterations, 1)
    }

    // MARK: - Codable round-trip

    func test_roundTrip_preservesCustomValue() throws {
        let config = GenerationConfig(maxToolIterations: 4)
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: encoded)
        XCTAssertEqual(decoded.maxToolIterations, 4)
    }

    func test_roundTrip_preservesDefault() throws {
        let config = GenerationConfig()
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: encoded)
        XCTAssertEqual(decoded.maxToolIterations, 10)
    }

    func test_legacyPayload_withoutField_defaultsTo10() throws {
        // Payloads serialised before maxToolIterations was added must still
        // decode with the canonical default.
        let legacy = """
        {"temperature":0.7,"topP":0.9,"repeatPenalty":1.1,"tools":[],"toolChoice":{"type":"auto"},"jsonMode":false}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: legacy)

        XCTAssertEqual(decoded.maxToolIterations, 10)
    }

    func test_legacyPayload_withZeroField_clampedTo1() throws {
        // Defensive: a persisted zero (e.g. from a pre-release build) should
        // still yield loop-viable semantics after decode.
        let legacy = #"{"temperature":0.7,"topP":0.9,"repeatPenalty":1.1,"tools":[],"toolChoice":{"type":"auto"},"jsonMode":false,"maxToolIterations":0}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: legacy)

        XCTAssertEqual(decoded.maxToolIterations, 1)
    }
}
