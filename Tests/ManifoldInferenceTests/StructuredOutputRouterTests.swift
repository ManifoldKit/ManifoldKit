import XCTest
@testable import ManifoldInference

final class StructuredOutputRouterTests: XCTestCase {
    private struct GuidedFixture: Decodable {}

    func test_selectStrategy_prefersGrammarWhenSupported() {
        let caps = BackendCapabilities(supportsGrammarConstrainedSampling: true)
        let target = StructuredOutputTarget(
            gbnfGrammar: #"root ::= "ok""#,
            guidedType: GuidedFixture.self,
            jsonSchema: #"{"type":"object"}"#
        )

        let strategy = StructuredOutputRouter.selectStrategy(capabilities: caps, target: target)

        XCTAssertEqual(strategy, .gbnf(#"root ::= "ok""#))
    }

    func test_selectStrategy_usesGuidedWhenGrammarUnavailable() {
        let caps = BackendCapabilities(supportsGuidedStructuredOutput: true)
        let target = StructuredOutputTarget(
            guidedType: GuidedFixture.self,
            jsonSchema: #"{"type":"object"}"#
        )

        let strategy = StructuredOutputRouter.selectStrategy(capabilities: caps, target: target)

        XCTAssertEqual(strategy, .guided(GuidedFixture.self))
    }

    func test_selectStrategy_usesJsonSchemaWhenSupported() {
        let caps = BackendCapabilities(supportsStructuredOutput: true)
        let strategy = StructuredOutputRouter.selectStrategy(
            capabilities: caps,
            jsonSchema: #"{"type":"object","properties":{}}"#
        )

        XCTAssertEqual(strategy, .jsonSchema(#"{"type":"object","properties":{}}"#))
    }

    func test_selectStrategy_fallsBackToJsonPrompting() {
        let caps = BackendCapabilities()
        let strategy = StructuredOutputRouter.selectStrategy(
            capabilities: caps,
            guidedType: GuidedFixture.self,
            jsonSchema: #"{"type":"object"}"#
        )

        XCTAssertEqual(strategy, .jsonPrompting)
    }

    func test_targetEncodesExistingJSONSchemaValue() throws {
        let target = try StructuredOutputTarget.jsonSchema(.object([
            "type": .string("object"),
            "properties": .object([
                "answer": .object(["type": .string("string")])
            ])
        ]))

        XCTAssertEqual(
            target.jsonSchema,
            #"{"properties":{"answer":{"type":"string"}},"type":"object"}"#
        )
    }

    func test_structuredOutput_isRuntimeOnly_onHints() throws {
        // structuredOutput moved off GenerationConfig into the non-Codable
        // GenerationRuntimeHints (#2152): it is a per-request runtime input, so
        // it carries on the hints and never appears on the config's persisted
        // payload.
        let hints = GenerationRuntimeHints(structuredOutput: .jsonSchema(#"{"type":"object"}"#))
        XCTAssertEqual(hints.structuredOutput, .jsonSchema(#"{"type":"object"}"#))

        // A config encodes without any structuredOutput key.
        let data = try JSONEncoder().encode(GenerationConfig())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["structuredOutput"])
    }

    func test_capabilitiesPreferredStructuredOutputSupport() {
        XCTAssertEqual(
            BackendCapabilities(supportsGrammarConstrainedSampling: true).preferredStructuredOutputSupport,
            .grammarConstrainedSampling
        )
        XCTAssertEqual(
            BackendCapabilities(supportsGuidedStructuredOutput: true).preferredStructuredOutputSupport,
            .guidedGeneration
        )
        XCTAssertEqual(
            BackendCapabilities(supportsStructuredOutput: true).preferredStructuredOutputSupport,
            .jsonSchema
        )
        XCTAssertEqual(
            BackendCapabilities().preferredStructuredOutputSupport,
            .jsonPrompting
        )
    }
}
