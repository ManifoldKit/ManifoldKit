#if MLX
import Foundation
import ManifoldInference

/// MLX tool-call dialect for ``ToolCallTransform``.
///
/// Replaces the former `MLXToolCallParser`: the scanning / holdback / chunk
/// safety now lives once in `ToolCallTransform`, and only the MLX-specific
/// delimiters and JSON body parsing stay here, injected as a `@Sendable`
/// closure.
///
/// MLX models (Qwen 2.5 / Qwen 3 format) wrap tool calls in
/// `<tool_call>` / `</tool_call>` with a `{"name":…,"arguments":…}` JSON body.
enum MLXToolMarkers {

    private static let openTag  = "<tool_call>"
    private static let closeTag = "</tool_call>"

    /// The single-dialect marker set MLX hands to a `ToolCallTransform`.
    static func markers() -> [ToolCallMarker] {
        [
            ToolCallMarker(open: openTag, close: closeTag) { body in
                parseToolCall(body)
            }
        ]
    }

    /// Attempts to parse a buffered `<tool_call>` body into a `ToolCall`.
    ///
    /// Expects `{"name":"…","arguments":{…}}`. The `arguments` object is
    /// re-serialised to a JSON string so `ToolCall.arguments` always carries a
    /// valid JSON string regardless of how the model formatted it. Moved
    /// verbatim from `MLXToolCallParser.parseToolCall` — the `try?
    /// JSONSerialization` idiom here is audit-approved (decoding at a trust
    /// boundary).
    private static func parseToolCall(_ json: String) -> ToolCall? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty
        else {
            return nil
        }

        // `arguments` may be a pre-parsed dictionary or (rarely) a JSON string.
        let argumentsString: String
        if let argsDict = obj["arguments"] as? [String: Any] {
            if let serialised = try? JSONSerialization.data(withJSONObject: argsDict),
               let str = String(data: serialised, encoding: .utf8) {
                argumentsString = str
            } else {
                argumentsString = "{}"
            }
        } else if let argsString = obj["arguments"] as? String {
            argumentsString = argsString
        } else {
            argumentsString = "{}"
        }

        let id = "mlx-\(name)-\(UUID().uuidString.prefix(8))"
        return ToolCall(id: id, toolName: name, arguments: argumentsString)
    }
}
#endif
