#if canImport(FoundationModels)
import XCTest
import FoundationModels
import BaseChatInference
@testable import BaseChatBackends
@testable import BaseChatFoundation

/// Coverage for the GuidedGeneration-backed tool-calling path on
/// `FoundationBackend` (issue #434).
///
/// The tests in this file split into two groups:
///
/// 1. **Schema-builder tests** — exercise `FoundationToolSchema` and
///    `FoundationEnvelope` in isolation. They never touch
///    `LanguageModelSession` and are safe to run on every CI runner that has
///    the iOS 26 / macOS 26 SDK headers.
///
/// 2. **End-to-end tool-call tests** — drive `FoundationBackend.generate(...)`
///    against a registered tool and assert that a `.toolCall(...)` event
///    surfaces. These require a live Apple Intelligence model and skip on
///    CI / simulator.
@available(iOS 26, macOS 26, *)
final class FoundationBackendToolCallingTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) else {
            throw XCTSkip("FoundationModels requires iOS 26 / macOS 26")
        }
    }

    // MARK: - Schema builder

    /// The envelope schema for a non-empty tool list must build without error.
    /// A failure here means a routine tool definition can no longer round-trip
    /// through `DynamicGenerationSchema` — apps that depend on Foundation
    /// tool calling would silently fall back to text-only.
    func test_makeEnvelope_buildsForCommonToolShape() throws {
        let weather = ToolDefinition(
            name: "get_weather",
            description: "Returns current weather for a city.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object([
                        "type": .string("string"),
                        "description": .string("City name"),
                    ]),
                    "units": .object([
                        "type": .string("string"),
                        "enum": .array([.string("metric"), .string("imperial")]),
                    ]),
                ]),
                "required": .array([.string("city")]),
            ])
        )

        XCTAssertNoThrow(try FoundationToolSchema.makeEnvelope(tools: [weather]))
    }

    /// Multiple tools should pack into a single envelope without name
    /// collisions in the dependency table.
    func test_makeEnvelope_handlesMultipleTools() throws {
        let a = ToolDefinition(name: "tool_a", description: "A", parameters: .object([
            "type": .string("object"),
            "properties": .object(["x": .object(["type": .string("string")])]),
        ]))
        let b = ToolDefinition(name: "tool_b", description: "B", parameters: .object([
            "type": .string("object"),
            "properties": .object(["y": .object(["type": .string("integer")])]),
        ]))
        XCTAssertNoThrow(try FoundationToolSchema.makeEnvelope(tools: [a, b]))
    }

    /// A tool whose parameter spec uses `anyOf` cannot be honoured by
    /// `DynamicGenerationSchema`. The mapper must throw with a clear keyword
    /// name rather than silently degrade — silent degradation would let an
    /// app register an `anyOf` tool and ship a model that can emit values the
    /// host's tool executor will reject. The caller (FoundationBackend.generate)
    /// catches this and falls back to text-only with a warning log.
    func test_makeEnvelope_throws_onAnyOfKeyword() {
        let badTool = ToolDefinition(
            name: "search",
            description: "Search.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "anyOf": .array([
                            .object(["type": .string("string")]),
                            .object(["type": .string("integer")]),
                        ])
                    ])
                ]),
            ])
        )
        XCTAssertThrowsError(try FoundationToolSchema.makeEnvelope(tools: [badTool])) { error in
            guard case FoundationToolSchemaError.unsupportedKeyword(let keyword) = error else {
                XCTFail("expected .unsupportedKeyword, got \(error)")
                return
            }
            XCTAssertEqual(keyword, "anyOf")
        }
    }

    /// `oneOf`, `$ref`, and `format` must also throw — the mapper is strict
    /// by design about every structural alternative or reference keyword.
    func test_makeEnvelope_throws_onEachUnsupportedKeyword() {
        let cases: [(keyword: String, schema: JSONSchemaValue)] = [
            ("oneOf", .object([
                "type": .string("object"),
                "oneOf": .array([.object(["type": .string("string")])]),
            ])),
            ("$ref", .object([
                "type": .string("object"),
                "$ref": .string("#/$defs/Other"),
            ])),
            ("format", .object([
                "type": .string("object"),
                "properties": .object([
                    "ts": .object([
                        "type": .string("string"),
                        "format": .string("date-time"),
                    ])
                ]),
            ])),
            ("const", .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "const": .string("event"),
                    ])
                ]),
            ])),
        ]
        for (expected, schema) in cases {
            let tool = ToolDefinition(name: "t", description: "", parameters: schema)
            XCTAssertThrowsError(try FoundationToolSchema.makeEnvelope(tools: [tool])) { error in
                guard case FoundationToolSchemaError.unsupportedKeyword(let keyword) = error else {
                    XCTFail("[\(expected)] expected .unsupportedKeyword, got \(error)")
                    return
                }
                XCTAssertEqual(keyword, expected)
            }
        }
    }

    /// A nullable type union (`type: ["string", "null"]`) must throw rather
    /// than silently degrade to a plain string — the schema would otherwise
    /// permit values the host's tool executor cannot decode.
    func test_makeEnvelope_throws_onNullableTypeUnion() {
        let tool = ToolDefinition(
            name: "lookup",
            description: "",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "key": .object([
                        "type": .array([.string("string"), .string("null")])
                    ])
                ]),
            ])
        )
        XCTAssertThrowsError(try FoundationToolSchema.makeEnvelope(tools: [tool])) { error in
            guard case FoundationToolSchemaError.unsupportedKeyword(let keyword) = error else {
                XCTFail("expected .unsupportedKeyword, got \(error)")
                return
            }
            XCTAssertTrue(keyword.contains("type"), "expected keyword to mention 'type', got: \(keyword)")
        }
    }

    /// A non-object root parameter spec (e.g. a bare `{"type": "string"}` at
    /// the top of `parameters`) must throw rather than silently degrade to an
    /// empty `{}` schema. Returning `{}` would let the model emit
    /// shape-correct envelopes the executor still rejects — the fail-closed
    /// keeps the round on the untooled path with a warning instead.
    func test_makeEnvelope_throws_onNonObjectRoot() {
        let tool = ToolDefinition(
            name: "echo",
            description: "",
            parameters: .string("string")  // not a JSON-Schema object
        )
        XCTAssertThrowsError(try FoundationToolSchema.makeEnvelope(tools: [tool])) { error in
            guard case FoundationToolSchemaError.unsupportedType(let detail) = error else {
                XCTFail("expected .unsupportedType, got \(error)")
                return
            }
            XCTAssertTrue(
                detail.contains("non-object root"),
                "detail must explain the failure mode, got: \(detail)"
            )
        }
    }

    /// The instructions blurb must mention every tool by name so the model
    /// can pick a branch based on prose alone (the schema constrains shape but
    /// the system-prompt copy steers selection).
    func test_instructions_mentionEveryRegisteredTool() {
        let a = ToolDefinition(name: "alpha", description: "first", parameters: .object([:]))
        let b = ToolDefinition(name: "bravo", description: "second", parameters: .object([:]))
        let copy = FoundationToolSchema.instructions(tools: [a, b])
        XCTAssertTrue(copy.contains("alpha"), "instructions must mention 'alpha', got: \(copy)")
        XCTAssertTrue(copy.contains("bravo"), "instructions must mention 'bravo', got: \(copy)")
    }

    /// Decoding a `tool_call` envelope must surface the tool name and a JSON
    /// arguments string the orchestrator can hand back to a tool executor.
    ///
    /// Sabotage check: change the `case "tool_call"` branch in
    /// `FoundationEnvelope.decode` to look up `props["arguments"]` under a
    /// different key (e.g. `"args"`). This test fails because the args lookup
    /// returns nil, decode returns nil, and the assertion below trips. Remove
    /// the sabotage before committing.
    func test_envelopeDecode_extractsToolCallBranch() throws {
        let argsContent = GeneratedContent(properties: [
            "city": "Paris",
        ])
        let envelopeContent = GeneratedContent(properties: [
            "kind": "tool_call",
            "name": "get_weather",
            "arguments": argsContent,
        ])

        guard let decoded = FoundationEnvelope.decode(envelopeContent) else {
            XCTFail("decode returned nil for a well-formed tool_call envelope")
            return
        }
        guard case .toolCall(let name, let argsJSON) = decoded else {
            XCTFail("expected .toolCall, got \(decoded)")
            return
        }
        XCTAssertEqual(name, "get_weather")
        XCTAssertTrue(argsJSON.contains("\"city\""), "args JSON must contain the city field, got: \(argsJSON)")
        XCTAssertTrue(argsJSON.contains("Paris"), "args JSON must contain the value 'Paris', got: \(argsJSON)")
    }

    /// Decoding a `text` envelope must surface the plain string.
    func test_envelopeDecode_extractsTextBranch() throws {
        let envelopeContent = GeneratedContent(properties: [
            "kind": "text",
            "text": "Hello there.",
        ])
        guard let decoded = FoundationEnvelope.decode(envelopeContent) else {
            XCTFail("decode returned nil for a well-formed text envelope")
            return
        }
        guard case .text(let s) = decoded else {
            XCTFail("expected .text, got \(decoded)")
            return
        }
        XCTAssertEqual(s, "Hello there.")
    }

    /// A malformed envelope (missing `kind`) decodes to nil so the backend
    /// can apply its raw-JSON fallback rather than crash.
    func test_envelopeDecode_returnsNil_forMalformedEnvelope() {
        let bogus = GeneratedContent(properties: [
            "something_else": "value",
        ])
        XCTAssertNil(FoundationEnvelope.decode(bogus))
    }

    // MARK: - End-to-end (Apple Intelligence required)

    /// Drives a full round trip against the on-device model with a tool
    /// registered. Asserts the structured-output path completes without error
    /// and surfaces *either* a text token stream or a `.toolCall(...)` —
    /// whichever branch the model chose. The schema constraint guarantees
    /// the envelope is well-formed; the model gets to pick the branch.
    ///
    /// We can't pin "the model must call this tool" deterministically — Apple
    /// Intelligence may decline ("I don't have real-time weather data") via
    /// the text branch. The contract this test pins is: the GuidedGeneration
    /// channel works end-to-end, emits valid events, and never crashes.
    ///
    /// Sabotage check: change the `runToolAwareStream` call site in
    /// `FoundationBackend.generate` to always take the text-only branch
    /// (e.g. `if let toolEnvelope = nil as GenerationSchema?`). The stream
    /// will still emit tokens but the schema constraint will not be applied —
    /// this test still passes (text branch is allowed), but `test_envelopeDecode_*`
    /// continues to anchor the contract. To exercise stronger sabotage, set
    /// the `kind` literal in `FoundationToolSchema.makeEnvelope`'s text branch
    /// to `"texxt"`. The envelope decode path then fails for every text
    /// response, no `.token` events are emitted, and this test fails.
    func test_generate_completesAgainstTooledSchema() async throws {
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Apple Intelligence not available — cannot exercise the live tool-calling path"
        )
        let ready = await FoundationBackend.probeIsReady()
        try XCTSkipUnless(ready, "Apple Intelligence not ready — ensure it is enabled and downloaded in System Settings > Apple Intelligence & Siri")

        let backend = FoundationBackend()
        let url = URL(fileURLWithPath: "/dev/null")
        try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))

        let weather = ToolDefinition(
            name: "get_weather",
            description: "Fetches current weather for a city. Always call this tool when the user asks about the weather.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object([
                        "type": .string("string"),
                        "description": .string("City name to look up."),
                    ]),
                ]),
                "required": .array([.string("city")]),
            ])
        )

        var config = GenerationConfig()
        config.tools = [weather]
        config.toolChoice = .auto

        let stream = try backend.generate(
            prompt: "What is the weather in Paris right now?",
            systemPrompt: "You are a helpful assistant.",
            config: config
        )

        var sawAnyEvent = false
        var sawToolCall = false
        var sawToken = false
        for try await event in stream.events {
            sawAnyEvent = true
            switch event {
            case .toolCall(let call):
                sawToolCall = true
                XCTAssertEqual(call.toolName, "get_weather", "tool name must match the schema-constrained anyOf")
                XCTAssertFalse(call.arguments.isEmpty, "arguments must be a JSON-encoded object")
            case .token:
                sawToken = true
            default:
                break
            }
        }
        backend.stopGeneration()

        XCTAssertTrue(sawAnyEvent, "stream must yield at least one event")
        XCTAssertTrue(
            sawToolCall || sawToken,
            "stream must emit either tokens (text branch) or a tool call — got neither"
        )
    }
}
#endif
