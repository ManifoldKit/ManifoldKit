import XCTest
@testable import ManifoldInference

/// Tests for `GenerationConfig.grammar` introduced in #663.
final class GenerationConfigGrammarTests: XCTestCase {

    // MARK: - Default

    func test_grammar_defaultsToNil() {
        let config = GenerationConfig()
        XCTAssertNil(config.grammar)
    }

    // MARK: - Mutable

    func test_grammar_isMutable() {
        var config = GenerationConfig()
        config.grammar = #"root ::= "hello" | "world""#
        XCTAssertEqual(config.grammar, #"root ::= "hello" | "world""#)
    }

    // MARK: - Codable round-trip with grammar set

    func test_codable_roundTrip_withGrammar() throws {
        var config = GenerationConfig()
        config.grammar = #"root ::= [a-z]+"#

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)

        XCTAssertEqual(decoded.grammar, #"root ::= [a-z]+"#)
    }

    // MARK: - Codable backward-compat: absent grammar decodes as nil

    func test_codable_roundTrip_withoutGrammar_decodesNil() throws {
        // Encode a config without grammar (nil by default).
        let config = GenerationConfig()
        let data = try JSONEncoder().encode(config)

        // Confirm the JSON does not contain the grammar key at all.
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["grammar"], "grammar key should be absent when nil")

        // Decode and assert nil.
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: data)
        XCTAssertNil(decoded.grammar)
    }
}
