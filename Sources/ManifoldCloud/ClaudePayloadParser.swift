#if CloudSaaS
import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

/// Stateless parser for Anthropic Messages API SSE payloads.
enum ClaudePayloadParser {
    struct ToolUseBlockStart {
        let index: Int
        let id: String
        let name: String
    }

    struct InputJSONDelta {
        let index: Int
        let partialJSON: String
    }

    struct WholeToolUseBlock {
        let id: String
        let name: String
        let serializedInput: String
    }

    static func parseEventType(from json: String) -> String? {
        guard let parsed = parseObject(json) else { return nil }
        return parsed["type"] as? String
    }

    static func parseToolUseBlockStart(from json: String) -> ToolUseBlockStart? {
        guard let parsed = parseObject(json),
              parsed["type"] as? String == "content_block_start",
              let index = parsed["index"] as? Int,
              let block = parsed["content_block"] as? [String: Any],
              block["type"] as? String == "tool_use",
              let id = block["id"] as? String, !id.isEmpty,
              let name = block["name"] as? String, !name.isEmpty else {
            return nil
        }
        return ToolUseBlockStart(index: index, id: id, name: name)
    }

    static func parseInputJSONDelta(from json: String) -> InputJSONDelta? {
        guard let parsed = parseObject(json),
              parsed["type"] as? String == "content_block_delta",
              let index = parsed["index"] as? Int,
              let delta = parsed["delta"] as? [String: Any],
              delta["type"] as? String == "input_json_delta",
              let partial = delta["partial_json"] as? String else {
            return nil
        }
        return InputJSONDelta(index: index, partialJSON: partial)
    }

    static func parseContentBlockIndex(from json: String) -> Int? {
        parseObject(json)?["index"] as? Int
    }

    static func parseWholeMessageToolUseBlocks(from json: String) -> [WholeToolUseBlock]? {
        guard let parsed = parseObject(json) else { return nil }
        guard parsed["type"] as? String == "message",
              let content = parsed["content"] as? [[String: Any]] else {
            return nil
        }
        var result: [WholeToolUseBlock] = []
        for block in content {
            guard block["type"] as? String == "tool_use",
                  let id = block["id"] as? String, !id.isEmpty,
                  let name = block["name"] as? String, !name.isEmpty else {
                continue
            }
            let input = block["input"] ?? [String: Any]()
            result.append(WholeToolUseBlock(id: id, name: name, serializedInput: serializeInputObject(input)))
        }
        return result
    }

    static func parseThinkingBlockStartSignature(from json: String) -> String? {
        guard let parsed = parseObject(json),
              parsed["type"] as? String == "content_block_start",
              let block = parsed["content_block"] as? [String: Any],
              block["type"] as? String == "thinking",
              let signature = block["signature"] as? String,
              !signature.isEmpty else {
            return nil
        }
        return signature
    }

    static func parseSignatureDelta(from json: String) -> String? {
        guard let parsed = parseObject(json),
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              delta["type"] as? String == "signature_delta",
              let signature = delta["signature"] as? String,
              !signature.isEmpty else {
            return nil
        }
        return signature
    }

    static func parseThinkingDelta(from json: String) -> String? {
        guard let parsed = parseObject(json),
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              delta["type"] as? String == "thinking_delta",
              let thinking = delta["thinking"] as? String else {
            return nil
        }
        return thinking
    }

    static func parseToken(from json: String) -> String? {
        guard let parsed = parseObject(json),
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    static func parseIsStreamEnd(_ json: String) -> Bool {
        guard let type = parseObject(json)?["type"] as? String else { return false }
        return type == "message_stop"
    }

    struct CacheUsage {
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int
    }

    static func parseUsage(from json: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let parsed = parseObject(json),
              let type = parsed["type"] as? String else {
            return nil
        }

        switch type {
        case "message_start":
            guard let message = parsed["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let inputTokens = usage["input_tokens"] as? Int else {
                return nil
            }
            return (promptTokens: inputTokens, completionTokens: nil)
        case "message_delta":
            guard let usage = parsed["usage"] as? [String: Any],
                  let outputTokens = usage["output_tokens"] as? Int else {
                return nil
            }
            return (promptTokens: nil, completionTokens: outputTokens)
        default:
            return nil
        }
    }

    /// Parses Anthropic prompt-cache token counts from a `message_start` payload.
    ///
    /// Both fields default to 0 when absent — an absent field means no cache
    /// activity occurred, not a parse failure, so we treat them as optional
    /// with a zero fallback rather than nil-gating the whole result.
    static func parseCacheUsage(from json: String) -> CacheUsage? {
        guard let parsed = parseObject(json),
              parsed["type"] as? String == "message_start",
              let message = parsed["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }
        let creation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let read = usage["cache_read_input_tokens"] as? Int ?? 0
        // Only materialise a CacheUsage when there is actual cache activity to
        // report — avoids a debug log on every non-cached turn.
        guard creation > 0 || read > 0 else { return nil }
        return CacheUsage(cacheCreationInputTokens: creation, cacheReadInputTokens: read)
    }

    static func parseStreamError(from json: String) -> CloudBackendError? {
        guard let parsed = parseObject(json),
              parsed["type"] as? String == "error",
              let error = parsed["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return .parseError(message)
    }

    private static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func serializeInputObject(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            return "{}"
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            Log.inference.warning(
                "ClaudePayloadParser: tool_use.input could not be re-serialised — falling back to empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return "{}"
        }
    }
}

struct ClaudePayloadHandler: SSEPayloadHandler {
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
#endif
