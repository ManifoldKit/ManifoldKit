import Foundation
import ManifoldInference
import ManifoldCloudCore

// The `.claude` / `.openAIResponses` accessors live here — not in
// `ManifoldCloudCore` with the `CloudPayloadHandler` type — because their
// witnesses call the Anthropic / OpenAI Responses parser namespaces, which
// belong to this provider module. See the type's doc comment for the
// layering rationale.

extension CloudPayloadHandler {
    /// Handler for the Anthropic Messages API wire shape.
    public static var claude: CloudPayloadHandler {
        CloudPayloadHandler(provider: .claude, wrapping: ClaudeMessagesPayloadHandler())
    }

    /// Handler for the OpenAI Responses API wire shape.
    public static var openAIResponses: CloudPayloadHandler {
        CloudPayloadHandler(provider: .openAIResponses, wrapping: OpenAIResponsesPayloadHandler())
    }
}

/// Stateless witness forwarding to `ClaudePayloadParser`. The stateful
/// cross-frame logic (tool-use accumulation, thinking signatures) lives on
/// ``ClaudeStreamEventExtractor``; this surface covers the per-payload
/// classification the routed stream loop needs.
struct ClaudeMessagesPayloadHandler: SSEPayloadHandler {
    func extractToken(from payload: String) -> String? {
        ClaudePayloadParser.parseToken(from: payload)
    }

    func extractEvents(from payload: String) -> [GenerationEvent] {
        if let thinking = ClaudePayloadParser.parseThinkingDelta(from: payload) {
            return [.thinkingToken(thinking)]
        }
        if let token = ClaudePayloadParser.parseToken(from: payload) {
            return [.token(token)]
        }
        return []
    }

    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        ClaudePayloadParser.parseUsage(from: payload)
    }

    func isStreamEnd(_ payload: String) -> Bool {
        ClaudePayloadParser.parseIsStreamEnd(payload)
    }

    func extractStreamError(from payload: String) -> Error? {
        ClaudePayloadParser.parseStreamError(from: payload)
    }
}

/// Stateless witness for the OpenAI Responses API wire shape.
struct OpenAIResponsesPayloadHandler: SSEPayloadHandler {
    func extractToken(from payload: String) -> String? {
        OpenAIResponsesBackend.parseDelta(from: payload)
    }

    func extractEvents(from payload: String) -> [GenerationEvent] {
        if let delta = OpenAIResponsesBackend.parseDelta(from: payload), !delta.isEmpty {
            return [.token(delta)]
        }
        return []
    }

    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        OpenAIResponsesBackend.parseUsage(from: payload)
    }

    // The Responses API doesn't carry an explicit in-payload terminal
    // sentinel; the SSE `[DONE]` line is stripped at framing time.
    func isStreamEnd(_ payload: String) -> Bool { false }

    /// Inspects a `NamedSSETransport`-wrapped payload (or a raw event
    /// data string) for the `response.error` event signature and
    /// surfaces it as a ``CloudBackendError/serverError`` so the
    /// adapter-routed stream loop terminates instead of silently
    /// skipping the event.
    func extractStreamError(from payload: String) -> Error? {
        guard let envelope = NamedSSETransport.unwrap(envelope: payload) else {
            return nil
        }
        guard envelope.name == "response.error" else { return nil }
        let message = OpenAIResponsesBackend.parseErrorMessage(from: envelope.data)
        return CloudBackendError.sanitizedServerError(statusCode: 500, rawMessage: message)
    }
}
