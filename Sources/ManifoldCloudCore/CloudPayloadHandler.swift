import Foundation
import ManifoldInference

/// Unified entry point for the cloud provider payload handlers.
///
/// `CloudPayloadHandler` collapses the parallel `SSEPayloadHandler`
/// conformances (`OpenAIPayloadHandler`, `OpenAIResponsesPayloadHandler`,
/// `ClaudePayloadHandler`, `OllamaPayloadHandler`) into a single
/// provider-keyed surface so that:
/// 1. New backends pick up the unified entry point automatically,
/// 2. `CloudPayloadHandlerContractTests` has a single parameterised
///    subject under test, and
/// 3. Each backend `init(...)` constructs exactly one handler value.
///
/// ### Why a wrapper struct and not an enum
///
/// This was an enum whose switch arms called the per-provider parser
/// namespaces directly. The v0.48 product split moved those parsers into
/// `ManifoldOllama` / `ManifoldCloudSaaS`, which sit *above* this module —
/// an enum here can no longer name them. The struct keeps the public
/// `.openAI` / `.claude` / `.ollama` / `.openAIResponses` spelling via
/// static accessors (`.openAI` below; the others in the provider modules)
/// while the parsing witness travels with its provider.
public struct CloudPayloadHandler: Sendable, SSEPayloadHandler {

    /// Identity of the wire format this handler parses. Stands in for the
    /// retired enum cases so factory extensions (e.g.
    /// `makeClaudeStreamConsumer()`) can still discriminate providers.
    public enum Provider: String, Sendable, Hashable {
        case openAI
        case openAIResponses
        case claude
        case ollama
    }

    public let provider: Provider
    private let base: any SSEPayloadHandler

    /// Wraps a provider-specific `SSEPayloadHandler` witness. Provider
    /// modules use this to publish their `.claude` / `.ollama` /
    /// `.openAIResponses` static accessors.
    public init(provider: Provider, wrapping base: any SSEPayloadHandler) {
        self.provider = provider
        self.base = base
    }

    // MARK: - SSEPayloadHandler

    public func extractToken(from payload: String) -> String? {
        base.extractToken(from: payload)
    }

    public func extractEvents(from payload: String) -> [GenerationEvent] {
        base.extractEvents(from: payload)
    }

    public func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        base.extractUsage(from: payload)
    }

    public func isStreamEnd(_ payload: String) -> Bool {
        base.isStreamEnd(payload)
    }

    public func extractStreamError(from payload: String) -> Error? {
        base.extractStreamError(from: payload)
    }

    // MARK: - OpenAI Chat Completions

    /// Handler for the OpenAI Chat Completions wire shape. Lives here (not
    /// in `ManifoldCloudSaaS`) because the parsing is shared with Ollama's
    /// OpenAI-compatible endpoint via `OpenAIChatCompletionsPayloadParsing`.
    public static var openAI: CloudPayloadHandler {
        CloudPayloadHandler(provider: .openAI, wrapping: OpenAIChatCompletionsPayloadHandler())
    }
}

/// Stateless witness for the OpenAI Chat Completions streaming format.
///
/// Chat Completions doesn't carry an explicit in-payload terminal sentinel;
/// the SSE `[DONE]` line is stripped at framing time. Backends rely on
/// `finish_reason` + usage to detect termination.
struct OpenAIChatCompletionsPayloadHandler: SSEPayloadHandler {
    func extractToken(from payload: String) -> String? {
        OpenAIChatCompletionsPayloadParsing.extractToken(from: payload)
    }

    func extractEvents(from payload: String) -> [GenerationEvent] {
        OpenAIChatCompletionsPayloadParsing.extractEvents(from: payload)
    }

    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        OpenAIChatCompletionsPayloadParsing.extractUsage(from: payload)
    }

    func isStreamEnd(_ payload: String) -> Bool { false }

    func extractStreamError(from payload: String) -> Error? { nil }
}
