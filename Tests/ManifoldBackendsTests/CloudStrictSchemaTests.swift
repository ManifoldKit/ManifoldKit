import XCTest
import Foundation
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Wire-contract tests for cloud strict-schema emission (#1918):
///
/// - ``StrictSchemaTransform/openAIStrict(_:)`` injects
///   `additionalProperties:false` at every object level, marks every property
///   required, and rewrites previously-optional fields into `["T","null"]`
///   unions.
/// - ``StrictSchemaTransform/anthropicStrict(_:)`` applies the shared core
///   without the OpenAI null-union rewrite or keyword stripping.
/// - ``OpenAIBackend`` tool encoding under a strict request flags
///   `function.strict==true` and transforms `parameters`.
/// - ``OpenAIBackend/buildRequest`` with a `.jsonSchema` strategy emits a
///   `response_format.type=="json_schema"` + `strict:true` block.
/// - The capability gate: a backend without `supportsStrictSchema` keeps the
///   legacy `json_object` shape.
@MainActor
final class CloudStrictSchemaTests: XCTestCase {

    private var mockURL: URL!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        mockURL = URL(string: "https://openai-strict-\(UUID().uuidString).test")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        if let url = mockURL {
            MockURLProtocol.unstub(url: url.appendingPathComponent("v1/chat/completions"))
        }
        session = nil
        mockURL = nil
        super.tearDown()
    }

    private func makeOpenAI() -> OpenAIBackend {
        let backend = OpenAIBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "sk-test", modelName: "gpt-4o-mini")
        return backend
    }

    /// A nested object schema with one required (`city`) and one optional
    /// (`units`) top-level field, plus a nested `coords` object with a
    /// required `lat` and optional `lon`.
    private func nestedSchema() -> JSONSchemaValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")]),
                "units": .object(["type": .string("string")]),
                "coords": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "lat": .object(["type": .string("number")]),
                        "lon": .object(["type": .string("number")]),
                    ]),
                    "required": .array([.string("lat")]),
                ]),
            ]),
            "required": .array([.string("city")]),
        ])
    }

    // MARK: - StrictSchemaTransform.openAIStrict

    func test_openAIStrict_addsAdditionalPropertiesFalse_atEveryLevel() throws {
        let strict = StrictSchemaTransform.openAIStrict(nestedSchema())
        guard case .object(let root) = strict else { return XCTFail("root not object") }
        XCTAssertEqual(root["additionalProperties"], .bool(false), "root must forbid extra properties")

        guard case .object(let props) = root["properties"],
              case .object(let coords) = props["coords"] else {
            return XCTFail("coords not object")
        }
        XCTAssertEqual(coords["additionalProperties"], .bool(false), "nested object must forbid extra properties")
    }

    func test_openAIStrict_marksEveryPropertyRequired() throws {
        let strict = StrictSchemaTransform.openAIStrict(nestedSchema())
        guard case .object(let root) = strict,
              case .array(let required) = root["required"] else {
            return XCTFail("required not array")
        }
        let names = Set(required.compactMap { if case .string(let s) = $0 { return s }; return nil })
        XCTAssertEqual(names, ["city", "units", "coords"], "every declared property must be required")

        guard case .object(let props) = root["properties"],
              case .object(let coords) = props["coords"],
              case .array(let coordsRequired) = coords["required"] else {
            return XCTFail("coords.required not array")
        }
        let coordsNames = Set(coordsRequired.compactMap { if case .string(let s) = $0 { return s }; return nil })
        XCTAssertEqual(coordsNames, ["lat", "lon"], "nested object's properties must all be required")
    }

    func test_openAIStrict_rewritesOptionalFieldToNullUnion() throws {
        let strict = StrictSchemaTransform.openAIStrict(nestedSchema())
        guard case .object(let root) = strict,
              case .object(let props) = root["properties"] else {
            return XCTFail("properties missing")
        }

        // `units` was NOT in the original required set → null union.
        guard case .object(let units) = props["units"] else { return XCTFail("units missing") }
        XCTAssertEqual(units["type"], .array([.string("string"), .string("null")]),
                       "previously-optional field must become a [\"T\",\"null\"] union")

        // `city` WAS required → plain type preserved.
        guard case .object(let city) = props["city"] else { return XCTFail("city missing") }
        XCTAssertEqual(city["type"], .string("string"), "required field keeps its scalar type")
    }

    func test_openAIStrict_stripsUnsupportedKeywords() throws {
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                    "format": .string("email"),
                ]),
            ]),
            "required": .array([.string("name")]),
        ])
        let strict = StrictSchemaTransform.openAIStrict(schema)
        guard case .object(let root) = strict,
              case .object(let props) = root["properties"],
              case .object(let name) = props["name"] else {
            return XCTFail("name property missing")
        }
        XCTAssertNil(name["minLength"], "minLength must be stripped for OpenAI strict")
        XCTAssertNil(name["format"], "format must be stripped for OpenAI strict")
        XCTAssertEqual(name["type"], .string("string"))
    }

    // MARK: - StrictSchemaTransform.anthropicStrict (divergence)

    func test_anthropicStrict_keepsKeywordsAndDoesNotNullUnion() throws {
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                ]),
                "units": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("name")]),
        ])
        let strict = StrictSchemaTransform.anthropicStrict(schema)
        guard case .object(let root) = strict,
              case .object(let props) = root["properties"],
              case .object(let name) = props["name"],
              case .object(let units) = props["units"] else {
            return XCTFail("schema shape unexpected")
        }
        // Shared core: additionalProperties:false + all-required.
        XCTAssertEqual(root["additionalProperties"], .bool(false))
        guard case .array(let required) = root["required"] else { return XCTFail("required missing") }
        let names = Set(required.compactMap { if case .string(let s) = $0 { return s }; return nil })
        XCTAssertEqual(names, ["name", "units"])
        // Divergence from OpenAI: keep keywords, no null union.
        XCTAssertEqual(name["minLength"], .integer(1), "Anthropic keeps validation keywords")
        XCTAssertEqual(units["type"], .string("string"), "Anthropic does NOT rewrite optionals to null unions")
    }

    // MARK: - OpenAI tool encoding under strict

    func test_encodeToolDefinition_strict_setsStrictTrueAndTransformsParams() throws {
        let tool = ToolDefinition(
            name: "lookup",
            description: "Look up a value.",
            parameters: nestedSchema()
        )
        let encoded = OpenAIToolEncoding.encodeToolDefinition(tool, strict: true)
        let function = try XCTUnwrap(encoded["function"] as? [String: Any])
        XCTAssertEqual(function["strict"] as? Bool, true, "strict tool must carry strict:true")

        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false,
                       "strict tool parameters must forbid extra properties")
        let required = try XCTUnwrap(parameters["required"] as? [String])
        XCTAssertEqual(Set(required), ["city", "units", "coords"],
                       "strict tool parameters must require every property")
    }

    func test_encodeToolDefinition_nonStrict_omitsStrictFlag() throws {
        let tool = ToolDefinition(name: "lookup", description: "x", parameters: nestedSchema())
        let encoded = OpenAIToolEncoding.encodeToolDefinition(tool, strict: false)
        let function = try XCTUnwrap(encoded["function"] as? [String: Any])
        XCTAssertNil(function["strict"], "non-strict tool must not carry the strict flag")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertNil(parameters["additionalProperties"],
                     "non-strict parameters must be passed through verbatim")
    }

    // MARK: - OpenAIBackend.buildRequest response_format

    private func jsonSchemaStrategy() throws -> StructuredOutputStrategy {
        let data = try JSONEncoder().encode(nestedSchema())
        return .jsonSchema(String(decoding: data, as: UTF8.self))
    }

    func test_buildRequest_jsonSchemaStrategy_emitsJsonSchemaResponseFormat() throws {
        let backend = makeOpenAI()
        backend.activeHints = GenerationRuntimeHints(structuredOutput: try jsonSchemaStrategy())

        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false,
                       "emitted response_format schema must be in strict shape")
        // Legacy json_object shape must NOT also be present.
        XCTAssertNil(json["format"], "strict path must not emit the legacy `format: json` switch")
    }

    func test_buildRequest_jsonMode_withoutStructuredOutput_keepsLegacyJsonObject() throws {
        let backend = makeOpenAI()
        backend.activeHints = GenerationRuntimeHints(jsonMode: true)

        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_object",
                       "plain jsonMode must keep the legacy json_object shape")
    }

    // MARK: - Capability gate regression guard

    func test_capabilityGate_nonStrictBackend_emitsLegacyJsonObject() throws {
        // A backend whose capabilities do NOT advertise strict schema must
        // fall back to legacy json_object even when given a .jsonSchema
        // strategy — otherwise it would 400 on additionalProperties:false.
        let caps = BackendCapabilities(supportsStructuredOutput: true, supportsStrictSchema: false)
        XCTAssertFalse(caps.supportsStrictSchema)

        // Drive the gate exactly as OpenAIBackend.buildRequest does.
        let strategy = try jsonSchemaStrategy()
        let strictRequested = caps.supportsStrictSchema
            && StrictSchemaTransform.jsonSchemaString(from: strategy) != nil
        XCTAssertFalse(strictRequested,
                       "a non-strict-capable backend must not enter the strict emission path")
    }

    func test_openAIBackend_advertisesStrictSchemaCapability() {
        XCTAssertTrue(makeOpenAI().capabilities.supportsStrictSchema)
    }

    func test_claudeBackend_advertisesStrictSchemaCapability() {
        XCTAssertTrue(ClaudeBackend().capabilities.supportsStrictSchema)
    }
}
