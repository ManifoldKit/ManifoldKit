import Foundation
import ManifoldInference
import ManifoldCloudCore

/// `CloudHTTPProviderAdapter` composition for Anthropic Claude (Messages API).
///
/// Mirrors `OpenAIAdapter` for the Claude wire shape:
///
/// - Tool calls arrive as typed `content_block` blocks with `type: tool_use`
///   (whole-block shape with id/name on `content_block_start` and a stream
///   of `input_json_delta` events building up `input`).
/// - Image inputs use Anthropic `image` content blocks with
///   `source.{type:"base64", media_type, data}`.
///   The Messages API rejects more than 5 images per turn; the backend
///   enforces this pre-flight (`ClaudeBackend.maxImagesPerTurn`).
/// - Structured output is **emulated** via forced tool calls (Anthropic has
///   no native `response_format` equivalent today) — callers prompt-engineer
///   or use the `tool_choice: { type: "tool" }` pattern.
///   `BackendCapabilities.supportsNativeJSONMode` is `false` for this
///   backend (see `ClaudeBackend.capabilities`).
/// - Tool results encode as user-role messages with `tool_result` content
///   blocks (correlated via `tool_use_id`).
/// - Prompt cache uses explicit `cache_control: {type: "ephemeral"}`
///   breakpoints on selected blocks, capped at 4 by Anthropic. The
///   wire-level annotation lives in `CloudMessageEncoder.claude`'s system /
///   tools encoding; the policy gate is `ClaudeBackend.cachePolicy`.
/// - Error bodies use Anthropic's `{type:"error", error:{type, message}}`
///   nested shape; `DefaultErrorBodyDecoder` handles it via the shared
///   `parseCloudErrorMessage` helper which already recognises the nested
///   `error.message` form.
/// - Streaming is SSE; termination is signalled by a dedicated
///   `message_stop` event — `ClaudeMessageStopFinalizer`.
///
/// ### Routing status — fully flipped (Phase 3/Claude)
///
/// `ClaudeBackend` composes this adapter and installs a
/// `CloudAdapterRouting` whose `streamConsumerFactory` returns a fresh
/// `ClaudeStreamEventExtractor` per generation. The routing forwards
/// `buildRequest` back to the backend (which keeps owning tool-aware
/// history snapshot/clear, structured-history vision pre-flight, and
/// per-turn cache-policy snapshotting); everything else — payload
/// extraction, framing, finalization, error-body decoding — is driven by
/// the adapter's witnesses. The inline `parseResponseStream` override
/// was removed alongside `ClaudeToolCallAccumulator` (mirrors Phase
/// 2/B/iii/δ for OpenAI).
public struct ClaudeAdapter: CloudHTTPProviderAdapter {

    public let messageEncoder: CloudMessageEncoder
    public let payloadHandler: CloudPayloadHandler
    public let framedTransport: any FramedTransport
    public let streamFinalizer: any StreamFinalizer
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
        messageEncoder: CloudMessageEncoder = .claude,
        payloadHandler: CloudPayloadHandler = .claude,
        framedTransport: any FramedTransport = SSETransport(),
        streamFinalizer: any StreamFinalizer = ClaudeMessageStopFinalizer(),
        requestBuilder: @escaping @Sendable (String, String?, GenerationConfig, [StructuredMessage]) throws -> URLRequest
    ) {
        self.capabilities = capabilities
        self.messageEncoder = messageEncoder
        self.payloadHandler = payloadHandler
        self.framedTransport = framedTransport
        self.streamFinalizer = streamFinalizer
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
