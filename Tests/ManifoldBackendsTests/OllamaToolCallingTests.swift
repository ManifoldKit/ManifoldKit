#if Ollama
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Tool-calling wire contract tests for `OllamaBackend`.
///
/// Coverage:
/// - `tools` array shape in the request body (OpenAI envelope Ollama accepts)
/// - `tool_choice` mapping for every `ToolChoice` case
/// - parsing `message.tool_calls` from streaming NDJSON into
///   `.toolCall` generation events
/// - arguments encoded as a stringified JSON blob versus a pre-parsed object
/// - multiple tool calls in a single assistant message emitted in order
@MainActor
final class OllamaToolCallingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Use a fresh UUID hostname per test so stubs across suites never
    /// collide — per memory feedback the project intentionally avoids
    /// `MockURLProtocol.reset()` to keep suites isolated.
    private func makeBackend() -> (OllamaBackend, chatURL: URL) {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-tools-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.2")
        return (backend, baseURL.appendingPathComponent("api/chat"))
    }

    private func loadBackend(_ backend: OllamaBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    private func ndjsonLine(_ json: String) -> Data {
        Data("\(json)\n".utf8)
    }

    private func extractBody(from request: URLRequest?) throws -> Data {
        let unwrapped = try XCTUnwrap(request, "no captured request")
        if let body = unwrapped.httpBody { return body }
        if let stream = unwrapped.httpBodyStream {
            var data = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) }
            }
            stream.close()
            return data
        }
        XCTFail("Request has neither httpBody nor httpBodyStream")
        return Data()
    }

    private func sampleWeatherTool() -> ToolDefinition {
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

    private func sampleLookupTool() -> ToolDefinition {
        ToolDefinition(
            name: "lookup_time",
            description: "Return the current time.",
            parameters: .object(["type": .string("object")])
        )
    }

    private func drain(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    // MARK: - Capability flag

    func test_capabilities_supportsToolCalling_isTrue() {
        XCTAssertTrue(OllamaBackend().capabilities.supportsToolCalling)
    }

    // MARK: - Request body shape

    func test_requestBody_includesToolsArray() throws {
        let (backend, _) = makeBackend()
        var config = GenerationConfig()
        config.tools = [sampleWeatherTool(), sampleLookupTool()]

        let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: config)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // Sabotage check: removing the `tools` body injection in buildRequest
        // makes this XCTUnwrap fail.
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)

        // First entry shape — OpenAI envelope Ollama accepts.
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
        let scenarios: [(ToolChoice, expected: Any?)] = [
            (.auto, nil),
            (.none, "none" as Any?),
            (.required, "required" as Any?),
            (.tool(name: "pick_me"), nil),
        ]
        for (choice, expected) in scenarios {
            let (backend, _) = makeBackend()
            var config = GenerationConfig()
            config.tools = [sampleWeatherTool()]
            config.toolChoice = choice

            let request = try backend.buildRequest(prompt: "hi", systemPrompt: nil, config: config)
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

            switch choice {
            case .auto:
                XCTAssertNil(json["tool_choice"], "auto must omit tool_choice")
            case .none:
                XCTAssertEqual(json["tool_choice"] as? String, expected as? String)
            case .required:
                XCTAssertEqual(json["tool_choice"] as? String, expected as? String)
            case .tool(let name):
                let obj = try XCTUnwrap(json["tool_choice"] as? [String: Any])
                XCTAssertEqual(obj["type"] as? String, "function")
                let function = try XCTUnwrap(obj["function"] as? [String: Any])
                XCTAssertEqual(function["name"] as? String, name)
            }
        }
    }

    // MARK: - Streaming tool_calls

    func test_streaming_parsesToolCalls_fromAssistantMessage() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"id":"call-1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Rome\"}"}}]},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "Weather?", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        // Sabotage check: removing the `tool_calls` parse in `handleLine`
        // leaves `toolCalls` empty and the assertions below fail.
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c } else { return nil }
        }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.id, "call-1")
        XCTAssertEqual(toolCalls.first?.toolName, "get_weather")
        XCTAssertEqual(toolCalls.first?.arguments, #"{"city":"Rome"}"#)
    }

    func test_streaming_parsesToolCalls_whenArgumentsIsObject() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        // Some Ollama builds emit `arguments` as a pre-parsed object rather
        // than a JSON string. The parser must re-serialise so downstream
        // consumers always see a valid JSON string on `ToolCall.arguments`.
        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"id":"call-2","type":"function","function":{"name":"get_weather","arguments":{"city":"London"}}}]},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c } else { return nil }
        }
        XCTAssertEqual(toolCalls.count, 1)
        let parsed = try XCTUnwrap(toolCalls.first)
        XCTAssertEqual(parsed.toolName, "get_weather")

        // Accept either key order the JSONSerialization round-trip may
        // produce — what matters is that it's valid JSON that decodes to
        // the right structure.
        let data = try XCTUnwrap(parsed.arguments.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["city"] as? String, "London")
    }

    func test_streaming_parsesMultipleToolCalls_inSingleMessage() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"id":"c-1","type":"function","function":{"name":"fetch_a","arguments":"{}"}},{"id":"c-2","type":"function","function":{"name":"fetch_b","arguments":"{\"q\":\"x\"}"}}]},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)
        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c } else { return nil }
        }
        XCTAssertEqual(toolCalls.count, 2, "both tool calls must surface")
        XCTAssertEqual(toolCalls[0].id, "c-1")
        XCTAssertEqual(toolCalls[0].toolName, "fetch_a")
        XCTAssertEqual(toolCalls[1].id, "c-2")
        XCTAssertEqual(toolCalls[1].toolName, "fetch_b")
    }

    // MARK: - Tool-aware history

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

        // Assistant turn with tool_calls.
        let assistant = messages[1]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        let toolCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0]["id"] as? String, "t-1")

        // Tool-role response with tool_call_id.
        let toolEntry = messages[2]
        XCTAssertEqual(toolEntry["role"] as? String, "tool")
        XCTAssertEqual(toolEntry["tool_call_id"] as? String, "t-1")
        XCTAssertEqual(toolEntry["content"] as? String, "2099-01-01T00:00:00Z")
    }

    /// Regression: `setToolAwareHistory` is a one-shot payload. Once consumed
    /// by `buildRequest`, a second `buildRequest` with only `conversationHistory`
    /// set must fall back to the plain string history, not replay stale tool
    /// messages. Without the snapshot-and-clear at the read site, a tool-calling
    /// turn silently poisons every subsequent non-tool generation on the same
    /// backend instance.
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

        // First request consumes the tool-aware history.
        _ = try backend.buildRequest(
            prompt: "ignored", systemPrompt: nil, config: GenerationConfig()
        )

        // Second request must see only the plain string history. If the
        // one-shot isn't cleared, stale tool_calls / tool-role entries leak in.
        let second = try backend.buildRequest(
            prompt: "ignored again", systemPrompt: nil, config: GenerationConfig()
        )
        let body = try XCTUnwrap(second.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "second request should see only the plain history, not replayed tool messages")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "plain follow-up with no tools")
        XCTAssertNil(messages[0]["tool_calls"])
        XCTAssertNil(messages[0]["tool_call_id"])
    }
}
#endif
