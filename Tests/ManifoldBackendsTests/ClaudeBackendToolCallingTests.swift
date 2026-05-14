#if CloudSaaS
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Tool-calling wire-contract tests for ``ClaudeBackend`` (Anthropic
/// Messages API).
///
/// Coverage matrix (per #435 + #436):
/// - Tool definitions serialise into the Anthropic `tools[]` envelope
///   (`{name, description, input_schema}`).
/// - `tool_choice` mapping covers every ``ToolChoice`` case, including the
///   `.none → omit tools entirely` rule (Anthropic has no `tool_choice:none`
///   wire value).
/// - Streaming `content_block_*` events for parallel tool_use blocks decode
///   into the `.toolCallStart` → N×`.toolCallArgumentsDelta` → `.toolCall`
///   sequence from PR #783, with per-block `.toolCall` finalisation on
///   `content_block_stop` so tool dispatch can begin before `message_stop`.
/// - Empty-input tool_use blocks (no `input_json_delta` events) still emit a
///   single synthetic `"{}"` delta to keep the event surface uniform.
/// - Whole-message `content:[{type:"tool_use",...}, ...]` payloads fan out
///   into the same start + delta + toolCall triple per block.
/// - Mid-stream cancellation suppresses any `.toolCall` emission for
///   incomplete blocks.
/// - Tool-result history feedback produces the user-role `tool_result`
///   content blocks Anthropic expects.
/// - Capability flags are flipped for tool calling, streaming arguments,
///   and parallel tool calls.
@MainActor
final class ClaudeBackendToolCallingTests: XCTestCase {

    // MARK: - Fixtures

    private var mockURL: URL!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        mockURL = URL(string: "https://claude-toolcall-\(UUID().uuidString).test")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        if let url = mockURL {
            MockURLProtocol.unstub(url: url.appendingPathComponent("v1/messages"))
        }
        session = nil
        mockURL = nil
        super.tearDown()
    }

    private func makeBackend() -> (ClaudeBackend, messagesURL: URL) {
        let backend = ClaudeBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        return (backend, mockURL.appendingPathComponent("v1/messages"))
    }

    private func load(_ backend: ClaudeBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    private func sseChunk(_ json: String) -> Data {
        Data("data: \(json)\n\n".utf8)
    }

    private func drain(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func weatherTool() -> ToolDefinition {
        ToolDefinition(
            name: "get_weather",
            description: "Fetch current weather for a city.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")])
                ]),
                "required": .array([.string("city")]),
            ])
        )
    }

    private func timeTool() -> ToolDefinition {
        ToolDefinition(
            name: "lookup_time",
            description: "Return the current time.",
            parameters: .object(["type": .string("object")])
        )
    }

    // MARK: - Capabilities

    func test_capabilities_supportsToolCalling_andStreamingArguments_andParallel() {
        let caps = ClaudeBackend().capabilities
        XCTAssertTrue(caps.supportsToolCalling, "supportsToolCalling must be true")
        XCTAssertTrue(caps.streamsToolCallArguments, "streamsToolCallArguments must be true")
        XCTAssertTrue(caps.supportsParallelToolCalls, "supportsParallelToolCalls must be true")
    }

    // MARK: - Request body shape

    func test_requestBody_includesToolsArray_andInputSchema() throws {
        let (backend, _) = makeBackend()
        var config = GenerationConfig()
        config.tools = [weatherTool(), timeTool()]

        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: config)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0]["name"] as? String, "get_weather")
        XCTAssertEqual(tools[0]["description"] as? String, "Fetch current weather for a city.")
        let schema0 = try XCTUnwrap(tools[0]["input_schema"] as? [String: Any])
        XCTAssertEqual(schema0["type"] as? String, "object")
        let properties = try XCTUnwrap(schema0["properties"] as? [String: Any])
        XCTAssertNotNil(properties["city"])
        let required = try XCTUnwrap(schema0["required"] as? [String])
        XCTAssertEqual(required, ["city"])

        XCTAssertEqual(tools[1]["name"] as? String, "lookup_time")
    }

    func test_requestBody_omitsTools_whenToolsEmpty() throws {
        let (backend, _) = makeBackend()
        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["tool_choice"])
    }

    func test_requestBody_toolChoice_mapping_auto_required_tool_none() throws {
        // .auto → no tool_choice field (Anthropic default).
        // .required → {type:"any"}.
        // .tool(name) → {type:"tool", name}.
        // .none → drops the tools field entirely (no wire value exists).
        let cases: [ToolChoice] = [.auto, .required, .tool(name: "pick_me"), .none]
        for choice in cases {
            let (backend, _) = makeBackend()
            var config = GenerationConfig()
            config.tools = [weatherTool()]
            config.toolChoice = choice

            let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: config)
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

            switch choice {
            case .auto:
                XCTAssertNotNil(json["tools"], ".auto must keep the tools field")
                XCTAssertNil(json["tool_choice"], ".auto must omit tool_choice")
            case .required:
                XCTAssertNotNil(json["tools"])
                let obj = try XCTUnwrap(json["tool_choice"] as? [String: Any])
                XCTAssertEqual(obj["type"] as? String, "any")
            case .tool(let name):
                XCTAssertNotNil(json["tools"])
                let obj = try XCTUnwrap(json["tool_choice"] as? [String: Any])
                XCTAssertEqual(obj["type"] as? String, "tool")
                XCTAssertEqual(obj["name"] as? String, name)
            case .none:
                XCTAssertNil(json["tools"], ".none must drop tools entirely")
                XCTAssertNil(json["tool_choice"], ".none must drop tool_choice")
            }
        }
    }

    // MARK: - Streaming deltas (parallel tool_use blocks)

    /// Two parallel tool_use blocks in the same assistant turn — each has
    /// its own `index` (0 and 1) interleaved with `input_json_delta`
    /// fragments. The accumulator routes deltas by index and emits
    /// `.toolCallStart` events on each `content_block_start` and
    /// `.toolCall` events on each `content_block_stop`.
    func test_streaming_twoParallelToolUseBlocks_emitsStartDeltasAndToolCalls() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        // Realistic Anthropic SSE shape — message_start, two tool_use
        // content blocks with interleaved input_json_delta fragments,
        // content_block_stop per block, message_delta with stop_reason,
        // message_stop.
        let chunks: [Data] = [
            sseChunk(#"{"type":"message_start","message":{"id":"msg_1","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":42}}}"#),
            sseChunk(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_abc","name":"get_weather","input":{}}}"#),
            sseChunk(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#),
            sseChunk(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_xyz","name":"lookup_time","input":{}}}"#),
            sseChunk(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"Rome\"}"}}"#),
            sseChunk(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#),
            sseChunk(#"{"type":"content_block_stop","index":0}"#),
            sseChunk(#"{"type":"content_block_stop","index":1}"#),
            sseChunk(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}"#),
            sseChunk(#"{"type":"message_stop"}"#),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        // .toolCallStart events fire in the order content_block_start
        // events arrive — index 0 then index 1.
        let starts = events.compactMap { event -> (String, String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 2, "expected one toolCallStart per tool_use block, got events: \(events)")
        XCTAssertEqual(starts[0].0, "toolu_abc")
        XCTAssertEqual(starts[0].1, "get_weather")
        XCTAssertEqual(starts[1].0, "toolu_xyz")
        XCTAssertEqual(starts[1].1, "lookup_time")

        // Argument deltas concatenate per call into valid JSON. Critically,
        // each delta is keyed by the tool_use block's id, NOT the index —
        // breaking that mapping is the sabotage check this test guards.
        var deltasById: [String: String] = [:]
        for event in events {
            if case .toolCallArgumentsDelta(let id, let frag) = event {
                deltasById[id, default: ""] += frag
            }
        }
        XCTAssertEqual(deltasById["toolu_abc"], #"{"city":"Rome"}"#)
        XCTAssertEqual(deltasById["toolu_xyz"], "{}")

        // .toolCall events fire on each content_block_stop — index 0
        // finalised before index 1 because Anthropic emitted the stops in
        // that order.
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "toolu_abc")
        XCTAssertEqual(toolCalls[0].toolName, "get_weather")
        XCTAssertEqual(toolCalls[0].arguments, #"{"city":"Rome"}"#)
        XCTAssertEqual(toolCalls[1].id, "toolu_xyz")
        XCTAssertEqual(toolCalls[1].toolName, "lookup_time")
        XCTAssertEqual(toolCalls[1].arguments, "{}")
    }

    /// Empty-input tool_use: `content_block_start` declares the call but
    /// no `input_json_delta` events arrive before `content_block_stop`.
    /// The backend must emit exactly one synthetic `.toolCallArgumentsDelta(textDelta:"{}")`
    /// before `.toolCall` to keep the event sequence uniform with worker 2's
    /// pattern.
    func test_streaming_emptyInputToolCall_emitsSyntheticEmptyDelta() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        let chunks: [Data] = [
            sseChunk(#"{"type":"message_start","message":{"id":"msg_2","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":12}}}"#),
            sseChunk(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_empty","name":"lookup_time","input":{}}}"#),
            // No input_json_delta — model produced a no-args call.
            sseChunk(#"{"type":"content_block_stop","index":0}"#),
            sseChunk(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#),
            sseChunk(#"{"type":"message_stop"}"#),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "what time is it?", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        // Must see: .toolCallStart → exactly one .toolCallArgumentsDelta(textDelta:"{}") → .toolCall.
        let deltas = events.compactMap { event -> (String, String)? in
            if case .toolCallArgumentsDelta(let id, let frag) = event { return (id, frag) }
            return nil
        }
        XCTAssertEqual(deltas.count, 1, "no-input tool_use must emit exactly one synthetic empty delta")
        XCTAssertEqual(deltas[0].0, "toolu_empty")
        XCTAssertEqual(deltas[0].1, "{}")

        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].id, "toolu_empty")
        XCTAssertEqual(toolCalls[0].arguments, "{}")
    }

    // MARK: - Non-streaming whole-message

    /// Non-streaming-style envelope: the upstream delivers the full
    /// message in a single payload with `content:[{type:"tool_use",...},
    /// {type:"tool_use",...}]`. Each tool_use block fans out into a
    /// uniform start + single delta + .toolCall triple so consumers don't
    /// have to special-case the path.
    func test_nonStreaming_wholeMessageToolUseBlocks_emitStartDeltaAndToolCallTriple() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        let chunks: [Data] = [
            sseChunk(#"{"type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_a","name":"get_weather","input":{"city":"Paris"}},{"type":"tool_use","id":"toolu_b","name":"lookup_time","input":{}}]}"#),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        let starts = events.compactMap { event -> (String, String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].0, "toolu_a")
        XCTAssertEqual(starts[0].1, "get_weather")
        XCTAssertEqual(starts[1].0, "toolu_b")
        XCTAssertEqual(starts[1].1, "lookup_time")

        // One delta per call carrying the full re-serialised input.
        var deltasById: [String: [String]] = [:]
        for event in events {
            if case .toolCallArgumentsDelta(let id, let frag) = event {
                deltasById[id, default: []].append(frag)
            }
        }
        XCTAssertEqual(deltasById["toolu_a"]?.count, 1)
        // input is {"city":"Paris"}; JSON re-serialisation is stable here
        // since there's only one key.
        XCTAssertEqual(deltasById["toolu_a"]?.first, #"{"city":"Paris"}"#)
        XCTAssertEqual(deltasById["toolu_b"]?.count, 1)
        XCTAssertEqual(deltasById["toolu_b"]?.first, "{}")

        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "toolu_a")
        XCTAssertEqual(toolCalls[1].id, "toolu_b")
    }

    // MARK: - Cancellation mid-stream

    /// Drop the consumer mid-deltas. The backend must NOT emit `.toolCall`
    /// for blocks that never received `content_block_stop`.
    func test_cancellation_midStream_doesNotEmitToolCall() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        // asyncSSE so chunks arrive with a real delay and the consumer
        // dropping out mid-stream actually interrupts the parser before
        // content_block_stop arrives for the in-flight tool_use block.
        let chunks: [Data] = [
            sseChunk(#"{"type":"message_start","message":{"id":"msg_3","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":8}}}"#),
            sseChunk(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_partial","name":"get_weather","input":{}}}"#),
            sseChunk(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#),
            sseChunk(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"Tokyo\"}"}}"#),
            sseChunk(#"{"type":"content_block_stop","index":0}"#),
            sseChunk(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}"#),
            sseChunk(#"{"type":"message_stop"}"#),
        ]
        MockURLProtocol.stub(url: url, response: .asyncSSE(chunks: chunks, chunkDelay: 0.020, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())

        // Consume one event then abort.
        var observed: [GenerationEvent] = []
        let task = Task<Void, Error> {
            for try await event in stream.events {
                observed.append(event)
                if observed.count >= 1 {
                    backend.stopGeneration()
                    break
                }
            }
        }
        do {
            try await task.value
        } catch is CancellationError {
            // Expected
        } catch {
            // Cancellation may surface as the stream finishing without error.
        }

        let toolCalls = observed.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertTrue(toolCalls.isEmpty, "no .toolCall must fire after mid-stream cancellation")
    }

    // MARK: - Tool-result history feedback

    func test_toolAwareHistory_shapesMessagesArray() throws {
        let (backend, _) = makeBackend()
        backend.setToolAwareHistory([
            ToolAwareHistoryEntry(role: "user", content: "what time?"),
            ToolAwareHistoryEntry(
                role: "assistant",
                content: "",
                toolCalls: [ToolCall(id: "toolu_t1", toolName: "now", arguments: "{}")]
            ),
            ToolAwareHistoryEntry(
                role: "tool",
                content: "2099-01-01T00:00:00Z",
                toolCallId: "toolu_t1"
            ),
        ])

        let request = try backend.buildRequest(
            prompt: "(ignored — tool-aware history takes precedence)",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)

        // Plain user turn collapses to string content.
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "what time?")

        // Assistant turn carries a structured content array with the
        // tool_use block.
        let assistant = messages[1]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        let assistantBlocks = try XCTUnwrap(assistant["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.count, 1)
        XCTAssertEqual(assistantBlocks[0]["type"] as? String, "tool_use")
        XCTAssertEqual(assistantBlocks[0]["id"] as? String, "toolu_t1")
        XCTAssertEqual(assistantBlocks[0]["name"] as? String, "now")
        // Anthropic requires `input` to be a JSON object, not a string.
        let input = try XCTUnwrap(assistantBlocks[0]["input"] as? [String: Any])
        XCTAssertTrue(input.isEmpty, "empty-arg tool call must round-trip as {}")

        // Tool-role response collapses to a user-role tool_result block.
        let toolEntry = messages[2]
        XCTAssertEqual(toolEntry["role"] as? String, "user", "Anthropic expresses tool results as user-role messages")
        let toolBlocks = try XCTUnwrap(toolEntry["content"] as? [[String: Any]])
        XCTAssertEqual(toolBlocks.count, 1)
        XCTAssertEqual(toolBlocks[0]["type"] as? String, "tool_result")
        XCTAssertEqual(toolBlocks[0]["tool_use_id"] as? String, "toolu_t1")
        XCTAssertEqual(toolBlocks[0]["content"] as? String, "2099-01-01T00:00:00Z")
    }

    /// Tool-call arguments that carry a non-empty JSON object must
    /// round-trip into `input` as a parsed object on Anthropic's wire —
    /// stringifying would violate the schema and 400.
    func test_toolAwareHistory_assistantToolUseInput_isJSONObjectNotString() throws {
        let (backend, _) = makeBackend()
        backend.setToolAwareHistory([
            ToolAwareHistoryEntry(
                role: "assistant",
                content: "",
                toolCalls: [ToolCall(id: "toolu_w1", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)]
            ),
        ])
        let request = try backend.buildRequest(prompt: "ignored", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        let input = try XCTUnwrap(blocks[0]["input"] as? [String: Any])
        XCTAssertEqual(input["city"] as? String, "Paris")
    }

    /// `setToolAwareHistory` is a one-shot payload. Consumed by
    /// `buildRequest` and cleared so a follow-up non-tool generation falls
    /// back to the plain string history. Without snapshot-and-clear,
    /// every later call would silently replay the prior tool turn — a
    /// footgun observed on Ollama before the fix and prevented here by
    /// the same pattern.
    func test_toolAwareHistory_isClearedAfterBuildRequest() throws {
        let (backend, _) = makeBackend()
        backend.setToolAwareHistory([
            ToolAwareHistoryEntry(role: "user", content: "what time?"),
            ToolAwareHistoryEntry(
                role: "assistant",
                content: "",
                toolCalls: [ToolCall(id: "toolu_t1", toolName: "now", arguments: "{}")]
            ),
            ToolAwareHistoryEntry(
                role: "tool",
                content: "2099-01-01T00:00:00Z",
                toolCallId: "toolu_t1"
            ),
        ])
        backend.setConversationHistory([
            (role: "user", content: "plain follow-up with no tools"),
        ])

        _ = try backend.buildRequest(prompt: "ignored", systemPrompt: nil, config: GenerationConfig())

        let second = try backend.buildRequest(prompt: "ignored", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(second.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "plain follow-up with no tools")
        // No structured tool_use blocks should leak in.
        XCTAssertNil(messages[0]["content"] as? [[String: Any]])
    }
}
#endif
