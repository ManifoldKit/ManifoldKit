#if CloudSaaS
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Tool-calling wire-contract tests for ``OpenAIResponsesBackend`` (the
/// OpenAI Responses `/v1/responses` API).
///
/// The Responses API uses the same `tools[]` envelope as Chat Completions
/// but a different streaming shape: function calls flow through
/// `response.output_item.added` (carrying `item.id`, `item.call_id`,
/// `item.name`) followed by N × `response.function_call_arguments.delta`
/// (keyed by `item_id`) and a terminal `response.completed`. The backend
/// maps `item_id → call_id` so the orchestrator only ever sees `call_id`
/// values on its `.toolCallStart` / `.toolCallArgumentsDelta` / `.toolCall`
/// events.
@MainActor
final class OpenAIResponsesBackendToolCallingTests: XCTestCase {

    // MARK: - Fixtures

    private var mockURL: URL!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        mockURL = URL(string: "https://openai-responses-tools-\(UUID().uuidString).test")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        if let url = mockURL {
            MockURLProtocol.unstub(url: url.appendingPathComponent("v1/responses"))
        }
        session = nil
        mockURL = nil
        super.tearDown()
    }

    private func makeBackend() -> (OpenAIResponsesBackend, responsesURL: URL) {
        let backend = OpenAIResponsesBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "sk-test", modelName: "gpt-5")
        return (backend, mockURL.appendingPathComponent("v1/responses"))
    }

    private func load(_ backend: OpenAIResponsesBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    private func sseEvent(_ name: String, data: String) -> Data {
        Data("event: \(name)\ndata: \(data)\n\n".utf8)
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

    func test_capabilities_supportsToolCalling_andStreamingArguments() {
        let caps = OpenAIResponsesBackend().capabilities
        XCTAssertTrue(caps.supportsToolCalling)
        XCTAssertTrue(caps.streamsToolCallArguments)
        XCTAssertTrue(caps.supportsParallelToolCalls)
    }

    // MARK: - Request body shape

    func test_requestBody_includesToolsArray() throws {
        let (backend, _) = makeBackend()
        var config = GenerationConfig()
        config.tools = [weatherTool(), timeTool()]

        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: config)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let function0 = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function0["name"] as? String, "get_weather")
    }

    func test_requestBody_toolChoice_mapping() throws {
        let cases: [ToolChoice] = [.auto, .none, .required, .tool(name: "pick_me")]
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
                XCTAssertNil(json["tool_choice"])
            case .none:
                XCTAssertEqual(json["tool_choice"] as? String, "none")
            case .required:
                XCTAssertEqual(json["tool_choice"] as? String, "required")
            case .tool(let name):
                let obj = try XCTUnwrap(json["tool_choice"] as? [String: Any])
                XCTAssertEqual(obj["type"] as? String, "function")
                let function = try XCTUnwrap(obj["function"] as? [String: Any])
                XCTAssertEqual(function["name"] as? String, name)
            }
        }
    }

    // MARK: - Streaming function-call events

    /// Two parallel function calls — proves item_id → call_id mapping and
    /// insertion-ordered `.toolCall` emission on `response.completed`.
    /// Conceptually saved as
    /// `Tests/ManifoldBackendsTests/Fixtures/openai_responses_two_tool_calls.txt`;
    /// inlined to keep tests self-contained.
    func test_streaming_twoFunctionCalls_emitStartDeltasAndToolCallInOrder() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        let chunks: [Data] = [
            sseEvent("response.output_item.added",
                     data: #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_abc","name":"get_weather","arguments":""}}"#),
            sseEvent("response.function_call_arguments.delta",
                     data: #"{"item_id":"item_1","output_index":0,"delta":"{\"city\":"}"#),
            sseEvent("response.output_item.added",
                     data: #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"item_2","call_id":"call_xyz","name":"lookup_time","arguments":""}}"#),
            sseEvent("response.function_call_arguments.delta",
                     data: #"{"item_id":"item_1","output_index":0,"delta":"\"Rome\"}"}"#),
            sseEvent("response.function_call_arguments.delta",
                     data: #"{"item_id":"item_2","output_index":1,"delta":"{}"}"#),
            sseEvent("response.function_call_arguments.done",
                     data: #"{"item_id":"item_1","arguments":"{\"city\":\"Rome\"}"}"#),
            sseEvent("response.function_call_arguments.done",
                     data: #"{"item_id":"item_2","arguments":"{}"}"#),
            sseEvent("response.completed",
                     data: #"{"response":{"usage":{"input_tokens":12,"output_tokens":8}}}"#),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        // .toolCallStart events must use call_id (NOT item_id).
        let starts = events.compactMap { event -> (String, String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].0, "call_abc")
        XCTAssertEqual(starts[0].1, "get_weather")
        XCTAssertEqual(starts[1].0, "call_xyz")
        XCTAssertEqual(starts[1].1, "lookup_time")

        // Argument deltas must concatenate per call_id and not bleed across.
        var deltasById: [String: String] = [:]
        for event in events {
            if case .toolCallArgumentsDelta(let id, let frag) = event {
                deltasById[id, default: ""] += frag
            }
        }
        XCTAssertEqual(deltasById["call_abc"], #"{"city":"Rome"}"#)
        XCTAssertEqual(deltasById["call_xyz"], "{}")

        // Final .toolCall events emitted on response.completed in insertion
        // order (call_abc first, then call_xyz).
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "call_abc")
        XCTAssertEqual(toolCalls[0].toolName, "get_weather")
        XCTAssertEqual(toolCalls[0].arguments, #"{"city":"Rome"}"#)
        XCTAssertEqual(toolCalls[1].id, "call_xyz")
        XCTAssertEqual(toolCalls[1].toolName, "lookup_time")
        XCTAssertEqual(toolCalls[1].arguments, "{}")
    }

    /// Stream end without a `response.completed` — the backend's stream-end
    /// fallback must finalise any buffered tool calls so the orchestrator
    /// can dispatch them. Mirrors the Chat-Completions path.
    func test_streaming_streamEndsWithoutCompleted_stillFinalisesToolCalls() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        let chunks: [Data] = [
            sseEvent("response.output_item.added",
                     data: #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_only","name":"get_weather","arguments":""}}"#),
            sseEvent("response.function_call_arguments.delta",
                     data: #"{"item_id":"item_1","output_index":0,"delta":"{\"city\":\"London\"}"}"#),
            sseEvent("response.function_call_arguments.done",
                     data: #"{"item_id":"item_1"}"#),
            // No response.completed — stream just ends.
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].id, "call_only")
        XCTAssertEqual(toolCalls[0].arguments, #"{"city":"London"}"#)
    }

    // MARK: - Cancellation mid-stream

    func test_cancellation_midStream_doesNotEmitToolCall() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        let chunks: [Data] = [
            sseEvent("response.output_item.added",
                     data: #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_partial","name":"get_weather","arguments":""}}"#),
            sseEvent("response.function_call_arguments.delta",
                     data: #"{"item_id":"item_1","delta":"{\"city\":"}"#),
            sseEvent("response.function_call_arguments.delta",
                     data: #"{"item_id":"item_1","delta":"\"Tokyo\"}"}"#),
            sseEvent("response.completed",
                     data: #"{"response":{"usage":{}}}"#),
        ]
        MockURLProtocol.stub(url: url, response: .asyncSSE(chunks: chunks, chunkDelay: 0.020, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
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
        do { try await task.value } catch { /* cancelled */ }

        let toolCalls = observed.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertTrue(toolCalls.isEmpty, "no .toolCall must fire after cancellation")
    }

    // MARK: - Tool-result history feedback (Responses API shape)

    func test_toolAwareHistory_emitsFunctionCallAndFunctionCallOutputItems() throws {
        let (backend, _) = makeBackend()
        backend.setToolAwareHistory([
            ToolAwareHistoryEntry(role: "user", content: "what time?"),
            ToolAwareHistoryEntry(
                role: "assistant",
                content: "",
                toolCalls: [ToolCall(id: "call_t1", toolName: "now", arguments: "{}")]
            ),
            ToolAwareHistoryEntry(
                role: "tool",
                content: "2099-01-01T00:00:00Z",
                toolCallId: "call_t1"
            ),
        ])

        let request = try backend.buildRequest(prompt: "(ignored)", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])

        // Expect:
        //   [0] user role message
        //   [1] function_call item with call_id=call_t1, name=now
        //   [2] function_call_output item with call_id=call_t1
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["role"] as? String, "user")

        let functionCall = input[1]
        XCTAssertEqual(functionCall["type"] as? String, "function_call")
        XCTAssertEqual(functionCall["call_id"] as? String, "call_t1")
        XCTAssertEqual(functionCall["name"] as? String, "now")
        XCTAssertEqual(functionCall["arguments"] as? String, "{}")

        let functionOutput = input[2]
        XCTAssertEqual(functionOutput["type"] as? String, "function_call_output")
        XCTAssertEqual(functionOutput["call_id"] as? String, "call_t1")
        XCTAssertEqual(functionOutput["output"] as? String, "2099-01-01T00:00:00Z")
    }

    func test_toolAwareHistory_isClearedAfterBuildRequest() throws {
        let (backend, _) = makeBackend()
        backend.setToolAwareHistory([
            ToolAwareHistoryEntry(role: "user", content: "what time?"),
            ToolAwareHistoryEntry(
                role: "assistant",
                content: "",
                toolCalls: [ToolCall(id: "call_t1", toolName: "now", arguments: "{}")]
            ),
            ToolAwareHistoryEntry(
                role: "tool",
                content: "2099-01-01T00:00:00Z",
                toolCallId: "call_t1"
            ),
        ])
        backend.setConversationHistory([(role: "user", content: "plain follow-up")])

        _ = try backend.buildRequest(prompt: "ignored", systemPrompt: nil, config: GenerationConfig())
        let second = try backend.buildRequest(prompt: "ignored", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(second.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[0]["content"] as? String, "plain follow-up")
        XCTAssertNil(input[0]["call_id"])
        XCTAssertNil(input[0]["type"])
    }
}
#endif
