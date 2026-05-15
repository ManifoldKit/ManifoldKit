#if Ollama || CloudSaaS
import Foundation

// MARK: - Tool-Call Shape
//
// The six "shape" protocols below model the essential per-provider
// divergences identified by the cross-backend audit. They are deliberately
// small (≤2 methods each) and use the *witness* pattern rather than closed
// enums so downstream packages can add a backend (Gemini, GROQ, Bedrock)
// without forcing exhaustive `switch` updates across every adapter in the
// tree. Each concrete witness shipped here is a stub conforming type that
// declares its shape — Phase 2/B fills in the wire-encoding bodies and
// routes adapters through the witnesses. The protocols ship now so adapter
// composition can be expressed in the type system from the moment
// `CloudHTTPProviderAdapter` lands.

/// How a provider transports tool calls on the wire.
///
/// The three observed shapes today:
///
/// - OpenAI-style: `delta.tool_calls[]` with per-`index` argument deltas,
///   buffered into `.toolCallStart` → N×`.toolCallArgumentsDelta` →
///   `.toolCall` events.
/// - Anthropic-style: `content_block_start` / `content_block_delta` events
///   with typed `tool_use` blocks; per-block accumulation.
/// - Ollama / chat-completions non-streaming: a single `message.tool_calls`
///   array delivered whole on the terminal frame.
///
/// Implementations are `Sendable` value types; an adapter composes one.
public protocol ToolCallShape: Sendable {
    /// Human-readable shape label used by diagnostics and the
    /// `ToolTransportShapeAuditTest` two-direction check (Phase 3).
    var shapeName: String { get }
}

/// OpenAI Chat Completions streaming-delta shape.
public struct OpenAIDeltaToolCalls: ToolCallShape {
    public init() {}
    public var shapeName: String { "openai.delta" }
}

/// Anthropic content-block tool-use shape.
public struct AnthropicBlockToolCalls: ToolCallShape {
    public init() {}
    public var shapeName: String { "anthropic.block" }
}

/// Ollama whole-array tool-calls (delivered in one terminal frame).
public struct OllamaWholeToolCalls: ToolCallShape {
    public init() {}
    public var shapeName: String { "ollama.whole" }
}

/// Inline-marker dialect: tool calls embedded as `<tool_call>…</tool_call>`
/// text spans (some Ollama chat templates, llama.cpp grammar paths).
public struct InlineMarkerToolCalls: ToolCallShape {
    public init() {}
    public var shapeName: String { "inline.marker" }
}

/// OpenAI Responses API item-id shape: tool calls are identified by
/// `response.output[].id` rather than `delta.tool_calls[].index`.
public struct OpenAIResponsesItemIdToolCalls: ToolCallShape {
    public init() {}
    public var shapeName: String { "openai_responses.item_id" }
}

// MARK: - Image Input Shape

/// How a provider accepts inbound image attachments.
public protocol ImageInputShape: Sendable {
    var shapeName: String { get }
}

/// OpenAI Chat Completions `image_url` content-part shape.
public struct OpenAIImageURL: ImageInputShape {
    public init() {}
    public var shapeName: String { "openai.image_url" }
}

/// Anthropic `image` content block with `source.{type:"base64", media_type, data}`.
public struct AnthropicImageBlock: ImageInputShape {
    public init() {}
    public var shapeName: String { "anthropic.image_block" }
}

/// Ollama `images[]` field on the message: array of base-64 strings, no MIME.
public struct OllamaImagesField: ImageInputShape {
    public init() {}
    public var shapeName: String { "ollama.images_field" }
}

/// Backend does not accept image input.
public struct NoImageInput: ImageInputShape {
    public init() {}
    public var shapeName: String { "none" }
}

// MARK: - Structured Output Shape

/// How a provider accepts a JSON-schema / structured-output instruction.
public protocol StructuredOutputShape: Sendable {
    var shapeName: String { get }
}

