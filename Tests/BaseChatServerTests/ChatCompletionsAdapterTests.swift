@testable import BaseChatServerCore
import BaseChatInference
import BaseChatTestSupport
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
        XCTAssertTrue(config.jsonMode)
    }

    func testTokenEventsMapToContentDeltaChunks() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hel", "lo"]
        let request = ChatCompletionRequest(model: "m", messages: [ChatCompletionMessage(role: .user, content: "hi")], stream: true)

        let chunks = try await collect(try DefaultChatCompletionsAdapter().chunks(for: request, using: backend))

        XCTAssertEqual(chunks.compactMap { $0.choices.first?.delta.content }, ["Hel", "lo"])
        XCTAssertEqual(chunks.last?.choices.first?.finishReason, .stop)
        XCTAssertEqual(backend.lastPrompt, "user: hi")
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
        let backend = EventSequenceBackend(events: [.token("ok"), .usage(prompt: 3, completion: 2)])
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

    func testNonStreamResponseAssemblesContentReasoningToolCallsAndUsage() async throws {
        let backend = EventSequenceBackend(events: [
            .thinkingToken("think "),
            .thinkingToken("hard"),
            .token("Hello"),
            .token(" world"),
            .toolCallStart(callId: "call_1", name: "lookup"),
            .toolCallArgumentsDelta(callId: "call_1", textDelta: "{\"q\":"),
            .toolCallArgumentsDelta(callId: "call_1", textDelta: "\"swift\"}"),
            .usage(prompt: 5, completion: 7)
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

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
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
