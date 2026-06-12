import Foundation
import ManifoldInference
import ManifoldCloudCore

// The `.ollama` accessor lives here — not in `ManifoldCloudCore` with the
// `CloudPayloadHandler` type — because its witness calls
// `OllamaPayloadParser`, which belongs to this provider module. See the
// type's doc comment for the layering rationale.

extension CloudPayloadHandler {
    /// Handler for Ollama's NDJSON wire shape.
    public static var ollama: CloudPayloadHandler {
        CloudPayloadHandler(provider: .ollama, wrapping: OllamaNDJSONPayloadHandler())
    }
}

/// Stateless witness forwarding to `OllamaPayloadParser`.
struct OllamaNDJSONPayloadHandler: SSEPayloadHandler {
    func extractToken(from payload: String) -> String? {
        OllamaPayloadParser.extractToken(from: payload)
    }

    func extractEvents(from payload: String) -> [GenerationEvent] {
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

    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let parsed = OllamaPayloadParser.parseLine(payload) else { return nil }
        guard parsed.evalCount != nil || parsed.promptEvalCount != nil else {
            return nil
        }
        return (
            promptTokens: parsed.promptEvalCount,
            completionTokens: parsed.evalCount
        )
    }

    // Ollama signals termination via the `"done":true` flag, but the
    // backend stream loop reads that field directly out of the per-line
    // parse rather than via the handler.
    func isStreamEnd(_ payload: String) -> Bool { false }

    func extractStreamError(from payload: String) -> Error? { nil }
}
