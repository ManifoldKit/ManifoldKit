#if Server
@testable import ManifoldServer
import ManifoldInference
import ManifoldTestSupport
import XCTest

final class ChatCompletionsAdapterTests: XCTestCase {
    func testDecodesOpenAIRequestShape() throws {
        let json = #"""
        {
          "model": "local-model",
          "messages": [
            {"role": "system", "content": "Be terse."},
            {"role": "user", "content": "Weather?"}
          ],
          "stream": true,
          "stream_options": {"include_usage": true},
          "temperature": 0.2,
          "top_p": 0.8,
          "max_tokens": 32,
          "response_format": {"type": "json_object"},
          "tools": [{
            "type": "function",
            "function": {
              "name": "get_weather",
              "description": "Get weather",
              "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}
            }
          }],
          "tool_choice": {"type": "function", "function": {"name": "get_weather"}}
        }
        """#.data(using: .utf8)!

        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: json)

        XCTAssertEqual(request.model, "local-model")
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertEqual(request.stream, true)
        XCTAssertEqual(request.streamOptions, ChatCompletionStreamOptions(includeUsage: true))
        XCTAssertEqual(request.temperature, 0.2)
        XCTAssertEqual(request.topP, 0.8)
        XCTAssertEqual(request.maxTokens, 32)
        XCTAssertEqual(request.responseFormat?.type, .jsonObject)
        XCTAssertEqual(request.tools?.first?.function.name, "get_weather")
        XCTAssertEqual(request.toolChoice, .function(name: "get_weather"))
    }

    func testMapsRequestToGenerationConfig() throws {
        let request = ChatCompletionRequest(
            model: "m",
            messages: [ChatCompletionMessage(role: .user, content: "hi")],
            temperature: 0.1,
            topP: 0.2,
            maxTokens: 12,
            maxCompletionTokens: 10,
            responseFormat: ChatCompletionResponseFormat(type: .jsonObject),
            tools: [ChatCompletionTool(function: ChatCompletionFunctionDefinition(
                name: "lookup",
                description: "Lookup a value",
                parameters: .object(["type": .string("object")])
            ))],
            toolChoice: .function(name: "lookup")
        )

        let config = try DefaultChatCompletionsAdapter().generationConfig(for: request)

        XCTAssertEqual(config.temperature, 0.1, accuracy: 0.0001)
        XCTAssertEqual(config.topP, 0.2, accuracy: 0.0001)
        XCTAssertEqual(config.maxOutputTokens, 10)
        XCTAssertEqual(config.tools, [ToolDefinition(name: "lookup", description: "Lookup a value", parameters: .object(["type": .string("object")]))])
        if case .tool(let name) = config.toolChoice {
            XCTAssertEqual(name, "lookup")
        } else {
            XCTFail("Expected named tool choice")
        }

        let hints = try DefaultChatCompletionsAdapter().generationHints(for: request)
        XCTAssertTrue(hints.jsonMode)
    }

    func testJsonSchemaResponseFormatStagesStructuredOutput() throws {
        // A json_schema response_format must reach GenerationRuntimeHints.structuredOutput
        // (the field the engine's structured-output router consults) — not just
        // flip jsonMode and drop the schema.
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "properties": .object([
                "answer": .object(["type": .string("string")])
            ]),
        ])
        let request = ChatCompletionRequest(
            model: "m",
            messages: [ChatCompletionMessage(role: .user, content: "hi")],
            responseFormat: ChatCompletionResponseFormat(
                type: .jsonSchema,
                jsonSchema: .init(name: "answer_shape", schema: schema)
            )
        )

        let hints = try DefaultChatCompletionsAdapter().generationHints(for: request)

        XCTAssertTrue(hints.jsonMode)
        guard case .jsonSchema(let staged) = hints.structuredOutput else {
            XCTFail("Expected structuredOutput to be staged as .jsonSchema; got \(String(describing: hints.structuredOutput))")
            return
        }
        XCTAssertTrue(staged.contains("\"answer\""), "staged schema should carry the client's schema content; got: \(staged)")
    }

    func testJsonObjectResponseFormatDoesNotStageStructuredOutput() throws {
        let request = ChatCompletionRequest(
            model: "m",
            messages: [ChatCompletionMessage(role: .user, content: "hi")],
            responseFormat: ChatCompletionResponseFormat(type: .jsonObject)
        )

        let hints = try DefaultChatCompletionsAdapter().generationHints(for: request)

        XCTAssertTrue(hints.jsonMode)
        XCTAssertNil(hints.structuredOutput)
    }

    func testTokenEventsMapToContentDeltaChunks() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hel", "lo"]
        let request = ChatCompletionRequest(model: "m", messages: [ChatCompletionMessage(role: .user, content: "hi")], stream: true)

        let chunks = try await collect(try DefaultChatCompletionsAdapter().chunks(for: request, using: backend))

        XCTAssertEqual(chunks.compactMap { $0.choices.first?.delta.content }, ["Hel", "lo"])
        XCTAssertEqual(chunks.last?.choices.first?.finishReason, .stop)
        // The prompt is now the raw latest-user-turn text (no `role:` prefix);
        // turn structure is carried via the installed conversation history.
        XCTAssertEqual(backend.lastPrompt, "hi")
    }

    func testToolCallDeltasUseStableIndexes() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = []
        backend.scriptedToolCallDeltasPerTurn = [[
            .start(callId: "call_b", name: "second"),
            .delta(callId: "call_b", textDelta: "{\"b\":"),
            .start(callId: "call_a", name: "first"),
            .delta(callId: "call_a", textDelta: "{\"a\":1}"),
            .delta(callId: "call_b", textDelta: "2}")
        ]]
        let request = ChatCompletionRequest(model: "m", messages: [ChatCompletionMessage(role: .user, content: "tools")], stream: true)

        let chunks = try await collect(try DefaultChatCompletionsAdapter().chunks(for: request, using: backend))
        let deltas = chunks.compactMap { $0.choices.first?.delta.toolCalls?.first }

        XCTAssertEqual(deltas.map(\.index), [0, 0, 1, 1, 0])
        XCTAssertEqual(deltas[0].id, "call_b")
        XCTAssertEqual(deltas[2].id, "call_a")
        XCTAssertEqual(chunks.last?.choices.first?.finishReason, .toolCalls)
    }

    func testUsageEventMapsToFinalUsageChunkWhenRequested() async throws {
        let backend = EventSequenceBackend(events: [.token("ok"), .usage(TokenUsage(promptTokens: 3, completionTokens: 2))])
        let request = ChatCompletionRequest(
            model: "m",
            messages: [ChatCompletionMessage(role: .user, content: "hi")],
            stream: true,
            streamOptions: ChatCompletionStreamOptions(includeUsage: true)
        )

        let chunks = try await collect(try DefaultChatCompletionsAdapter().chunks(for: request, using: backend))

        XCTAssertEqual(chunks.last?.choices, [])
        XCTAssertEqual(chunks.last?.usage, ChatCompletionUsage(promptTokens: 3, completionTokens: 2))
    }

    func testCancellingStreamingChunksStopsBackendGeneration() async throws {
        let gate = TokenEmissionGate()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["one", "two"]
        backend.tokenEmissionGate = gate
        let request = ChatCompletionRequest(
            model: "m",
            messages: [ChatCompletionMessage(role: .user, content: "hi")],
            stream: true
        )

        let stream = try DefaultChatCompletionsAdapter().chunks(for: request, using: backend)
        let firstToken = expectation(description: "first token streamed")
        let consumer = Task {
            for try await chunk in stream {
                if chunk.choices.first?.delta.content == "one" {
                    firstToken.fulfill()
                }
            }
        }

        await gate.advance()
        await fulfillment(of: [firstToken], timeout: 1)
        consumer.cancel()
        await waitUntil {
            backend.stopCallCount == 1 && backend.isGenerating == false
        }
        await gate.release()
        _ = await consumer.result

        XCTAssertEqual(backend.generateCallCount, 1)
    }

    func testUsageEventDoesNotMapToStreamingChunkByDefaultOrWhenFalse() async throws {
        let requests = [
            ChatCompletionRequest(
                model: "m",
                messages: [ChatCompletionMessage(role: .user, content: "hi")],
                stream: true
            ),
            ChatCompletionRequest(
                model: "m",
                messages: [ChatCompletionMessage(role: .user, content: "hi")],
                stream: true,
                streamOptions: ChatCompletionStreamOptions(includeUsage: false)
            )
        ]

        for request in requests {
            let backend = EventSequenceBackend(events: [.token("ok"), .usage(TokenUsage(promptTokens: 3, completionTokens: 2))])
            let chunks = try await collect(try DefaultChatCompletionsAdapter().chunks(for: request, using: backend))

            XCTAssertTrue(chunks.allSatisfy { $0.usage == nil })
            XCTAssertEqual(chunks.last?.choices.first?.finishReason, .stop)
        }
    }

    func testDefaultStreamingAdapterEmitsUsageOnlyWhenRequested() async throws {
        let response = ChatCompletionResponse(
            id: "chatcmpl-response-only",
            created: 42,
            model: "m",
            choices: [ChatCompletionChoice(index: 0, message: ChatCompletionMessage(role: .assistant, content: "ok"), finishReason: .stop)],
            usage: ChatCompletionUsage(promptTokens: 4, completionTokens: 2)
        )
        let adapter = ResponseOnlyUsageAdapter(response: response)
        let backend = EventSequenceBackend(events: [])
        let defaultRequest = ChatCompletionRequest(
            model: "m",
            messages: [ChatCompletionMessage(role: .user, content: "hi")],
            stream: true
        )
        let usageRequest = ChatCompletionRequest(
            model: "m",
            messages: [ChatCompletionMessage(role: .user, content: "hi")],
            stream: true,
            streamOptions: ChatCompletionStreamOptions(includeUsage: true)
        )

        let defaultChunks = try await collect(try adapter.chunks(for: defaultRequest, using: backend))
        let usageChunks = try await collect(try adapter.chunks(for: usageRequest, using: backend))

        XCTAssertEqual(defaultChunks.count, 1)
        XCTAssertNil(defaultChunks.last?.usage)
        XCTAssertEqual(usageChunks.last?.choices, [])
        XCTAssertEqual(usageChunks.last?.usage, ChatCompletionUsage(promptTokens: 4, completionTokens: 2))
    }

    func testNonStreamResponseAssemblesContentReasoningToolCallsAndUsage() async throws {
        let backend = EventSequenceBackend(events: [
            .thinkingToken("think "),
            .thinkingToken("hard"),
            .token("Hello"),
            .token(" world"),
            .toolCallStart(callId: "call_1", name: "lookup"),
            .toolCallArgumentsDelta(callId: "call_1", textDelta: "{\"q\":"),
            .toolCallArgumentsDelta(callId: "call_1", textDelta: "\"swift\"}"),
            .usage(TokenUsage(promptTokens: 5, completionTokens: 7))
        ])
        let request = ChatCompletionRequest(model: "m", messages: [ChatCompletionMessage(role: .user, content: "hi")])

        let response = try await DefaultChatCompletionsAdapter().response(for: request, using: backend)

        XCTAssertEqual(response.choices.first?.message.content, "Hello world")
        XCTAssertEqual(response.choices.first?.message.reasoningContent, "think hard")
        XCTAssertEqual(response.choices.first?.message.toolCalls, [
            ChatCompletionMessageToolCall(
                id: "call_1",
                function: ChatCompletionFunctionCall(name: "lookup", arguments: "{\"q\":\"swift\"}")
            )
        ])
        XCTAssertEqual(response.choices.first?.finishReason, .toolCalls)
        XCTAssertEqual(response.usage, ChatCompletionUsage(promptTokens: 5, completionTokens: 7))
    }

    func testDecodesToolChoiceStringVariants() throws {
        let autoJSON = #"{"model":"m","messages":[],"tool_choice":"auto"}"#
        let noneJSON = #"{"model":"m","messages":[],"tool_choice":"none"}"#
        let requiredJSON = #"{"model":"m","messages":[],"tool_choice":"required"}"#
        let decoder = JSONDecoder()

        let autoRequest = try decoder.decode(ChatCompletionRequest.self, from: Data(autoJSON.utf8))
        let noneRequest = try decoder.decode(ChatCompletionRequest.self, from: Data(noneJSON.utf8))
        let requiredRequest = try decoder.decode(ChatCompletionRequest.self, from: Data(requiredJSON.utf8))

        XCTAssertEqual(autoRequest.toolChoice, .some(.auto))
        XCTAssertEqual(noneRequest.toolChoice, .some(.none))
        XCTAssertEqual(requiredRequest.toolChoice, .some(.required))
    }

    func testMultiTurnConversationPreservesTurnStructure() async throws {
        let request = ChatCompletionRequest(
            model: "m",
            messages: [
                ChatCompletionMessage(role: .system, content: "You are helpful."),
                ChatCompletionMessage(role: .user, content: "Hello"),
                ChatCompletionMessage(role: .assistant, content: "Hi there!"),
                ChatCompletionMessage(
                    role: .tool,
                    content: "42",
                    toolCallID: "call_123"
                ),
                ChatCompletionMessage(role: .user, content: "Thanks")
            ]
        )

        let adapter = DefaultChatCompletionsAdapter()
        let backend = CapturingBackend()
        _ = try await adapter.response(for: request, using: backend)

        // System turns are extracted into the dedicated system-prompt channel,
        // not folded into the conversation.
        XCTAssertEqual(backend.capturedSystemPrompt, "You are helpful.")

        // The structured multi-turn history is threaded onto the backend with
        // per-message roles preserved — NOT collapsed into one `role: text`
        // string. The system turn is excluded; the other four turns keep order.
        let structured = try XCTUnwrap(backend.capturedStructuredHistory)
        XCTAssertEqual(structured.map(\.role), ["user", "assistant", "tool", "user"])
        XCTAssertEqual(structured.first?.textContent, "Hello")
        XCTAssertEqual(structured.last?.textContent, "Thanks")

        // The tool turn retains its call id as a structured tool-result part.
        let toolTurn = try XCTUnwrap(structured.first { $0.role == "tool" })
        let hasToolResult = toolTurn.parts.contains { part in
            if case .toolResult(let result) = part {
                return result.callId == "call_123" && result.content == "42"
            }
            return false
        }
        XCTAssertTrue(hasToolResult, "Tool turn should carry a structured tool-result part with the call id")

        // The flattened receiver shape also preserves per-turn roles.
        let flattened = try XCTUnwrap(backend.capturedHistory)
        XCTAssertEqual(flattened.map(\.role), ["user", "assistant", "tool", "user"])

        // The tool-aware shape threads the call id through for `role: tool`.
        let toolAware = try XCTUnwrap(backend.capturedToolAwareHistory)
        XCTAssertEqual(toolAware.first { $0.role == "tool" }?.toolCallId, "call_123")

        // The prompt argument carries the latest user turn (the fallback shape
        // for backends with no installed history) — never the role-prefixed dump.
        XCTAssertEqual(backend.capturedPrompt, "Thanks")
    }

    func testAssistantToolCallTurnThreadsThroughStructuredHistory() async throws {
        let request = ChatCompletionRequest(
            model: "m",
            messages: [
                ChatCompletionMessage(role: .user, content: "What's the weather?"),
                ChatCompletionMessage(
                    role: .assistant,
                    content: nil,
                    toolCalls: [ChatCompletionMessageToolCall(
                        id: "call_w",
                        function: ChatCompletionFunctionCall(name: "get_weather", arguments: "{\"city\":\"SF\"}")
                    )]
                ),
                ChatCompletionMessage(role: .tool, content: "sunny", toolCallID: "call_w"),
                ChatCompletionMessage(role: .user, content: "Thanks!")
            ]
        )

        let backend = CapturingBackend()
        _ = try await DefaultChatCompletionsAdapter().response(for: request, using: backend)

        let structured = try XCTUnwrap(backend.capturedStructuredHistory)
        let assistantTurn = try XCTUnwrap(structured.first { $0.role == "assistant" })
        let hasToolCall = assistantTurn.parts.contains { part in
            if case .toolCall(let call) = part {
                return call.id == "call_w" && call.toolName == "get_weather"
            }
            return false
        }
        XCTAssertTrue(hasToolCall, "Assistant tool-call turn should carry a structured tool-call part")

        let toolAware = try XCTUnwrap(backend.capturedToolAwareHistory)
        let assistantEntry = try XCTUnwrap(toolAware.first { $0.role == "assistant" })
        XCTAssertEqual(assistantEntry.toolCalls?.first?.toolName, "get_weather")
    }

    func testErrorEnvelopeRoundTrips() throws {
        let envelope = ChatCompletionErrorEnvelope(
            error: ChatCompletionError(message: "bad request", type: "invalid_request_error", param: "messages", code: "invalid")
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ChatCompletionErrorEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(ChatCompletionErrorEnvelope.from(ServerError.invalidConfiguration("nope")).error.message, "nope")
    }

    private func collect(_ stream: AsyncThrowingStream<ChatCompletionChunk, Error>) async throws -> [ChatCompletionChunk] {
        var chunks: [ChatCompletionChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private final class EventSequenceBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded = true
    var isGenerating = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: true,
        supportsStructuredOutput: true,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )
    let events: [GenerationEvent]

    init(events: [GenerationEvent]) {
        self.events = events
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws { isModelLoaded = true }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        let events = events
        return GenerationStream(AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        })
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}

private struct ResponseOnlyUsageAdapter: ChatCompletionsAdapter {
    let response: ChatCompletionResponse

    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        response
    }
}

private final class CapturingBackend: InferenceBackend, ConversationHistoryReceiver, StructuredHistoryReceiver, ToolCallingHistoryReceiver, @unchecked Sendable {
    var isModelLoaded = true
    var isGenerating = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: false,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )
    private(set) var capturedPrompt: String?
    private(set) var capturedSystemPrompt: String?
    private(set) var capturedHistory: [(role: String, content: String)]?
    private(set) var capturedStructuredHistory: [StructuredMessage]?
    private(set) var capturedToolAwareHistory: [ToolAwareHistoryEntry]?

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws { isModelLoaded = true }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        capturedPrompt = prompt
        capturedSystemPrompt = systemPrompt
        return GenerationStream(AsyncThrowingStream { continuation in
            continuation.finish()
        })
    }

    func setConversationHistory(_ messages: [(role: String, content: String)]) {
        capturedHistory = messages
    }

    func setStructuredHistory(_ messages: [StructuredMessage]) {
        capturedStructuredHistory = messages
    }

    func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        capturedToolAwareHistory = messages
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}

#endif
