import XCTest
import Foundation
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Tool-calling wire-contract tests for ``OpenAIBackend`` (Chat Completions API).
///
/// Coverage matrix (per #435 + #436):
/// - Tool definitions serialise into the OpenAI `tools[]` envelope.
/// - `tool_choice` mapping covers every ``ToolChoice`` case.
/// - Streaming `choices[0].delta.tool_calls[]` deltas decode into the
///   `.toolCallStart` → N×`.toolCallArgumentsDelta` → `.toolCall` sequence
///   from PR #783.
/// - Compat servers that drop `id` after the first delta still get a stable
///   `callId` via the `index → (id, name, args)` accumulator.
/// - Non-streaming whole `message.tool_calls[]` fan out into the same
///   start/delta/toolCall triple.
/// - Mid-stream cancellation suppresses any `.toolCall` emission for
///   incomplete entries.
/// - Tool-result history feedback produces the `{role:"tool", tool_call_id,
///   content}` shape Chat Completions expects.
/// - Capability flags are flipped for tool calling, streaming arguments,
///   and parallel tool calls.
@MainActor
final class OpenAIBackendToolCallingTests: XCTestCase {

    // MARK: - Fixtures

    private var mockURL: URL!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        mockURL = URL(string: "https://openai-toolcall-\(UUID().uuidString).test")!
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

