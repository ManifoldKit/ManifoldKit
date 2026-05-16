#if Ollama || CloudSaaS
import Foundation
import ManifoldInference
import ManifoldCloudCore

/// Unified entry point for the four cloud provider payload handlers.
///
/// `CloudPayloadHandler` collapses the four parallel `SSEPayloadHandler`
/// conformances (`OpenAIPayloadHandler`, `OpenAIResponsesPayloadHandler`,
/// `ClaudePayloadHandler`, `OllamaPayloadHandler`) into a single
/// enum-keyed surface. Each case dispatches to the existing per-provider
/// parsing namespace, which stays in place for the per-stream-loop helpers
/// the backends still call directly (`ClaudePayloadParser.parseEventType`,
/// `OllamaPayloadParser.parseLine`, etc.).
///
/// - Note: The full collapse of those internal parser namespaces into the
///   enum lives in Phase 2 (alongside the `CloudHTTPProviderAdapter` shape),
///   when the stream loops themselves move into the adapter and the
///   parser calls can be re-keyed off the enum directly without crossing
///   the backend boundary. Phase 1b only unifies the protocol-conforming
///   surface so that:
///   1. New backends pick up the unified entry point automatically
///      (`CloudPayloadHandler.case` rather than a new top-level struct),
///   2. `CloudPayloadHandlerContractTests` has a single parameterised
///      subject under test, and
///   3. The four `*PayloadHandler` symbols become deprecated wrappers
///      whose call sites are exactly the four backend `init(...)`s.
public enum CloudPayloadHandler: Sendable, SSEPayloadHandler {
    case openAI
    case openAIResponses
    case claude
    case ollama

    // MARK: - SSEPayloadHandler

    public func extractToken(from payload: String) -> String? {
        switch self {
        case .openAI:
            return OpenAIChatCompletionsPayloadParsing.extractToken(from: payload)
        case .openAIResponses:
            #if CloudSaaS
            return OpenAIResponsesPayloadParsing.extractToken(from: payload)
            #else
            return nil
            #endif
        case .claude:
            #if CloudSaaS
            return ClaudePayloadParsingDispatch.extractToken(from: payload)
            #else
            return nil
            #endif
        case .ollama:
            #if Ollama
            return OllamaPayloadParsingDispatch.extractToken(from: payload)
            #else
            return nil
            #endif
        }
    }

    public func extractEvents(from payload: String) -> [GenerationEvent] {
        switch self {
        case .openAI:
            return OpenAIChatCompletionsPayloadParsing.extractEvents(from: payload)
        case .openAIResponses:
            #if CloudSaaS
            return OpenAIResponsesPayloadParsing.extractEvents(from: payload)
            #else
            return []
            #endif
        case .claude:
            #if CloudSaaS
            return ClaudePayloadParsingDispatch.extractEvents(from: payload)
            #else
            return []
            #endif
        case .ollama:
            #if Ollama
            return OllamaPayloadParsingDispatch.extractEvents(from: payload)
            #else
            return []
            #endif
        }
    }

    public func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        switch self {
        case .openAI:
            return OpenAIChatCompletionsPayloadParsing.extractUsage(from: payload)
        case .openAIResponses:
            #if CloudSaaS
            return OpenAIResponsesPayloadParsing.extractUsage(from: payload)
            #else
            return nil
            #endif
        case .claude:
            #if CloudSaaS
            return ClaudePayloadParsingDispatch.extractUsage(from: payload)
            #else
            return nil
            #endif
        case .ollama:
            #if Ollama
            return OllamaPayloadParsingDispatch.extractUsage(from: payload)
            #else
            return nil
            #endif
        }
    }

    public func isStreamEnd(_ payload: String) -> Bool {
        switch self {
        case .openAI, .openAIResponses:
            // Chat Completions / Responses don't carry an explicit
            // in-payload terminal sentinel; the SSE `[DONE]` line is
            // stripped at framing time. Backends rely on `finish_reason` +
            // usage to detect termination — a `StreamFinalizer` job in
            // Phase 2.
            return false
        case .claude:
            #if CloudSaaS
            return ClaudePayloadParsingDispatch.isStreamEnd(payload)
            #else
            return false
            #endif
        case .ollama:
            // Ollama signals termination via the `"done":true` flag, but
            // the existing backend stream loop reads that field directly
            // out of the per-line parse rather than via the handler.
            // Phase 2 will route this through `StreamFinalizer`.
            return false
        }
    }

    public func extractStreamError(from payload: String) -> Error? {
        switch self {
        case .openAI, .ollama:
            return nil
        case .openAIResponses:
            #if CloudSaaS
            // Adapter-routed Responses streams ride `NamedSSETransport`,
            // which wraps each event as `{__event, __data}`. Surface
            // `response.error` events as a thrown error so the routed
            // loop terminates the stream.
            return OpenAIResponsesPayloadParsing.extractStreamError(from: payload)
            #else
            return nil
            #endif
        case .claude:
            #if CloudSaaS
            return ClaudePayloadParsingDispatch.extractStreamError(from: payload)
            #else
            return nil
            #endif
        }
    }
}

