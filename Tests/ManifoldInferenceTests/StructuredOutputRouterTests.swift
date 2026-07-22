import XCTest
@testable import ManifoldInference

// @MainActor: GenerationQueue.structuredOutputTarget(from:capabilities:) is
// @MainActor-isolated (GenerationQueue itself is), exercised by the
// .guided reconstruction tests below (#2354).
@MainActor
final class StructuredOutputRouterTests: XCTestCase {
    private struct GuidedFixture: Decodable {}

    /// A `SchemaProviding` fixture for `GenerationQueue.structuredOutputTarget`'s
    /// `.guided` reconstruction tests below (#2354) — distinct from
    /// `GuidedFixture` above, which deliberately does NOT conform, to also
    /// exercise the defensive non-conforming fallback.
    private struct GuidedSchemaFixture: Decodable, SchemaProviding {
        static var jsonSchema: JSONSchemaValue {
            .object([
                "type": .string("object"),
                "properties": .object([
                    "answer": .object(["type": .string("string")])
                ]),
                "required": .array([.string("answer")]),
            ])
        }
    }

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

    // MARK: - GenerationQueue.structuredOutputTarget(from:capabilities:) — .guided (#2354)

    /// A guided-capable backend (Foundation) reading a `.guided`-staged hint
    /// gets a target carrying the concrete type AND the schema recovered from
    /// its `SchemaProviding` conformance — the schema is what lets a NON-guided
    /// backend serving the same staged request still resolve to `.jsonSchema`
    /// instead of silently losing the constraint (see the next two tests).
    func test_structuredOutputTarget_guided_recoversSchemaFromConformance() {
        let target = GenerationQueue.structuredOutputTarget(
            from: .guided(GuidedSchemaFixture.self),
            capabilities: BackendCapabilities(supportsGuidedStructuredOutput: true)
        )

        XCTAssertNotNil(target)
        XCTAssertEqual(target?.guidedType.map(ObjectIdentifier.init), ObjectIdentifier(GuidedSchemaFixture.self))
        XCTAssertEqual(target?.jsonSchema, #"{"properties":{"answer":{"type":"string"}},"required":["answer"],"type":"object"}"#)
        XCTAssertNil(target?.gbnfGrammar, "no grammar without supportsGrammarConstrainedSampling")
    }

    /// When the serving backend ALSO supports grammar-constrained sampling,
    /// the `.guided`-staged hint still lowers to GBNF — the same upgrade path
    /// `.jsonSchema` already had, now reachable from `.guided` staging too.
    func test_structuredOutputTarget_guided_lowersToGrammarWhenSupported() {
        let target = GenerationQueue.structuredOutputTarget(
            from: .guided(GuidedSchemaFixture.self),
            capabilities: BackendCapabilities(
                supportsGrammarConstrainedSampling: true,
                supportsGuidedStructuredOutput: true
            )
        )

        XCTAssertNotNil(target?.gbnfGrammar)
    }

    /// A `.guided`-staged type that does NOT conform to `SchemaProviding`
    /// (unreachable from `respond`/`structured`'s generic constraint today,
    /// but defended against for a hypothetical future caller) degrades to a
    /// guided-only target rather than crashing — no jsonSchema/gbnfGrammar to
    /// recover, so a non-guided backend serving this request falls through to
    /// `.jsonPrompting`.
    func test_structuredOutputTarget_guided_nonConformingType_degradesGracefully() {
        let target = GenerationQueue.structuredOutputTarget(
            from: .guided(GuidedFixture.self),
            capabilities: BackendCapabilities(supportsGuidedStructuredOutput: true)
        )

        XCTAssertNotNil(target)
        XCTAssertEqual(target?.guidedType.map(ObjectIdentifier.init), ObjectIdentifier(GuidedFixture.self))
        XCTAssertNil(target?.jsonSchema)
        XCTAssertNil(target?.gbnfGrammar)
    }

    /// End-to-end proof that `.guided` staging survives round-trip through
    /// BOTH the reconstruction (`structuredOutputTarget`) and the selection
    /// (`StructuredOutputRouter.selectStrategy`) for a guided-capable backend
    /// — this is the exact two-step pipeline `GenerationQueue.enqueue` runs.
    func test_structuredOutputTarget_guided_thenRouter_selectsGuided() {
        let target = GenerationQueue.structuredOutputTarget(
            from: .guided(GuidedSchemaFixture.self),
            capabilities: BackendCapabilities(supportsGuidedStructuredOutput: true)
        )
        let strategy = StructuredOutputRouter.selectStrategy(
            capabilities: BackendCapabilities(supportsGuidedStructuredOutput: true),
            target: target!
        )

        XCTAssertEqual(strategy, .guided(GuidedSchemaFixture.self))
    }

    /// The same staged `.guided` hint, served by a backend that does NOT
    /// support guided generation but DOES support plain JSON Schema, resolves
    /// to `.jsonSchema` — the schema recovered via `SchemaProviding` in
    /// `structuredOutputTarget` is exactly what makes this fallback possible
    /// instead of the request silently losing its structure entirely.
    func test_structuredOutputTarget_guided_thenRouter_fallsBackToJsonSchemaForNonGuidedBackend() {
        let nonGuidedCapabilities = BackendCapabilities(supportsStructuredOutput: true)
        let target = GenerationQueue.structuredOutputTarget(
            from: .guided(GuidedSchemaFixture.self),
            capabilities: nonGuidedCapabilities
        )
        let strategy = StructuredOutputRouter.selectStrategy(
            capabilities: nonGuidedCapabilities,
            target: target!
        )

        XCTAssertEqual(strategy, .jsonSchema(#"{"properties":{"answer":{"type":"string"}},"required":["answer"],"type":"object"}"#))
    }
}