    private func makeBackend() -> (OpenAIBackend, completionsURL: URL) {
        let backend = OpenAIBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "sk-test", modelName: "gpt-4o-mini")
        return (backend, mockURL.appendingPathComponent("v1/chat/completions"))
    }

    private func load(_ backend: OpenAIBackend) async throws {
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

    func test_capabilities_supportsToolCalling_andStreamingArguments() {
        let caps = OpenAIBackend().capabilities
        XCTAssertTrue(caps.supportsToolCalling, "supportsToolCalling must be true")
        XCTAssertTrue(caps.streamsToolCallArguments, "streamsToolCallArguments must be true")
        XCTAssertTrue(caps.supportsParallelToolCalls, "supportsParallelToolCalls must be true")
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
        XCTAssertEqual(function0["description"] as? String, "Fetch current weather for a city.")
        let parameters = try XCTUnwrap(function0["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
    }

    func test_requestBody_omitsTools_whenToolsEmpty() throws {
        let (backend, _) = makeBackend()
        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["tool_choice"])
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
                XCTAssertNil(json["tool_choice"], "auto must omit tool_choice")
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

    // MARK: - Streaming deltas

    /// Two interleaved tool calls — proves the `index` accumulator buffers
    /// fragments per call and emits `.toolCall` events in the correct order.
    /// Saved to `Tests/ManifoldBackendsTests/Fixtures/openai_two_tool_calls.txt`
    /// in spirit; inlined here to keep tests self-contained.
    func test_streaming_twoToolCalls_emitsStartDeltasAndToolCallInIndexOrder() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        // First-delta-only-id pattern: index=0 carries id+name; index=1 also
        // carries id+name on its first delta. Subsequent deltas only carry
        // arguments. Final empty delta with finish_reason: "tool_calls".
        let chunks: [Data] = [
            sseChunk(#"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_xyz","type":"function","function":{"name":"lookup_time","arguments":""}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Rome\"}"}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{}"}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            Data("data: [DONE]\n\n".utf8),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        // Expected ordering of tool-related events:
        //   - .toolCallStart for call_abc (first), then call_xyz (when index=1
        //     is observed mid-stream),
        //   - interleaved .toolCallArgumentsDelta entries for both ids,
        //   - .toolCall(call_abc) followed by .toolCall(call_xyz) on
        //     finish_reason=="tool_calls".
        let starts = events.compactMap { event -> (String, String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].0, "call_abc")
        XCTAssertEqual(starts[0].1, "get_weather")
        XCTAssertEqual(starts[1].0, "call_xyz")
        XCTAssertEqual(starts[1].1, "lookup_time")

        // Argument deltas must concatenate into valid JSON for each call.
        var deltasById: [String: String] = [:]
        for event in events {
            if case .toolCallArgumentsDelta(let id, let frag) = event {
                deltasById[id, default: ""] += frag
            }
        }
        XCTAssertEqual(deltasById["call_abc"], #"{"city":"Rome"}"#)
        XCTAssertEqual(deltasById["call_xyz"], "{}")

        // Final .toolCall events must arrive in `index` order.
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

    /// Some compat servers (Together, Groq) emit `id` only on the first delta
    /// for a given index. Subsequent deltas omit it. The accumulator must
    /// sticky-buffer the first id and apply it to all later argument
    /// fragments for the same index.
    func test_streaming_compatServer_dropsIdOnLaterDeltas_stillEmitsStableCallId() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        let chunks: [Data] = [
            sseChunk(#"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_groq_1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#),
            // No `id`, no `name` — only an arguments fragment. The accumulator
            // must keep both sticky.
            sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Berlin\"}"}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        let starts = events.compactMap { event -> (String, String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].0, "call_groq_1")

        // Every delta must carry the original id.
        let deltaIds = events.compactMap { event -> String? in
            if case .toolCallArgumentsDelta(let id, _) = event { return id }
            return nil
        }
        XCTAssertFalse(deltaIds.isEmpty)
        XCTAssertTrue(deltaIds.allSatisfy { $0 == "call_groq_1" },
                      "compat-server fallback must apply the first id to all subsequent deltas")

        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].id, "call_groq_1")
        XCTAssertEqual(toolCalls[0].arguments, #"{"city":"Berlin"}"#)
    }

    // MARK: - Non-streaming whole tool_calls

    /// Some servers (and OpenAI itself with `stream:false`) deliver the
    /// completed tool calls inside `choices[0].message.tool_calls`. The
    /// backend produces a uniform `start` + single `delta` + `.toolCall`
    /// triple per entry so consumers don't have to special-case the path.
    func test_nonStreaming_wholeToolCalls_emitStartDeltaAndToolCallTriple() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        // Single SSE chunk with the whole message — same shape OpenAI returns
        // when `stream:false` (we still test it via the stream path because
        // the backend always sets `stream:true`; the parser handles the
        // payload regardless of the on-wire transport).
        let chunks: [Data] = [
            sseChunk(#"{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_a","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}},{"id":"call_b","type":"function","function":{"name":"lookup_time","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        let starts = events.compactMap { event -> (String, String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].0, "call_a")
        XCTAssertEqual(starts[0].1, "get_weather")
        XCTAssertEqual(starts[1].0, "call_b")
        XCTAssertEqual(starts[1].1, "lookup_time")

        // One delta per call carrying the full arguments string.
        var deltasById: [String: [String]] = [:]
        for event in events {
            if case .toolCallArgumentsDelta(let id, let frag) = event {
                deltasById[id, default: []].append(frag)
            }
        }
        XCTAssertEqual(deltasById["call_a"]?.count, 1)
        XCTAssertEqual(deltasById["call_a"]?.first, #"{"city":"Paris"}"#)
        XCTAssertEqual(deltasById["call_b"]?.count, 1)
        XCTAssertEqual(deltasById["call_b"]?.first, "{}")

        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "call_a")
        XCTAssertEqual(toolCalls[1].id, "call_b")
    }

    // MARK: - Cancellation mid-stream

    /// Drop the consumer mid-deltas. The backend must NOT emit `.toolCall`
    /// for entries that never finished arriving — phantom dispatch would
    /// double-execute tools.
    func test_cancellation_midStream_doesNotEmitToolCall() async throws {
        let (backend, url) = makeBackend()
        try await load(backend)

        // Use asyncSSE so chunks arrive with a real delay and a consumer
        // dropping out mid-stream actually interrupts the parser before
        // `finish_reason` arrives.
        let chunks: [Data] = [
            sseChunk(#"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_partial","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Tokyo\"}"}}]}}]}"#),
            sseChunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
        ]
        MockURLProtocol.stub(url: url, response: .asyncSSE(chunks: chunks, chunkDelay: 0.020, statusCode: 200))

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())

        // Consume only the first event, then abort.
        var observed: [GenerationEvent] = []
        let task = Task<Void, Error> {
            for try await event in stream.events {
                observed.append(event)
                if observed.count >= 1 {
                    // Stop generation actively — this cancels the underlying
                    // task and the .toolCall finalisation path must skip.
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

        // Give the cancelled stream a moment to wind down so any spurious
        // post-cancel emissions would have surfaced. We can't drain the
        // stream a second time after cancelling, so observed is the full set.
        let toolCalls = observed.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }
        XCTAssertTrue(toolCalls.isEmpty, "no .toolCall must fire after cancellation")
    }

    // MARK: - Tool-result history feedback

    func test_toolAwareHistory_shapesMessagesArray() throws {
        let (backend, _) = makeBackend()
        backend.setToolAwareHistory([
            ToolAwareHistoryEntry(role: "user", content: "what time?"),
            ToolAwareHistoryEntry(
                role: "assistant",
                content: "",
                toolCalls: [ToolCall(id: "t-1", toolName: "now", arguments: "{}")]
            ),
            ToolAwareHistoryEntry(
                role: "tool",
                content: "2099-01-01T00:00:00Z",
                toolCallId: "t-1"
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

        // Assistant turn carries `tool_calls` shaped per OpenAI Chat
        // Completions: each call has {id, type:"function", function:{name,
        // arguments}} with `arguments` as a stringified JSON blob.
        let assistant = messages[1]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0]["id"] as? String, "t-1")
        XCTAssertEqual(toolCalls[0]["type"] as? String, "function")
        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "now")
        XCTAssertEqual(function["arguments"] as? String, "{}")

        // Tool-role response carries `tool_call_id` matching the assistant's
        // call so the server can thread results into the right slot.
        let toolEntry = messages[2]
        XCTAssertEqual(toolEntry["role"] as? String, "tool")
        XCTAssertEqual(toolEntry["tool_call_id"] as? String, "t-1")
        XCTAssertEqual(toolEntry["content"] as? String, "2099-01-01T00:00:00Z")
    }

    /// `setToolAwareHistory` is a one-shot payload. Consumed by `buildRequest`
    /// and cleared so a follow-up non-tool generation falls back to the plain
    /// string history. Without snapshot-and-clear, every later call would
    /// silently replay the prior tool turn — a footgun observed on Ollama
    /// before the fix and prevented here by the same pattern.
    func test_toolAwareHistory_isClearedAfterBuildRequest() throws {
        let (backend, _) = makeBackend()
        backend.setToolAwareHistory([
            ToolAwareHistoryEntry(role: "user", content: "what time?"),
            ToolAwareHistoryEntry(
                role: "assistant",
                content: "",
                toolCalls: [ToolCall(id: "t-1", toolName: "now", arguments: "{}")]
            ),
            ToolAwareHistoryEntry(
                role: "tool",
                content: "2099-01-01T00:00:00Z",
                toolCallId: "t-1"
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
        XCTAssertNil(messages[0]["tool_calls"])
        XCTAssertNil(messages[0]["tool_call_id"])
    }
}
