#if CloudSaaS
import Foundation
import ManifoldInference
import ManifoldCloudCore

/// `CloudHTTPProviderAdapter` composition for the OpenAI Responses API
/// (`POST /v1/responses`).
///
/// The Responses API shares OpenAI's `image_url`, `json_schema` (under
/// `text.format`), prefix-stable prompt cache, and `{error: {message}}`
/// error-body shapes with Chat Completions. It diverges on:
///
/// - **Tool-call transport**: a per-item streaming shape keyed by
///   `item_id` (`response.output_item.added` →
///   `response.function_call_arguments.delta` →
///   `response.function_call_arguments.done`) rather than Chat
///   Completions' per-index delta shape. Captured by the
///   ``OpenAIResponsesItemIdToolCalls`` witness.
/// - **Tool-result encoding**: tool turns serialise as
///   `function_call` / `function_call_output` *items* on the request's
///   `input[]` rather than as `role:"tool"` *messages*. Captured by the
///   ``OpenAIResponsesFunctionCallItems`` witness.
/// - **Framing transport**: ``NamedSSETransport`` because reasoning vs.
///   visible-text classification depends on the `event:` name.
/// - **Stream finaliser**: ``OpenAIResponsesEventFinalizer`` —
///   `response.completed` is the terminal event, not the SSE `[DONE]`
///   sentinel.
///
/// The adapter forwards `buildRequest` to a host-supplied closure so the
/// backend keeps owning per-turn state (tool-aware history snapshot/clear,
/// just-in-time keychain API-key resolution, model-name-derived URL).
/// The migration is staged like ``OpenAIAdapter``: the adapter is the
/// composition root the cross-backend audit recognises, while
/// `OpenAIResponsesBackend.init` installs a `CloudAdapterRouting` that
/// invokes the backend's own `buildRequest` override.
public struct OpenAIResponsesAdapter: CloudHTTPProviderAdapter {

    public let messageEncoder: CloudMessageEncoder
    public let payloadHandler: CloudPayloadHandler
    public let framedTransport: any FramedTransport
    public let streamFinalizer: any StreamFinalizer
    public let toolCallShape: any ToolCallShape
    public let imageInputShape: any ImageInputShape
    public let structuredOutputShape: any StructuredOutputShape
    public let toolResultEncoding: any ToolResultEncoding
    public let promptCacheShape: any PromptCacheShape
    public let errorBodyDecoder: any ErrorBodyDecoder
    public let capabilities: BackendCapabilities

    private let requestBuilder: @Sendable (
        _ prompt: String,
        _ systemPrompt: String?,
        _ config: GenerationConfig,
        _ history: [StructuredMessage]
    ) throws -> URLRequest

    public init(
        capabilities: BackendCapabilities,
        messageEncoder: CloudMessageEncoder = .openAIResponses,
        payloadHandler: CloudPayloadHandler = .openAIResponses,
        framedTransport: any FramedTransport = NamedSSETransport(),
        streamFinalizer: any StreamFinalizer = OpenAIResponsesEventFinalizer(),
        requestBuilder: @escaping @Sendable (String, String?, GenerationConfig, [StructuredMessage]) throws -> URLRequest
    ) {
        self.capabilities = capabilities
        self.messageEncoder = messageEncoder
        self.payloadHandler = payloadHandler
        self.framedTransport = framedTransport
        self.streamFinalizer = streamFinalizer
        self.toolCallShape = OpenAIResponsesItemIdToolCalls()
        self.imageInputShape = OpenAIImageURL()
        self.structuredOutputShape = OpenAIJSONSchema()
        self.toolResultEncoding = OpenAIResponsesFunctionCallItems()
        self.promptCacheShape = OpenAIPrefixStableCache()
        self.errorBodyDecoder = DefaultErrorBodyDecoder()
        self.requestBuilder = requestBuilder
    }

    public func buildRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        history: [StructuredMessage]
    ) throws -> URLRequest {
        try requestBuilder(prompt, systemPrompt, config, history)
    }
}

// MARK: - Responses-specific witnesses

/// Responses API tool-call transport: per-item streaming keyed by
/// `item_id`. Distinct from Chat Completions' per-index delta shape.
public struct OpenAIResponsesItemIdToolCalls: ToolCallShape {
    public init() {}
    public var shapeName: String { "openai_responses.item_id" }
}

/// Responses API tool-result encoding: `function_call` /
/// `function_call_output` items on the request body's `input[]` array,
/// not `role:"tool"` messages.
public struct OpenAIResponsesFunctionCallItems: ToolResultEncoding {
    public init() {}
    public var encodingName: String { "openai_responses.function_call_items" }
}
#endif