// MARK: - Dispatch shims
//
// These enums forward to the existing per-provider parser namespaces.
// Once Phase 2 lifts the parser internals into the adapter composition,
// these shims will collapse into the enum's `switch` arms directly.

#if CloudSaaS
enum ClaudePayloadParsingDispatch {
    static func extractToken(from payload: String) -> String? {
        ClaudePayloadParser.parseToken(from: payload)
    }

    static func extractEvents(from payload: String) -> [GenerationEvent] {
        if let thinking = ClaudePayloadParser.parseThinkingDelta(from: payload) {
            return [.thinkingToken(thinking)]
        }
        if let token = ClaudePayloadParser.parseToken(from: payload) {
            return [.token(token)]
        }
        return []
    }

    static func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        ClaudePayloadParser.parseUsage(from: payload)
    }

    static func isStreamEnd(_ payload: String) -> Bool {
        ClaudePayloadParser.parseIsStreamEnd(payload)
    }

    static func extractStreamError(from payload: String) -> Error? {
        ClaudePayloadParser.parseStreamError(from: payload)
    }
}
#endif

#if Ollama
enum OllamaPayloadParsingDispatch {
    static func extractToken(from payload: String) -> String? {
        OllamaPayloadParser.extractToken(from: payload)
    }

    static func extractEvents(from payload: String) -> [GenerationEvent] {
        guard let parsed = OllamaPayloadParser.parseLine(payload) else { return [] }
        var events: [GenerationEvent] = []
        if let thinking = parsed.thinking, !thinking.isEmpty {
            events.append(.thinkingToken(thinking))
        }
        if let content = parsed.content, !content.isEmpty {
            events.append(.token(content))
        }
        return events
    }

    static func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let parsed = OllamaPayloadParser.parseLine(payload) else { return nil }
        guard parsed.evalCount != nil || parsed.promptEvalCount != nil else {
            return nil
        }
        return (
            promptTokens: parsed.promptEvalCount,
            completionTokens: parsed.evalCount
        )
    }
}
#endif

#if CloudSaaS
enum OpenAIResponsesPayloadParsing {
    static func extractToken(from payload: String) -> String? {
        OpenAIResponsesBackend.parseDelta(from: payload)
    }

    static func extractEvents(from payload: String) -> [GenerationEvent] {
        if let delta = OpenAIResponsesBackend.parseDelta(from: payload), !delta.isEmpty {
            return [.token(delta)]
        }
        return []
    }

    static func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        OpenAIResponsesBackend.parseUsage(from: payload)
    }

    /// Inspects a `NamedSSETransport`-wrapped payload (or a raw event
    /// data string) for the `response.error` event signature and
    /// surfaces it as a ``CloudBackendError/serverError`` so the
    /// adapter-routed stream loop terminates instead of silently
    /// skipping the event.
    static func extractStreamError(from payload: String) -> Error? {
        guard let envelope = NamedSSETransport.unwrap(envelope: payload) else {
            return nil
        }
        guard envelope.name == "response.error" else { return nil }
        let message = OpenAIResponsesBackend.parseErrorMessage(from: envelope.data) ?? "unknown error"
        return CloudBackendError.serverError(statusCode: 500, message: message)
    }
}
#endif // CloudSaaS
#endif // Ollama || CloudSaaS
