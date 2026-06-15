import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for the ``ToolCall`` / ``ToolResult`` / ``ToolDefinition`` / ``ToolChoice``
/// contract introduced in ManifoldInference.
///
/// Covers:
/// - `GenerationConfig` round-trips (Codable) with tools and toolChoice
/// - `MockInferenceBackend` emits scripted tool calls in order
/// - `GenerationEvent.toolCall` is carried through a stream and consumed
/// - `GenerationStreamConsumer` maps `.toolCall` to `.dispatchToolCall`
final class ToolCallContractTests: XCTestCase {

    // MARK: - ToolDefinition Codable

    func test_toolDefinition_roundTrips() throws {
        let schema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")])
            ]),
            "required": .array([.string("city")])
        ])
        let def = ToolDefinition(name: "get_weather", description: "Returns weather.", parameters: schema)

        let encoded = try JSONEncoder().encode(def)
        let decoded = try JSONDecoder().decode(ToolDefinition.self, from: encoded)

        // Sabotage check: changing `def.name` to "" before encoding causes XCTAssertEqual to fail
        XCTAssertEqual(decoded.name, "get_weather")
        XCTAssertEqual(decoded.description, "Returns weather.")
        XCTAssertEqual(decoded.parameters, schema)
    }

    // MARK: - ToolCall Codable

    func test_toolCall_roundTrips() throws {
        let call = ToolCall(id: "call-1", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)

        let encoded = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: encoded)

        // Sabotage check: swapping `id` and `toolName` fields in encoding causes this to fail
        XCTAssertEqual(decoded.id, "call-1")
        XCTAssertEqual(decoded.toolName, "get_weather")
        XCTAssertEqual(decoded.arguments, #"{"city":"Paris"}"#)
    }

    // MARK: - ToolResult Codable

    func test_toolResult_roundTrips_success() throws {
        let result = ToolResult(callId: "call-1", content: "Sunny, 22°C")

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)

        XCTAssertEqual(decoded.callId, "call-1")
        XCTAssertEqual(decoded.content, "Sunny, 22°C")
        XCTAssertFalse(decoded.isError)
    }

    func test_toolResult_roundTrips_error() throws {
        let result = ToolResult(callId: "call-2", content: "City not found", errorKind: .notFound)

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)

        // Sabotage check: defaulting `errorKind` to `nil` in the init causes this to fail
        XCTAssertTrue(decoded.isError)
        XCTAssertEqual(decoded.errorKind, .notFound)
        XCTAssertEqual(decoded.content, "City not found")
    }

    // MARK: - ToolChoice Codable

    func test_toolChoice_auto_roundTrips() throws {
        let encoded = try JSONEncoder().encode(ToolChoice.auto)
        let decoded = try JSONDecoder().decode(ToolChoice.self, from: encoded)
        XCTAssertEqual(decoded, .auto)
    }

    func test_toolChoice_none_roundTrips() throws {
        let encoded = try JSONEncoder().encode(ToolChoice.none)
        let decoded = try JSONDecoder().decode(ToolChoice.self, from: encoded)
        XCTAssertEqual(decoded, .none)
    }

    func test_toolChoice_required_roundTrips() throws {
        let encoded = try JSONEncoder().encode(ToolChoice.required)
        let decoded = try JSONDecoder().decode(ToolChoice.self, from: encoded)
        XCTAssertEqual(decoded, .required)
    }

    func test_toolChoice_tool_roundTrips() throws {
        let encoded = try JSONEncoder().encode(ToolChoice.tool(name: "get_weather"))
        let decoded = try JSONDecoder().decode(ToolChoice.self, from: encoded)
        // Sabotage check: encoding the name as empty string causes XCTAssertEqual to fail
        XCTAssertEqual(decoded, .tool(name: "get_weather"))
    }

    // MARK: - GenerationConfig Codable with tools

    func test_generationConfig_defaultTools_isEmpty() {
        let config = GenerationConfig()
        XCTAssertTrue(config.tools.isEmpty)
        XCTAssertEqual(config.toolChoice, .auto)
    }

    func test_generationConfig_roundTrips_withTools() throws {
        let tool = ToolDefinition(
            name: "search",
            description: "Web search",
            parameters: .object(["type": .string("object")])
        )
        let config = GenerationConfig(tools: [tool], toolChoice: .required)

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: encoded)

        // Sabotage check: not encoding `tools` or `toolChoice` causes count == 0 and choice == .auto
        XCTAssertEqual(decoded.tools.count, 1)
        XCTAssertEqual(decoded.tools[0].name, "search")
        XCTAssertEqual(decoded.toolChoice, .required)
    }

    func test_generationConfig_roundTrips_toolChoiceTool() throws {
        let config = GenerationConfig(toolChoice: .tool(name: "search"))

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: encoded)

        XCTAssertEqual(decoded.toolChoice, .tool(name: "search"))
    }

    func test_generationConfig_existingProperties_unaffected() throws {
        // Adding tools/toolChoice plus the runtime-only jsonMode field must not
        // break existing serialised GenerationConfig values.
        let config = GenerationConfig(temperature: 0.8, topP: 0.95, maxOutputTokens: 512)

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: encoded)

        XCTAssertEqual(decoded.temperature, 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(decoded.maxOutputTokens, 512)
        // Defaults must survive the round-trip
        XCTAssertTrue(decoded.tools.isEmpty)
        XCTAssertEqual(decoded.toolChoice, .auto)
        XCTAssertFalse(decoded.jsonMode)
    }

    func test_generationConfig_codable_omitsRuntimeOnlyJsonMode() throws {
        let config = GenerationConfig(
            temperature: 0.8,
            topP: 0.95,
            maxOutputTokens: 512,
            jsonMode: true
        )

        let encoded = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: encoded)

        XCTAssertNil(json["jsonMode"])
        XCTAssertFalse(decoded.jsonMode)
    }

    func test_generationConfig_decodesLegacyJSON_withoutToolsOrToolChoice() throws {
        // Payloads serialised before the tools/toolChoice fields were introduced
        // must decode successfully, falling back to the canonical defaults
        // ([] / .auto / false for the runtime-only jsonMode flag).
        // Sabotage check: using `decode` instead of `decodeIfPresent` in init(from:)
        // causes a keyNotFound DecodingError here.
        let legacyJSON = """
        {"temperature":0.7,"topP":0.9,"repeatPenalty":1.1}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GenerationConfig.self, from: legacyJSON)

        XCTAssertEqual(decoded.temperature, 0.7, accuracy: 0.001)
        XCTAssertTrue(decoded.tools.isEmpty, "Missing 'tools' key must default to []")
        XCTAssertEqual(decoded.toolChoice, .auto, "Missing 'toolChoice' key must default to .auto")
        XCTAssertFalse(decoded.jsonMode, "Missing 'jsonMode' key must default to false")
    }

    // MARK: - MockInferenceBackend emits scripted tool calls

    func test_mockBackend_emitsScriptedToolCalls_afterTokens() async throws {
        let backend = MockInferenceBackend()
        try await backend.loadModel(
            from: URL(string: "file:///mock")!,
            plan: .testStub(effectiveContextSize: 512)
        )

        let call1 = ToolCall(id: "tc-1", toolName: "get_weather", arguments: #"{"city":"London"}"#)
        let call2 = ToolCall(id: "tc-2", toolName: "get_time", arguments: #"{"tz":"UTC"}"#)
        backend.tokensToYield = ["Hello"]
        backend.scriptedToolCalls = [call1, call2]

        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: .init())

        var tokens: [String] = []
        var toolCalls: [ToolCall] = []
        for try await event in stream.events {
            switch event {
            case .prefillProgress: break
            case .promptRendered: break
            case .token(let text): tokens.append(text)
            case .toolCall(let call): toolCalls.append(call)
            case .usage: break
            case .thinkingToken, .thinkingCompleted, .thinkingSignature: break
            case .toolResult, .toolProgress, .toolIterationLimitExceeded: break
            case .kvCacheReuse: break
            case .throttleDiagnostic: break
            case .toolCallStart, .toolCallArgumentsDelta: break
            case .toolDispatchStarted, .toolDispatchCompleted, .toolCallApproved: break
            case .toolCallParseFailed, .toolCallTruncated: break
            case .handoffRequested: break
            case .generationCompleted: break
            }
        }

        // Sabotage check: removing scriptedToolCalls emission from MockInferenceBackend.generate causes toolCalls.count == 0
        XCTAssertEqual(tokens, ["Hello"])
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "tc-1")
        XCTAssertEqual(toolCalls[1].id, "tc-2")
    }

    func test_mockBackend_emitsNoToolCalls_whenScriptedEmpty() async throws {
        let backend = MockInferenceBackend()
        try await backend.loadModel(
            from: URL(string: "file:///mock")!,
            plan: .testStub(effectiveContextSize: 512)
        )
        backend.tokensToYield = ["Hi"]
        // scriptedToolCalls defaults to []

        let stream = try backend.generate(prompt: "test", systemPrompt: nil, config: .init())

        var toolCalls: [ToolCall] = []
        for try await event in stream.events {
            if case .toolCall(let call) = event { toolCalls.append(call) }
        }

        XCTAssertTrue(toolCalls.isEmpty)
    }

    // MARK: - GenerationEvent.toolCall in stream

    func test_generationStream_deliversToolCallEvent() async throws {
        let expectedCall = ToolCall(id: "c1", toolName: "fn", arguments: "{}")
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.toolCall(expectedCall))
            continuation.finish()
        }
        let stream = GenerationStream(inner)

        var received: [ToolCall] = []
        for try await event in stream.events {
            if case .toolCall(let call) = event { received.append(call) }
        }

        // Sabotage check: removing `.toolCall` from GenerationEvent causes this stream to carry nothing
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].id, "c1")
        XCTAssertEqual(received[0].toolName, "fn")
    }

    func test_generationStream_mixedTokensAndToolCall() async throws {
        let call = ToolCall(id: "tc-3", toolName: "lookup", arguments: #"{"q":"swift"}"#)
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.token("Result: "))
            continuation.yield(.toolCall(call))
            continuation.finish()
        }
        let stream = GenerationStream(inner)

        var tokens: [String] = []
        var toolCalls: [ToolCall] = []
        for try await event in stream.events {
            switch event {
            case .prefillProgress: break
            case .promptRendered: break
            case .token(let t): tokens.append(t)
            case .toolCall(let c): toolCalls.append(c)
            case .usage: break
            case .thinkingToken, .thinkingCompleted, .thinkingSignature: break
            case .toolResult, .toolProgress, .toolIterationLimitExceeded: break
            case .kvCacheReuse: break
            case .throttleDiagnostic: break
            case .toolCallStart, .toolCallArgumentsDelta: break
            case .toolDispatchStarted, .toolDispatchCompleted, .toolCallApproved: break
            case .toolCallParseFailed, .toolCallTruncated: break
            case .handoffRequested: break
            case .generationCompleted: break
            }
        }

        XCTAssertEqual(tokens, ["Result: "])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].toolName, "lookup")
    }

    // MARK: - GenerationStreamConsumer handles toolCall

    func test_streamConsumer_toolCall_returnsDispatchToolCall() {
        var consumer = GenerationStreamConsumer()
        let call = ToolCall(id: "sc-1", toolName: "weather", arguments: "{}")

        let action = consumer.handle(.toolCall(call))

        // Sabotage check: returning .appendText("") for .toolCall in handle() causes XCTAssertEqual to fail
        XCTAssertEqual(action, .dispatchToolCall(call))
    }

    // MARK: - JSONSchemaValue edge cases

    func test_jsonSchemaValue_null_roundTrips() throws {
        let encoded = try JSONEncoder().encode(JSONSchemaValue.null)
        let decoded = try JSONDecoder().decode(JSONSchemaValue.self, from: encoded)
        XCTAssertEqual(decoded, .null)
    }

    func test_jsonSchemaValue_number_roundTrips() throws {
        let encoded = try JSONEncoder().encode(JSONSchemaValue.number(3.14))
        let decoded = try JSONDecoder().decode(JSONSchemaValue.self, from: encoded)
        if case .number(let n) = decoded {
            XCTAssertEqual(n, 3.14, accuracy: 0.001)
        } else {
            XCTFail("Expected .number, got \(decoded)")
        }
    }

    func test_jsonSchemaValue_array_roundTrips() throws {
        let value = JSONSchemaValue.array([.string("a"), .bool(true), .null])
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONSchemaValue.self, from: encoded)
        XCTAssertEqual(decoded, value)
    }

    func test_jsonSchemaValue_int64BeyondDoubleMantissa_roundTripsWithoutPrecisionLoss() throws {
        // 2^53 + 1 == 9007254740993 cannot survive a Double round-trip: it is the
        // first integer not exactly representable as a Double. Decoding it as
        // `.integer(Int64)` is what preserves the exact value.
        let raw = #"{"id": 9007199254740993}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(JSONSchemaValue.self, from: raw)
        guard case .object(let dict) = decoded, case .integer(let i) = dict["id"] else {
            return XCTFail("Expected .object containing .integer, got \(decoded)")
        }
        XCTAssertEqual(i, 9_007_199_254_740_993)

        // Encode → decode again to prove the value survives a full Codable cycle.
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(JSONSchemaValue.self, from: reEncoded)
        guard case .object(let dict2) = reDecoded, case .integer(let i2) = dict2["id"] else {
            return XCTFail("Expected .object containing .integer on re-decode, got \(reDecoded)")
        }
        // Sabotage check: route whole numbers through Double (drop the Int64
        // branch in init(from:)) and this becomes 9007199254740992, failing.
        XCTAssertEqual(i2, 9_007_199_254_740_993)
    }

    func test_jsonSchemaValue_fractionalNumberStaysNumber() throws {
        // Guard the decode ordering: a fractional literal must NOT be captured by
        // the Int64 branch — it stays `.number`.
        let raw = #"4.2"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(JSONSchemaValue.self, from: raw)
        guard case .number(let n) = decoded else {
            return XCTFail("Expected .number, got \(decoded)")
        }
        XCTAssertEqual(n, 4.2, accuracy: 0.0001)
    }
}
