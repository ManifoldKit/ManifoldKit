#if Ollama
import Foundation
import ManifoldInference
import ManifoldCloudCore

/// Decoded shape of a single Ollama NDJSON record.
///
/// Ollama's two endpoints carry data in different places:
/// - `/api/chat` streams put content in `message.content` and reasoning in
///   `message.thinking`.
/// - `/api/generate` (non-chat) uses top-level `response` and top-level
///   `thinking`.
/// `parseLine` normalises both shapes; consumers read `content` and
/// `thinking` without caring which endpoint produced the line.
///
/// `evalCount` / `promptEvalCount` are the exact token counts reported by
/// the Ollama server. Per Ollama's documented API, these appear on the
/// terminal `"done":true` line — `eval_count` is the number of tokens the
/// model produced this turn and `prompt_eval_count` is the number of tokens
/// in the prompt. Some Ollama-compatible servers also emit a running
/// `eval_count` on intermediate lines; parsing it unconditionally lets the
/// stream cap visible output precisely when available and falls back to a
/// line counter when not.
struct OllamaParsedLine {
    var content: String?
    var thinking: String?
    var done: Bool
    var evalCount: Int?
    var promptEvalCount: Int?
    /// Tool calls emitted by the assistant this line, in emission order.
    /// `nil` when the line carries no `tool_calls` field; an empty array
    /// is normalised to `nil` so downstream callers can short-circuit on
    /// `parsed.toolCalls != nil`.
    var toolCalls: [ToolCall]?
}

enum OllamaPayloadParser {

    /// Parses a single Ollama NDJSON line into a normalised shape.
    ///
    /// Returns `nil` for malformed lines so the stream parser can skip them
    /// the same way it historically skipped unparseable JSON.
    static func parseLine(_ json: String) -> OllamaParsedLine? {
        guard let data = json.data(using: .utf8) else { return nil }
        let parsed: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            parsed = object
        } catch {
            return nil
        }

        let done = (parsed["done"] as? Bool) ?? false

        var content: String?
        var thinking: String?
        var toolCalls: [ToolCall]?

        if let message = parsed["message"] as? [String: Any] {
            // `/api/chat` shape.
            content = message["content"] as? String
            thinking = message["thinking"] as? String
            if let rawCalls = message["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
                toolCalls = rawCalls.compactMap(OllamaMessageEncoder.decodeToolCall)
                if toolCalls?.isEmpty == true { toolCalls = nil }
            }
        }

        // `/api/generate` shape — top-level `response` and `thinking`. If both
        // `message.content` and top-level `response` are present (shouldn't
        // happen in practice), chat-shape wins because it arrived first.
        if content == nil, let response = parsed["response"] as? String {
            content = response
        }
        if thinking == nil, let topThinking = parsed["thinking"] as? String {
            thinking = topThinking
        }

        // Usage fields — `eval_count` (output tokens) and `prompt_eval_count`
        // (prompt tokens). Documented as done-line fields but we parse them
        // unconditionally so a running-count-emitting server is handled too.
        let evalCount = parsed["eval_count"] as? Int
        let promptEvalCount = parsed["prompt_eval_count"] as? Int

        return OllamaParsedLine(
            content: content,
            thinking: thinking,
            done: done,
            evalCount: evalCount,
            promptEvalCount: promptEvalCount,
            toolCalls: toolCalls
        )
    }

    /// Extracts the assistant content token from an Ollama NDJSON line.
    ///
    /// Ollama streaming format (one JSON object per line, no `data:` prefix):
    /// ```json
    /// {"model":"llama3","message":{"role":"assistant","content":"Hello"},"done":false}
    /// ```
    /// Final chunk has `"done":true` and empty or absent content — we skip it.
    ///
    /// This method only surfaces visible content; reasoning-model `thinking`
    /// fields are handled inline by ``parseResponseStream(bytes:config:continuation:)``
    /// so they can be emitted as ``GenerationEvent/thinkingToken(_:)`` with
    /// proper ``GenerationEvent/thinkingComplete`` bracketing. Kept for the
    /// ``SSEPayloadHandler`` protocol conformance and external callers.
    static func extractToken(from json: String) -> String? {
        guard let parsed = parseLine(json) else { return nil }
        // Skip the final "done" chunk.
        if parsed.done { return nil }
        guard let content = parsed.content, !content.isEmpty else { return nil }
        return content
    }

    /// Extracts reasoning content from an Ollama NDJSON line, if any.
    ///
    /// Returns `nil` when the line carries no `thinking` field or an empty
    /// one. Exposed for symmetry with ``extractToken(from:)``; streaming
    /// callers use the inline logic in
    /// ``parseResponseStream(bytes:config:continuation:)`` to bracket
    /// thinking emissions with ``GenerationEvent/thinkingComplete``.
    static func extractThinking(from json: String) -> String? {
        guard let parsed = parseLine(json),
              let thinking = parsed.thinking,
              !thinking.isEmpty else {
            return nil
        }
        return thinking
    }
}

// MARK: - SSE Payload Handler

/// Ollama-specific ``SSEPayloadHandler`` for use with ``SSEStreamParser``.
///
/// Ollama uses **NDJSON**, not strict SSE — every line is a complete
/// JSON object with no `data:` prefix and no blank-line event boundary.
/// The shared SSE byte parser cannot strip those frames, so
/// ``OllamaBackend`` overrides ``parseResponseStream(bytes:config:continuation:)``
/// to walk the byte stream line-by-line instead of via
/// ``SSEStreamParser/parse(bytes:limits:eventIDTracker:)``.
///
/// What this handler *does* provide is the per-line classification: given
/// one NDJSON payload, it surfaces the visible-text and reasoning events
/// it carries. Tests for the migration assert against
/// ``extractEvents(from:)`` directly, so the handler is the canonical
/// per-payload contract even when the production backend bypasses
/// ``SSEStreamParser/streamEvents(from:using:limits:)`` for the byte
/// loop.
struct OllamaPayloadHandler: SSEPayloadHandler {
    init() {}

    func extractToken(from payload: String) -> String? {
        OllamaPayloadParser.extractToken(from: payload)
    }

    /// Maps a single Ollama NDJSON line to the visible-text /
    /// reasoning-text events it carries.
    ///
    /// Emission order matches the on-the-wire field order: any
    /// `message.thinking` (or top-level `thinking`) on the line emits
    /// `.thinkingToken` first, then any `message.content` (or top-level
    /// `response`) emits `.token`.
    ///
    /// Tool calls, `done`-line bookkeeping, the per-stream visible /
    /// thinking caps, and the inline `<think>` fallback all live in the
    /// stateful byte loop because they require cross-payload state a
    /// handler cannot model.
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

    /// Extracts Ollama's per-turn usage from a single NDJSON payload.
    ///
    /// Ollama's documented API places `eval_count` (completion tokens) and
    /// `prompt_eval_count` (prompt tokens) on the terminal `"done":true`
    /// line. Returns `nil` when neither field is present so partial/running
    /// lines don't pollute a consumer that expects "final usage only".
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

    func isStreamEnd(_ payload: String) -> Bool { false }
    func extractStreamError(from payload: String) -> Error? { nil }
}
#endif
