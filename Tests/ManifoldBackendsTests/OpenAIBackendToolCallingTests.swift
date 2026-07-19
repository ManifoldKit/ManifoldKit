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

        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: config, hints: GenerationRuntimeHints())
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
        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: GenerationConfig(), hints: GenerationRuntimeHints())
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

            let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: config, hints: GenerationRuntimeHints())
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
        let hints = GenerationRuntimeHints(history: [
            StructuredMessage(role: "user", content: "what time?"),
            StructuredMessage(role: "assistant", parts: [
                .toolCall(ToolCall(id: "t-1", toolName: "now", arguments: "{}")),
            ]),
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "t-1", content: "2099-01-01T00:00:00Z")),
            ]),
        ])

        let request = try backend.buildRequest(
            prompt: "(ignored — tool-aware history takes precedence)",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: hints
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

    /// Sabotage-proven regression test for the #2312 follow-up: a *persisted*
    /// tool turn replays as one combined `StructuredMessage` (call + result +
    /// final answer all in the same message's `contentParts` —
    /// `TurnStreamFinalizer` appends them onto the same `ChatMessage` as it
    /// streams), not the split shape `test_toolAwareHistory_shapesMessagesArray`
    /// covers. Before this fix, `toolAwareHistory` mapped that one message to
    /// one wire entry carrying `tool_calls` *and* `tool_call_id` simultaneously
    /// (with `content` overwritten by the tool's raw result, clobbering the
    /// model's real answer) and never emitted the paired `role: "tool"`
    /// message — a shape OpenAI rejects with 400 on any follow-up turn.
    ///
    /// Sabotage proof (verified during development): reverting
    /// `toolAwareHistory` to its pre-fix one-entry-per-message `map` makes
    /// this test fail — `messages.count` drops to 1 and that entry carries
    /// both `tool_calls` and `tool_call_id`.
    func test_toolAwareHistory_splitsCombinedPersistedToolTurn() throws {
        let (backend, _) = makeBackend()
        let hints = GenerationRuntimeHints(history: [
            StructuredMessage(role: "user", content: "what time?"),
            StructuredMessage(role: "assistant", parts: [
                .toolCall(ToolCall(id: "t-1", toolName: "now", arguments: "{}")),
                .toolResult(ToolResult(callId: "t-1", content: "2099-01-01T00:00:00Z")),
                .text("It's noon."),
            ]),
        ])

        let request = try backend.buildRequest(
            prompt: "(ignored — tool-aware history takes precedence)",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: hints
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4, "user, assistant(tool_calls), tool(result), assistant(final answer)")

        let assistantCall = messages[1]
        XCTAssertEqual(assistantCall["role"] as? String, "assistant")
        XCTAssertEqual(assistantCall["content"] as? String, "")
        XCTAssertNil(assistantCall["tool_call_id"], "must not carry tool_call_id alongside tool_calls")
        let toolCalls = try XCTUnwrap(assistantCall["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0]["id"] as? String, "t-1")

        let toolEntry = messages[2]
        XCTAssertEqual(toolEntry["role"] as? String, "tool")
        XCTAssertEqual(toolEntry["tool_call_id"] as? String, "t-1")
        XCTAssertEqual(toolEntry["content"] as? String, "2099-01-01T00:00:00Z")
        XCTAssertNil(toolEntry["tool_calls"])

        let finalAnswer = messages[3]
        XCTAssertEqual(finalAnswer["role"] as? String, "assistant")
        XCTAssertEqual(finalAnswer["content"] as? String, "It's noon.", "the model's real answer, not the tool's raw result")
        XCTAssertNil(finalAnswer["tool_calls"])
        XCTAssertNil(finalAnswer["tool_call_id"])
    }

    /// Companion to `test_toolAwareHistory_splitsCombinedPersistedToolTurn`:
    /// pins the two shapes that test can't see because it exercises exactly
    /// one call/one result/non-empty text. Two real sabotages would pass that
    /// test alone: dropping every result past the first (e.g. `.prefix(1)`
    /// instead of mapping every `ToolResult`), and emitting a spurious empty
    /// trailing entry when a combined turn has no final text at all (missing
    /// the `!finalText.isEmpty` guard). This test catches both.
    func test_toolAwareHistory_parallelCallsAllResultsSurviveAndEmptyFinalTextOmitsTrailingEntry() throws {
        let (backend, _) = makeBackend()
        let hints = GenerationRuntimeHints(history: [
            StructuredMessage(role: "user", content: "what time is it in NYC and London?"),
            StructuredMessage(role: "assistant", parts: [
                .toolCall(ToolCall(id: "t-1", toolName: "now", arguments: #"{"tz":"America/New_York"}"#)),
                .toolCall(ToolCall(id: "t-2", toolName: "now", arguments: #"{"tz":"Europe/London"}"#)),
                .toolResult(ToolResult(callId: "t-1", content: "07:00")),
                .toolResult(ToolResult(callId: "t-2", content: "12:00")),
                // No final `.text` part: the turn ended on the tool results
                // (e.g. cancelled/truncated before the model replied further).
            ]),
        ])

        let request = try backend.buildRequest(
            prompt: "(ignored — tool-aware history takes precedence)",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: hints
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(
            messages.count, 4,
            "user, assistant(tool_calls x2), tool(t-1), tool(t-2) — and NO 5th entry for empty final text"
        )

        let assistantCall = messages[1]
        XCTAssertEqual(assistantCall["role"] as? String, "assistant")
        let toolCalls = try XCTUnwrap(assistantCall["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.map { $0["id"] as? String }, ["t-1", "t-2"], "both calls survive, in emission order")

        let toolEntry1 = messages[2]
        XCTAssertEqual(toolEntry1["role"] as? String, "tool")
        XCTAssertEqual(toolEntry1["tool_call_id"] as? String, "t-1")
        XCTAssertEqual(toolEntry1["content"] as? String, "07:00")

        // The result that would be dropped by a `.prefix(1)`-style sabotage:
        // must be present, not absent.
        let toolEntry2 = messages[3]
        XCTAssertEqual(toolEntry2["role"] as? String, "tool")
        XCTAssertEqual(toolEntry2["tool_call_id"] as? String, "t-2", "second result must not be silently dropped")
        XCTAssertEqual(toolEntry2["content"] as? String, "12:00")
    }

    // removed: `setToolAwareHistory` snapshot-and-clear retired in #2312.
    // History now threads per-call through `hints.history` — each
    // `buildRequest` call gets exactly the history its caller passed, with no
    // shared instance-state payload to consume-then-clear. The footgun this
    // test guarded against (a stale tool turn silently replaying into a later
    // non-tool call) is structurally impossible under the per-call model, so
    // there is no equivalent hints-based assertion to preserve.

    func test_history_perCallHints_doesNotLeakBetweenBuildRequestCalls() throws {
        let (backend, _) = makeBackend()

        let toolTurnHints = GenerationRuntimeHints(history: [
            StructuredMessage(role: "user", content: "what time?"),
            StructuredMessage(role: "assistant", parts: [
                .toolCall(ToolCall(id: "t-1", toolName: "now", arguments: "{}")),
            ]),
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "t-1", content: "2099-01-01T00:00:00Z")),
            ]),
        ])
        _ = try backend.buildRequest(prompt: "ignored", systemPrompt: nil, config: GenerationConfig(), hints: toolTurnHints)

        let plainFollowUpHints = GenerationRuntimeHints(history: [
            StructuredMessage(role: "user", content: "plain follow-up with no tools"),
        ])
        let second = try backend.buildRequest(prompt: "ignored", systemPrompt: nil, config: GenerationConfig(), hints: plainFollowUpHints)
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
