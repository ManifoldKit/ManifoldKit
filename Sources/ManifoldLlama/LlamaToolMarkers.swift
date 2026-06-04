#if Llama
import Foundation
import ManifoldInference

/// Llama tool-call dialects for ``ToolCallTransform``.
///
/// Replaces the former `LlamaToolCallParser`: the scanning, N-candidate
/// earliest-open-wins selection, holdback, and chunk safety now live once in
/// `ToolCallTransform`. Only the two Llama-specific delimiter pairs and their
/// body parsers stay here, injected as `@Sendable` closures.
///
/// Two dialects, in preference order (Gemma-4 native before JSON fallback —
/// `ToolCallTransform` resolves ties by array order, matching the original
/// parser's earliest-of-two behavior):
///
/// 1. **Gemma 4 native** — `<|tool_call>` … `<|end_of_turn>` with a
///    `call:name{key:<|"|>value<|"|>}` brace body.
/// 2. **JSON fallback** — `<tool_call>` … `</tool_call>` with a
///    `{"name":…,"arguments":…}` body (Qwen-style fine-tunes).
enum LlamaToolMarkers {

    /// Gemma 4 native open token.
    static let gemma4OpenTag = "<|tool_call>"
    /// Gemma 4 turn-end token used to close a native tool call.
    static let gemma4EndTurn = "<|end_of_turn>"
    /// Gemma 4 string-quoting token substituted with `"` before parsing.
    static let gemma4QuoteToken = "<|\"|>"

    /// Standard JSON open tag (fallback for non-native tool-call fine-tunes).
    static let jsonOpenTag  = "<tool_call>"
    /// Standard JSON close tag.
    static let jsonCloseTag = "</tool_call>"

    /// The ordered marker set Llama hands to a `ToolCallTransform`.
    /// Gemma-4 first so it wins ties against the JSON fallback.
    static func markers() -> [ToolCallMarker] {
        [
            ToolCallMarker(open: gemma4OpenTag, close: gemma4EndTurn) { body in
                parseCallBuffer(body)
            },
            ToolCallMarker(open: jsonOpenTag, close: jsonCloseTag) { body in
                parseCallBuffer(body)
            }
        ]
    }

    // MARK: - Body dispatch

