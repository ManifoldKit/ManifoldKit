#if Server
import ManifoldInference
import Foundation

internal enum ChatCompletionRole: String, Codable, Equatable, Sendable {
    case system
    case developer
    case user
    case assistant
    case tool
}

internal struct ChatCompletionMessage: Codable, Equatable, Sendable {
    internal var role: ChatCompletionRole
    internal var content: String?
    internal var reasoningContent: String?
    internal var name: String?
    internal var toolCallID: String?
    internal var toolCalls: [ChatCompletionMessageToolCall]?

    internal init(
        role: ChatCompletionRole,
        content: String? = nil,
        reasoningContent: String? = nil,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [ChatCompletionMessageToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    internal init(role: String, content: String) {
        self.init(role: ChatCompletionRole(rawValue: role) ?? .user, content: content)
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, name
        case reasoningContent = "reasoning_content"
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

internal extension ChatCompletionMessage {
    /// Projects this wire message into the engine's structured-history shape,
    /// preserving the role plus any tool call / tool result parts so a
    /// `StructuredHistoryReceiver` backend can replay the full turn structure.
    var structuredMessage: StructuredMessage {
        var parts: [MessagePart] = []
        // A tool turn's content is the tool *result* payload — it belongs in the
        // `.toolResult` part below, not as a sibling `.text` part. Emitting both
        // would represent the same content twice and double-encode on a
        // structured-only backend, so the text part is skipped for `.tool`.
        if let content, !content.isEmpty, role != .tool {
            parts.append(.text(content))
        }
        if let toolCalls {
            for call in toolCalls {
                parts.append(.toolCall(ToolCall(
                    id: call.id,
                    toolName: call.function.name ?? "",
                    arguments: call.function.arguments ?? ""
                )))
            }
        }
        if role == .tool, let toolCallID {
            parts.append(.toolResult(ToolResult(callId: toolCallID, content: content ?? "")))
        }
        return StructuredMessage(role: role.rawValue, parts: parts)
    }

    /// Projects this wire message into the tool-aware history shape consumed by
    /// `ToolCallingHistoryReceiver` backends (Ollama's `/api/chat`).
    var toolAwareHistoryEntry: ToolAwareHistoryEntry {
        ToolAwareHistoryEntry(
            role: role.rawValue,
            content: content ?? "",
            toolCalls: toolCalls?.map { call in
                ToolCall(
                    id: call.id,
                    toolName: call.function.name ?? "",
                    arguments: call.function.arguments ?? ""
                )
            },
            toolCallId: role == .tool ? toolCallID : nil
        )
    }
}

internal struct ChatCompletionRequest: Codable, Equatable, Sendable {
    internal var model: String
    internal var messages: [ChatCompletionMessage]
    internal var stream: Bool?
    internal var streamOptions: ChatCompletionStreamOptions?
    internal var temperature: Double?
    internal var topP: Double?
    internal var maxTokens: Int?
    internal var maxCompletionTokens: Int?
    internal var responseFormat: ChatCompletionResponseFormat?
    internal var tools: [ChatCompletionTool]?
    internal var toolChoice: ChatCompletionToolChoice?

    internal init(
        model: String,
        messages: [ChatCompletionMessage],
        stream: Bool = false,
        streamOptions: ChatCompletionStreamOptions? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        maxCompletionTokens: Int? = nil,
        responseFormat: ChatCompletionResponseFormat? = nil,
        tools: [ChatCompletionTool]? = nil,
        toolChoice: ChatCompletionToolChoice? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.streamOptions = streamOptions
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.responseFormat = responseFormat
        self.tools = tools
        self.toolChoice = toolChoice
    }

    internal var includesStreamUsage: Bool { streamOptions?.includeUsage == true }

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools
        case streamOptions = "stream_options"
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case responseFormat = "response_format"
        case toolChoice = "tool_choice"
    }
}

internal struct ChatCompletionStreamOptions: Codable, Equatable, Sendable {
    internal var includeUsage: Bool?

    internal init(includeUsage: Bool? = nil) {
        self.includeUsage = includeUsage
    }

    private enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

internal struct ChatCompletionResponseFormat: Codable, Equatable, Sendable {
    internal enum FormatType: String, Codable, Equatable, Sendable {
        case text
        case jsonObject = "json_object"
        case jsonSchema = "json_schema"
    }

    internal struct JSONSchema: Codable, Equatable, Sendable {
        internal var name: String
        internal var description: String?
        internal var schema: JSONSchemaValue?
        internal var strict: Bool?

        internal init(name: String, description: String? = nil, schema: JSONSchemaValue? = nil, strict: Bool? = nil) {
            self.name = name
            self.description = description
            self.schema = schema
            self.strict = strict
        }
    }

    internal var type: FormatType
    internal var jsonSchema: JSONSchema?

    internal init(type: FormatType, jsonSchema: JSONSchema? = nil) {
        self.type = type
        self.jsonSchema = jsonSchema
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

internal struct ChatCompletionTool: Codable, Equatable, Sendable {
    internal var type: String
    internal var function: ChatCompletionFunctionDefinition

    internal init(type: String = "function", function: ChatCompletionFunctionDefinition) {
        self.type = type
        self.function = function
    }

    internal func toolDefinition() -> ToolDefinition? {
        guard type == "function" else { return nil }
        return ToolDefinition(
            name: function.name,
            description: function.description ?? "",
            parameters: function.parameters ?? .object([:])
        )
    }
}

internal struct ChatCompletionFunctionDefinition: Codable, Equatable, Sendable {
    internal var name: String
    internal var description: String?
    internal var parameters: JSONSchemaValue?
    internal var strict: Bool?

    internal init(name: String, description: String? = nil, parameters: JSONSchemaValue? = nil, strict: Bool? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}

internal enum ChatCompletionToolChoice: Codable, Equatable, Sendable {
    case auto
    case none
    case required
    case function(name: String)

    internal init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            switch string {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown tool_choice '\(string)'")
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "function" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Only function tool_choice objects are supported")
        }
        let function = try container.decode(FunctionChoice.self, forKey: .function)
        self = .function(name: function.name)
    }

    internal func encode(to encoder: Encoder) throws {
        switch self {
        case .auto:
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        case .none:
            var container = encoder.singleValueContainer()
            try container.encode("none")
        case .required:
            var container = encoder.singleValueContainer()
            try container.encode("required")
        case .function(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            try container.encode(FunctionChoice(name: name), forKey: .function)
        }
    }

    internal func generationToolChoice() -> ManifoldInference.ToolChoice {
        switch self {
        case .auto: .auto
        case .none: .none
        case .required: .required
        case .function(let name): .tool(name: name)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, function }
    private struct FunctionChoice: Codable, Equatable, Sendable { var name: String }
}

internal struct ChatCompletionMessageToolCall: Codable, Equatable, Sendable {
    internal var id: String
    internal var type: String
    internal var function: ChatCompletionFunctionCall

    internal init(id: String, type: String = "function", function: ChatCompletionFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

internal struct ChatCompletionFunctionCall: Codable, Equatable, Sendable {
    internal var name: String?
    internal var arguments: String?

    internal init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

internal struct ChatCompletionResponse: Codable, Equatable, Sendable {
    internal var id: String
    internal var object: String
    internal var created: Int
    internal var model: String
    internal var choices: [ChatCompletionChoice]
    internal var usage: ChatCompletionUsage?

    internal init(
        id: String = "chatcmpl-placeholder",
        object: String = "chat.completion",
        created: Int = 0,
        model: String,
        choices: [ChatCompletionChoice] = [],
        usage: ChatCompletionUsage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }

    internal init(id: String = "chatcmpl-placeholder", model: String, content: String = "") {
        self.init(
            id: id,
            model: model,
            choices: [ChatCompletionChoice(index: 0, message: ChatCompletionMessage(role: .assistant, content: content), finishReason: .stop)]
        )
    }

    internal var content: String {
        choices.compactMap(\.message.content).joined()
    }
}

internal extension ChatCompletionResponse {
    var contentText: String {
        choices.first?.message.content ?? ""
    }
}

internal struct ChatCompletionChoice: Codable, Equatable, Sendable {
    internal var index: Int
    internal var message: ChatCompletionMessage
    internal var finishReason: ChatCompletionFinishReason?

    internal init(index: Int, message: ChatCompletionMessage, finishReason: ChatCompletionFinishReason? = nil) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
    }

    private enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
    }
}

internal struct ChatCompletionChunk: Codable, Equatable, Sendable {
    internal var id: String
    internal var object: String
    internal var created: Int
    internal var model: String
    internal var choices: [ChatCompletionChunkChoice]
    internal var usage: ChatCompletionUsage?

    internal init(
        id: String,
        object: String = "chat.completion.chunk",
        created: Int,
        model: String,
        choices: [ChatCompletionChunkChoice],
        usage: ChatCompletionUsage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

internal struct ChatCompletionChunkChoice: Codable, Equatable, Sendable {
    internal var index: Int
    internal var delta: ChatCompletionDelta
    internal var finishReason: ChatCompletionFinishReason?

    internal init(index: Int, delta: ChatCompletionDelta, finishReason: ChatCompletionFinishReason? = nil) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
    }

    private enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }
}

internal struct ChatCompletionDelta: Codable, Equatable, Sendable {
    internal var role: ChatCompletionRole?
    internal var content: String?
    internal var reasoningContent: String?
    internal var toolCalls: [ChatCompletionDeltaToolCall]?

    internal init(
        role: ChatCompletionRole? = nil,
        content: String? = nil,
        reasoningContent: String? = nil,
        toolCalls: [ChatCompletionDeltaToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

internal struct ChatCompletionDeltaToolCall: Codable, Equatable, Sendable {
    internal var index: Int
    internal var id: String?
    internal var type: String?
    internal var function: ChatCompletionFunctionCall?

    internal init(index: Int, id: String? = nil, type: String? = nil, function: ChatCompletionFunctionCall? = nil) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

internal enum ChatCompletionFinishReason: String, Codable, Equatable, Sendable {
    case stop
    case length
    case toolCalls = "tool_calls"
    case contentFilter = "content_filter"
    case error
}

internal struct ChatCompletionUsage: Codable, Equatable, Sendable {
    internal var promptTokens: Int
    internal var completionTokens: Int
    internal var totalTokens: Int

    internal init(promptTokens: Int, completionTokens: Int, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens ?? promptTokens + completionTokens
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

internal struct ChatCompletionErrorEnvelope: Codable, Equatable, Sendable {
    internal var error: ChatCompletionError

    internal init(error: ChatCompletionError) {
        self.error = error
    }

    internal init(message: String, type: String = "server_error", param: String? = nil, code: String? = nil) {
        self.error = ChatCompletionError(message: message, type: type, param: param, code: code)
    }

    internal static func from(_ error: Error) -> ChatCompletionErrorEnvelope {
        if let serverError = error as? ServerError {
            if case .invalidRequest(let message, let param, let code) = serverError {
                return ChatCompletionErrorEnvelope(
                    message: message,
                    type: "invalid_request_error",
                    param: param,
                    code: code
                )
            }
            return ChatCompletionErrorEnvelope(message: serverError.description, type: "server_error")
        }
        // A decode failure that bypassed the request-decode normalization is
        // still a client error — map it to invalid_request_error rather than a
        // 500 that leaks raw Swift type detail.
        if error is DecodingError {
            return ChatCompletionErrorEnvelope(
                message: "Could not parse request body. Ensure it is valid JSON matching the expected schema.",
                type: "invalid_request_error",
                code: "invalid_body"
            )
        }
        return ChatCompletionErrorEnvelope(message: String(describing: error), type: "server_error")
    }
}

internal struct ChatCompletionError: Codable, Equatable, Sendable {
    internal var message: String
    internal var type: String
    internal var param: String?
    internal var code: String?

    internal init(message: String, type: String, param: String? = nil, code: String? = nil) {
        self.message = message
        self.type = type
        self.param = param
        self.code = code
    }
}

internal protocol ChatCompletionsAdapter: Sendable {
    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig

    /// Per-request runtime hints (JSON mode, structured output) derived from the
    /// request's `response_format`. Split out of ``GenerationConfig`` in #2152.
    func generationHints(for request: ChatCompletionRequest) throws -> GenerationRuntimeHints

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error>
}

extension ChatCompletionsAdapter {
    internal func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        try DefaultChatCompletionsAdapter().generationConfig(for: request)
    }

    internal func generationHints(for request: ChatCompletionRequest) throws -> GenerationRuntimeHints {
        try DefaultChatCompletionsAdapter().generationHints(for: request)
    }

    internal func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.response(for: request, using: backend)
                    let chunk = ChatCompletionChunk(
                        id: response.id,
                        created: response.created,
                        model: response.model,
                        choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(content: response.contentText), finishReason: .stop)],
                        usage: nil
                    )
                    continuation.yield(chunk)
                    if request.includesStreamUsage, let usage = response.usage {
                        continuation.yield(ChatCompletionChunk(
                            id: response.id,
                            created: response.created,
                            model: response.model,
                            choices: [],
                            usage: usage
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                task.cancel()
                if case .cancelled = termination {
                    backend.stopGeneration()
                }
            }
        }
    }
}

internal struct DefaultChatCompletionsAdapter: ChatCompletionsAdapter {
    internal init() {}

    internal func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        let tools = request.tools?.compactMap { $0.toolDefinition() } ?? []
        let toolChoice = request.toolChoice?.generationToolChoice() ?? .auto
        return GenerationConfig(
            temperature: Float(request.temperature ?? 0.7),
            topP: Float(request.topP ?? 0.9),
            maxOutputTokens: request.maxCompletionTokens ?? request.maxTokens,
            tools: tools,
            toolChoice: toolChoice
        )
    }

    internal func generationHints(for request: ChatCompletionRequest) throws -> GenerationRuntimeHints {
        GenerationRuntimeHints(
            jsonMode: request.responseFormat?.type == .jsonObject || request.responseFormat?.type == .jsonSchema,
            structuredOutput: try structuredOutputStrategy(for: request.responseFormat)
        )
    }

    /// Converts an OpenAI-shaped `response_format.json_schema.schema` into the
    /// `StructuredOutputStrategy` the generation engine actually consults.
    ///
    /// `ServerApp.validateRequestCapabilities` already requires
    /// `capabilities.supportsStructuredOutput` for `response_format.type ==
    /// .jsonSchema`, implying the schema will constrain generation. Without
    /// staging it here, `GenerationQueue.respond` (which reads
    /// `GenerationConfig.structuredOutput` to pick GBNF / native-JSON-schema /
    /// prompt-fallback per backend capability) never sees the schema and the
    /// request is generated unconstrained.
    private func structuredOutputStrategy(
        for responseFormat: ChatCompletionResponseFormat?
    ) throws -> StructuredOutputStrategy? {
        guard responseFormat?.type == .jsonSchema, let schema = responseFormat?.jsonSchema?.schema else {
            return nil
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(schema)
            return .jsonSchema(String(decoding: data, as: UTF8.self))
        } catch {
            throw ServerError.invalidRequest(
                message: "response_format.json_schema.schema could not be encoded: \(error.localizedDescription)",
                param: "response_format",
                code: "invalid_json_schema"
            )
        }
    }

    internal func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        let stream = try generate(for: request, using: backend)
        let mapper = ChatCompletionEventMapper(id: completionID(), created: currentTimestamp(), model: request.model)
        return try await mapper.response(from: stream.events)
    }

    internal func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        let stream = try generate(for: request, using: backend)
        let mapper = ChatCompletionEventMapper(id: completionID(), created: currentTimestamp(), model: request.model)
        return mapper.chunks(
            from: stream.events,
            includeUsage: request.includesStreamUsage,
            onCancel: { backend.stopGeneration() }
        )
    }

    /// Threads the request's structured multi-turn history onto the backend and
    /// kicks off generation.
    ///
    /// Mirrors the engine's non-prompt-template dispatch path
    /// (`GenerationQueue.dispatchToBackend` →
    /// `GenerationHistoryInstaller.installHistory`): per-message roles, tool
    /// calls, and tool results are preserved by installing them through the
    /// public history-receiver protocols (`ToolCallingHistoryReceiver`,
    /// `StructuredHistoryReceiver`, `ConversationHistoryReceiver`) rather than
    /// being collapsed into one `role: text` string. The backends the server
    /// can actually load (Ollama, Foundation) reconstruct the turn structure
    /// from that installed history; the `prompt` argument carries the latest
    /// user turn for the absent-history fallback shape.
    private func generate(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> GenerationStream {
        let conversation = request.messages.filter { $0.role != .system && $0.role != .developer }
        installHistory(from: conversation, on: backend)
        let (prompt, systemPrompt) = promptParts(for: request)
        return try backend.generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: generationConfig(for: request),
            hints: generationHints(for: request)
        )
    }

    /// Installs the structured conversation history on whichever receiver
    /// protocol(s) the backend opts into — the same precedence the engine uses.
    private func installHistory(from conversation: [ChatCompletionMessage], on backend: any InferenceBackend) {
        if let toolReceiver = backend as? ToolCallingHistoryReceiver {
            toolReceiver.setToolAwareHistory(conversation.map(\.toolAwareHistoryEntry))
        }
        if let structuredReceiver = backend as? StructuredHistoryReceiver {
            structuredReceiver.setStructuredHistory(conversation.map(\.structuredMessage))
        }
        if let historyReceiver = backend as? ConversationHistoryReceiver {
            historyReceiver.setConversationHistory(conversation.map { (role: $0.role.rawValue, content: $0.content ?? "") })
        }
    }

    /// Builds the `(prompt, systemPrompt)` pair for the legacy single-string
    /// `generate` entry point. The system/developer turns are joined into the
    /// system prompt; the prompt is the most recent user turn so backends
    /// without an installed history (the fallback shape) still see the current
    /// message.
    private func promptParts(for request: ChatCompletionRequest) -> (prompt: String, systemPrompt: String?) {
        let systemPrompt = request.messages
            .filter { $0.role == .system || $0.role == .developer }
            .compactMap(\.content)
            .joined(separator: "\n")
        let prompt = request.messages
            .last(where: { $0.role == .user })?
            .content ?? ""
        return (prompt, systemPrompt.isEmpty ? nil : systemPrompt)
    }

    private func completionID() -> String { "chatcmpl-\(UUID().uuidString)" }
    private func currentTimestamp() -> Int { Int(Date().timeIntervalSince1970) }
}

internal struct ChatCompletionEventMapper: Sendable {
    internal var id: String
    internal var created: Int
    internal var model: String

    internal init(id: String, created: Int, model: String) {
        self.id = id
        self.created = created
        self.model = model
    }

    internal func response<S: AsyncSequence & Sendable>(from events: S) async throws -> ChatCompletionResponse where S.Element == GenerationEvent {
        var state = Accumulator()
        for try await event in events {
            state.apply(event)
        }
        let message = ChatCompletionMessage(
            role: .assistant,
            content: state.content.isEmpty ? nil : state.content,
            reasoningContent: state.reasoningContent.isEmpty ? nil : state.reasoningContent,
            toolCalls: state.toolCalls.isEmpty ? nil : state.toolCalls
        )
        return ChatCompletionResponse(
            id: id,
            created: created,
            model: model,
            choices: [ChatCompletionChoice(index: 0, message: message, finishReason: state.finishReason)],
            usage: state.usage
        )
    }

    internal func chunks<S: AsyncSequence & Sendable>(
        from events: S,
        includeUsage: Bool,
        onCancel: @escaping @Sendable () -> Void = {}
    ) -> AsyncThrowingStream<ChatCompletionChunk, Error> where S.Element == GenerationEvent {
        AsyncThrowingStream { continuation in
            let id = self.id
            let created = self.created
            let model = self.model
            let task = Task {
                var state = Accumulator()
                continuation.yield(Self.chunk(id: id, created: created, model: model, delta: ChatCompletionDelta(role: .assistant)))
                do {
                    for try await event in events {
                        switch event {
                        case .token(let text):
                            state.apply(event)
                            continuation.yield(Self.chunk(id: id, created: created, model: model, delta: ChatCompletionDelta(content: text)))
                        case .thinkingToken(let text):
                            state.apply(event)
                            continuation.yield(Self.chunk(id: id, created: created, model: model, delta: ChatCompletionDelta(reasoningContent: text)))
                        case .toolCallStart(let callID, let name):
                            let index = state.index(for: callID)
                            state.apply(event)
                            let toolCall = ChatCompletionDeltaToolCall(
                                index: index,
                                id: callID,
                                type: "function",
                                function: ChatCompletionFunctionCall(name: name)
                            )
                            continuation.yield(Self.chunk(id: id, created: created, model: model, delta: ChatCompletionDelta(toolCalls: [toolCall])))
                        case .toolCallArgumentsDelta(let callID, let textDelta):
                            let index = state.index(for: callID)
                            state.apply(event)
                            let toolCall = ChatCompletionDeltaToolCall(
                                index: index,
                                function: ChatCompletionFunctionCall(arguments: textDelta)
                            )
                            continuation.yield(Self.chunk(id: id, created: created, model: model, delta: ChatCompletionDelta(toolCalls: [toolCall])))
                        case .toolCall(let call):
                            let index = state.index(for: call.id)
                            state.apply(event)
                            let toolCall = ChatCompletionDeltaToolCall(
                                index: index,
                                id: call.id,
                                type: "function",
                                function: ChatCompletionFunctionCall(name: call.toolName, arguments: call.arguments)
                            )
                            continuation.yield(Self.chunk(id: id, created: created, model: model, delta: ChatCompletionDelta(toolCalls: [toolCall])))
                        case .usage:
                            state.apply(event)
                        default:
                            state.apply(event)
                        }
                    }
                    continuation.yield(Self.chunk(
                        id: id,
                        created: created,
                        model: model,
                        delta: ChatCompletionDelta(),
                        finishReason: state.finishReason
                    ))
                    if includeUsage, let usage = state.usage {
                        continuation.yield(ChatCompletionChunk(
                            id: id,
                            created: created,
                            model: model,
                            choices: [],
                            usage: usage
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                task.cancel()
                if case .cancelled = termination {
                    onCancel()
                }
            }
        }
    }

    private static func chunk(
        id: String,
        created: Int,
        model: String,
        delta: ChatCompletionDelta,
        finishReason: ChatCompletionFinishReason? = nil
    ) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: id,
            created: created,
            model: model,
            choices: [ChatCompletionChunkChoice(index: 0, delta: delta, finishReason: finishReason)]
        )
    }

    private struct Accumulator: Sendable {
        var content = ""
        var reasoningContent = ""
        var usage: ChatCompletionUsage?
        var sawToolCall = false
        var toolIndexes: [String: Int] = [:]
        var toolCallNames: [String: String] = [:]
        var toolCallArguments: [String: String] = [:]

        var toolCalls: [ChatCompletionMessageToolCall] {
            toolIndexes.sorted { $0.value < $1.value }.map { callID, _ in
                ChatCompletionMessageToolCall(
                    id: callID,
                    function: ChatCompletionFunctionCall(
                        name: toolCallNames[callID],
                        arguments: toolCallArguments[callID] ?? ""
                    )
                )
            }
        }

        var finishReason: ChatCompletionFinishReason { sawToolCall ? .toolCalls : .stop }

        mutating func index(for callID: String) -> Int {
            if let index = toolIndexes[callID] { return index }
            let index = toolIndexes.count
            toolIndexes[callID] = index
            return index
        }

        mutating func apply(_ event: GenerationEvent) {
            switch event {
            case .token(let text):
                content += text
            case .thinkingToken(let text):
                reasoningContent += text
            case .usage(let tokenUsage):
                usage = ChatCompletionUsage(promptTokens: tokenUsage.promptTokens, completionTokens: tokenUsage.completionTokens)
            case .toolCallStart(let callID, let name):
                _ = index(for: callID)
                sawToolCall = true
                toolCallNames[callID] = name
                toolCallArguments[callID, default: ""] += ""
            case .toolCallArgumentsDelta(let callID, let textDelta):
                _ = index(for: callID)
                sawToolCall = true
                toolCallArguments[callID, default: ""] += textDelta
            case .toolCall(let call):
                _ = index(for: call.id)
                sawToolCall = true
                toolCallNames[call.id] = call.toolName
                toolCallArguments[call.id] = call.arguments
            default:
                break
            }
        }
    }
}

#endif
