#if CloudSaaS
import Foundation
import ManifoldInference
import ManifoldCloudCore

/// `CloudHTTPProviderAdapter` composition for OpenAI Chat Completions.
///
/// Phase 2/A ships the composition declaration. The witnesses describe the
/// wire shapes OpenAI uses; the `buildRequest` body delegates to
/// `OpenAIBackend.buildRequest` so the migration is staged — Phase 2/B
/// inverts the dependency (`OpenAIBackend` becomes a thin host that owns
/// an `OpenAIAdapter` instance and routes through `SSECloudBackend`'s
/// adapter-driven path).
///
/// > Important: This adapter currently has no consumer in production — it
/// > exists so the protocol shape is exercised end-to-end at compile time
/// > and the `CloudSeamUsageAuditTest` allowlist has a concrete migrated
/// > file to point at by Phase 2/B. Phase 2/A keeps `OpenAIBackend`'s
/// > existing internal call paths intact.
public struct OpenAIAdapter: CloudHTTPProviderAdapter {

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

    /// Closure that builds the request. Phase 2/A wires this through the
    /// existing `OpenAIBackend.buildRequest` via a host-supplied closure
    /// so the adapter remains a value type and can compose without
    /// importing the backend class itself.
    private let requestBuilder: @Sendable (
        _ prompt: String,
        _ systemPrompt: String?,
        _ config: GenerationConfig,
        _ history: [StructuredMessage]
    ) throws -> URLRequest

    public init(
        capabilities: BackendCapabilities,
        messageEncoder: CloudMessageEncoder = .openAI,
        payloadHandler: CloudPayloadHandler = .openAI,
        framedTransport: any FramedTransport = SSETransport(),
        streamFinalizer: any StreamFinalizer = OpenAIDoneSentinelFinalizer(),
        requestBuilder: @escaping @Sendable (String, String?, GenerationConfig, [StructuredMessage]) throws -> URLRequest
    ) {
        self.capabilities = capabilities
        self.messageEncoder = messageEncoder
        self.payloadHandler = payloadHandler
        self.framedTransport = framedTransport
        self.streamFinalizer = streamFinalizer
        self.toolCallShape = OpenAIDeltaToolCalls()
        self.imageInputShape = OpenAIImageURL()
        self.structuredOutputShape = OpenAIJSONSchema()
        self.toolResultEncoding = OpenAIToolResult()
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
#endif