    /// Dispatches a buffered call body to the Gemma-4 native or JSON parser by
    /// inspecting its prefix — preserving the original
    /// `LlamaToolCallParser.parseCallBuffer` behaviour, which dispatched on the
    /// body shape rather than on which open tag matched. A `call:`-prefixed body
    /// is Gemma-4 native; anything else is treated as JSON.
    private static func parseCallBuffer(_ raw: String) -> ToolCall? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("call:") {
            return parseGemma4NativeCall(trimmed)
        }
        return parseJSONCall(trimmed)
    }

    // MARK: - Gemma 4 native body parsing

    /// Parses Gemma 4 native format: `call:name{param1:<|"|>val<|"|>,param2:42}`.
    ///
    /// The brace body uses **unquoted JSON-like keys** with values that are
    /// either Gemma 4's `<|"|>...<|"|>` quoted-string token, or a bare
    /// numeric / boolean / null literal. JSON itself requires quoted keys, so
    /// the body cannot be handed to `JSONSerialization` directly — the
    /// dedicated tokenizer below quotes keys and (when needed) values, then
    /// round-trips through `JSONSerialization` for canonicalisation.
    private static func parseGemma4NativeCall(_ raw: String) -> ToolCall? {
        // Caller (`parseCallBuffer`) has already trimmed and verified the
        // `call:` prefix.
        let body = String(raw.dropFirst("call:".count))
        let substituted = body.replacingOccurrences(of: gemma4QuoteToken, with: "\"")

        guard let braceIndex = substituted.firstIndex(of: "{") else { return nil }
        let name = String(substituted[..<braceIndex]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let braceBody = String(substituted[braceIndex...])
        let argsString = parseGemma4Arguments(braceBody) ?? "{}"
        let id = "llama-\(name)-\(UUID().uuidString.prefix(8))"
        return ToolCall(id: id, toolName: name, arguments: argsString)
    }

    /// Tokenises Gemma 4's `{key:value,key:value}` brace body into a JSON object.
    ///
    /// Returns the canonical JSON string on success, or `nil` on parse failure
    /// so the caller can fall back to `"{}"` (the same behaviour the JSON
    /// fallback path uses for malformed call bodies).
    private static func parseGemma4Arguments(_ braceBody: String) -> String? {
        var trimmed = braceBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        trimmed.removeFirst()
        trimmed.removeLast()
        let inner = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty {
            return "{}"
        }

        var dict: [String: Any] = [:]
        var idx = inner.startIndex
        let end = inner.endIndex

        while idx < end {
            // Skip whitespace and stray commas between pairs.
            while idx < end, inner[idx].isWhitespace || inner[idx] == "," {
                idx = inner.index(after: idx)
            }
            if idx >= end { break }

            // Read unquoted key up to the next `:`.
            guard let colon = inner[idx...].firstIndex(of: ":") else { return nil }
            let key = inner[idx..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            idx = inner.index(after: colon)

            // Skip whitespace before the value.
            while idx < end, inner[idx].isWhitespace {
                idx = inner.index(after: idx)
            }
            if idx >= end { return nil }

            // Read value: either a quoted string, or a bare literal up to the next comma.
            let value: Any
            if inner[idx] == "\"" {
                // Quoted string: scan for the closing quote, honouring `\"` escapes.
                var cursor = inner.index(after: idx)
                var raw = ""
                var escaped = false
                while cursor < end {
                    let ch = inner[cursor]
                    if escaped {
                        raw.append(ch)
                        escaped = false
                    } else if ch == "\\" {
                        raw.append(ch)
                        escaped = true
                    } else if ch == "\"" {
                        break
                    } else {
                        raw.append(ch)
                    }
                    cursor = inner.index(after: cursor)
                }
                guard cursor < end else { return nil } // unterminated string
                idx = inner.index(after: cursor)
                // Decode JSON escapes via JSONSerialization on a wrapped string.
                if let data = "\"\(raw)\"".data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(
                       with: data, options: [.fragmentsAllowed]) as? String {
                    value = decoded
                } else {
                    value = raw
                }
            } else {
                // Bare literal — number, true, false, or null. Read up to next comma.
                var cursor = idx
                while cursor < end, inner[cursor] != "," {
                    cursor = inner.index(after: cursor)
                }
                let literal = inner[idx..<cursor].trimmingCharacters(in: .whitespaces)
                idx = cursor
                guard !literal.isEmpty else { return nil }
                if literal == "true" {
                    value = true
                } else if literal == "false" {
                    value = false
                } else if literal == "null" {
                    value = NSNull()
                } else if let intVal = Int(literal) {
                    value = intVal
                } else if let dblVal = Double(literal) {
                    value = dblVal
                } else {
                    // Treat as a bare string when the model omits Gemma's quote token.
                    value = literal
                }
            }

            dict[key] = value
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str  = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    // MARK: - JSON fallback body parsing

    /// Parses JSON fallback format: `{"name":"...","arguments":{...}}`.
    private static func parseJSONCall(_ raw: String) -> ToolCall? {
        let json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty
        else { return nil }

        let argsString: String
        if let argsDict = obj["arguments"] as? [String: Any],
           let serialized = try? JSONSerialization.data(withJSONObject: argsDict),
           let str = String(data: serialized, encoding: .utf8) {
            argsString = str
        } else if let rawStr = obj["arguments"] as? String {
            argsString = rawStr
        } else {
            argsString = "{}"
        }

        let id = "llama-\(name)-\(UUID().uuidString.prefix(8))"
        return ToolCall(id: id, toolName: name, arguments: argsString)
    }
}
#endif