/// OpenAI `response_format: {type:"json_schema", ...}` (and legacy
/// `json_object`).
public struct OpenAIJSONSchema: StructuredOutputShape {
    public init() {}
    public var shapeName: String { "openai.json_schema" }
}

/// Anthropic does not have native structured-output; callers prompt-engineer.
public struct AnthropicPromptedJSON: StructuredOutputShape {
    public init() {}
    public var shapeName: String { "anthropic.prompted" }
}

/// Ollama `format: "json"` (legacy) or `format: <schema>` (newer).
public struct OllamaFormatField: StructuredOutputShape {
    public init() {}
    public var shapeName: String { "ollama.format" }
}

/// Backend does not support structured output.
public struct NoStructuredOutput: StructuredOutputShape {
    public init() {}
    public var shapeName: String { "none" }
}

// MARK: - Tool Result Encoding

/// How a provider expects tool-result messages on the request body for the
/// follow-up turn after a tool call.
public protocol ToolResultEncoding: Sendable {
    var encodingName: String { get }
}

/// OpenAI: `{role:"tool", tool_call_id, content}` message entries.
public struct OpenAIToolResult: ToolResultEncoding {
    public init() {}
    public var encodingName: String { "openai.role_tool" }
}

/// Anthropic: user message with `tool_result` content blocks referencing
/// `tool_use_id`.
public struct AnthropicToolResult: ToolResultEncoding {
    public init() {}
    public var encodingName: String { "anthropic.tool_result_block" }
}

/// Ollama: `{role:"tool", content}` (no `tool_call_id` on most builds).
public struct OllamaToolResult: ToolResultEncoding {
    public init() {}
    public var encodingName: String { "ollama.role_tool" }
}

// MARK: - Prompt Cache Shape
//
// Named `PromptCacheShape` (not `PromptCachePolicy`) to avoid colliding with
// the existing `PromptCachePolicy` enum that gates Anthropic
// `cache_control` emission. The witness here describes the *shape* of the
// provider's cache surface; the enum decides whether to use it.

/// How a provider surfaces prompt-cache control.
public protocol PromptCacheShape: Sendable {
    var shapeName: String { get }
}

/// Anthropic-style: explicit `cache_control: {type:"ephemeral"}` breakpoint
/// markers annotated on selected blocks. `maxBreakpoints` caps how many can
/// be emitted (Anthropic charges per breakpoint).
public struct AnthropicExplicitBreakpoints: PromptCacheShape {
    public let maxBreakpoints: Int
    public init(maxBreakpoints: Int = 4) { self.maxBreakpoints = maxBreakpoints }
    public var shapeName: String { "anthropic.explicit_breakpoints" }
}

/// OpenAI-style: prefix-stable automatic caching — no per-call annotation,
/// the provider hashes the request prefix server-side.
public struct OpenAIPrefixStableCache: PromptCacheShape {
    public init() {}
    public var shapeName: String { "openai.prefix_stable" }
}

/// No prompt-cache surface (Ollama today).
public struct NoPromptCache: PromptCacheShape {
    public init() {}
    public var shapeName: String { "none" }
}

// MARK: - Error Body Decoder

/// Maps an upstream HTTP error response body to a human-readable error
/// message. Adapters compose one so `SSECloudBackend.checkStatusCode`
/// surfaces provider-shaped errors without per-provider branches.
public protocol ErrorBodyDecoder: Sendable {
    /// Extract a user-facing error message from a JSON / text error body.
    /// Returns `nil` when the body doesn't match a known shape; the caller
    /// falls back to the raw body (sanitized).
    func extractMessage(from body: String) -> String?
}

/// Default decoder: handles `{error:{message:…}}`, flat `{message:…}`, and
/// `{detail:…}` shapes used by OpenAI, Anthropic, and most compat servers.
public struct DefaultErrorBodyDecoder: ErrorBodyDecoder {
    public init() {}
    public func extractMessage(from body: String) -> String? {
        parseCloudErrorMessage(from: body)
    }
}
#endif
