#if Ollama
import Foundation
import os
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
                toolCalls = rawCalls.compactMap(OllamaPayloadParser.decodeToolCall)
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

    /// Decodes one `tool_calls[]` entry from a parsed NDJSON line.
    ///
    /// Ollama's streaming format follows the OpenAI shape:
    /// `{id, type: "function", function: {name, arguments}}`. The `arguments`
    /// field is sometimes a JSON string (the documented wire shape) and
    /// sometimes a pre-parsed dictionary (observed on some Ollama builds);
    /// the decoder handles both and always produces a ``ToolCall`` whose
    /// `arguments` property is a valid JSON string.
    ///
    /// `id` is optional on the wire — some Ollama builds omit it for the
    /// first tool call in a turn. Synthesise a deterministic fallback from
    /// the tool name plus a counter suffix when absent so downstream
    /// call/result pairing still works.
    ///
    /// Inlined from the former `OllamaMessageEncoder.decodeToolCall` as
    /// part of Phase 1b/B — parser helpers now co-locate with the parser
    /// rather than the encoder.
    static func decodeToolCall(_ raw: [String: Any]) -> ToolCall? {
        // Two observed shapes on the wire:
        //   A) {id, type: "function", function: {name, arguments}}  — documented
        //   B) {id, name, arguments}                                 — some 0.3.x builds
        // Prefer the nested `function` envelope; fall back to the flat shape
        // when it's absent so lenient Ollama forks still produce tool events.
        let nameSource: [String: Any]
        if let function = raw["function"] as? [String: Any] {
            nameSource = function
        } else {
            nameSource = raw
        }
        guard let name = nameSource["name"] as? String, !name.isEmpty else {
            return nil
        }

        let id: String
        if let wireId = raw["id"] as? String, !wireId.isEmpty {
            id = wireId
        } else {
            // Deterministic fallback: ids are only used for id→result pairing
            // inside one turn, so a name-based placeholder is sufficient.
            id = "ollama-\(name)-\(UUID().uuidString.prefix(8))"
        }

        let argumentsString: String
        if let raw = nameSource["arguments"] as? String {
            argumentsString = raw
        } else if let dict = nameSource["arguments"] as? [String: Any] {
            argumentsString = serialiseArgumentDictionary(dict)
        } else {
            argumentsString = "{}"
        }

        return ToolCall(id: id, toolName: name, arguments: argumentsString)
    }

    /// Serialise an already-parsed arguments dictionary to a JSON string,
    /// normalising Ollama builds that emit structured `arguments` instead of
    /// the documented stringified form. Falls back to `"{}"` when
    /// serialisation fails so ``ToolCall/arguments`` always contains valid
    /// JSON the registry can decode.
    static func serialiseArgumentDictionary(_ dict: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            Log.inference.warning(
                "OllamaPayloadParser: tool arguments dictionary serialised to non-UTF8 bytes — substituting empty object."
            )
            return "{}"
        } catch {
            Log.inference.warning(
                "OllamaPayloadParser: failed to serialise parsed tool arguments — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return "{}"
        }
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
/// Thin shim retained for the existing `OllamaBackendTests` references
/// (`OllamaPayloadHandler()` direct instantiation). New call sites use
/// ``CloudPayloadHandler/ollama`` directly. Phase 2 deletes this shim when
/// the dedicated tests migrate onto the unified contract suite.
struct OllamaPayloadHandler: SSEPayloadHandler {
    private let inner: CloudPayloadHandler = .ollama

    init() {}

    func extractToken(from payload: String) -> String? {
        inner.extractToken(from: payload)
    }

    func extractEvents(from payload: String) -> [GenerationEvent] {
        inner.extractEvents(from: payload)
    }

    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        inner.extractUsage(from: payload)
    }

    func isStreamEnd(_ payload: String) -> Bool {
        inner.isStreamEnd(payload)
    }

    func extractStreamError(from payload: String) -> Error? {
        inner.extractStreamError(from: payload)
    }
}
#endif
