#if Llama
import Foundation
import BaseChatInference

/// Stateful, chunk-safe parser that extracts tool calls from Gemma 4 GGUF
/// token streams produced by `LlamaGenerationDriver`.
///
/// ## Token format
///
/// Gemma 4 IT GGUF models emit tool invocations using special tokens:
///
/// ```
/// <|tool_call>
/// call:function_name{param1:<|"|>value<|"|>}
/// <|end_of_turn>
/// ```
///
/// `<|"|>` is Gemma 4's string-quoting special token; it is substituted with
/// `"` before the call body is interpreted as a JSON-like object.
///
/// ## Fallback format
///
/// For tool-calling fine-tunes that deviate from the Gemma 4 native format
/// and instead emit a JSON object between `<tool_call>` / `</tool_call>` tags
/// (as used by Qwen and other models), the parser also accepts:
///
/// ```
/// <tool_call>
/// {"name": "function_name", "arguments": {"param": "value"}}
/// </tool_call>
/// ```
///
/// ## Chunk safety
///
/// Tags that straddle chunk boundaries are held back until the boundary is
/// resolved, using the same prefix-hold strategy as `MLXToolCallParser` and
/// `ThinkingParser`.
///
/// ## Usage
///
/// ```swift
/// var parser = LlamaToolCallParser()
/// for chunk in tokenStream {
///     for event in parser.process(chunk) { … }
/// }
/// for event in parser.finalize() { … }
/// ```
struct LlamaToolCallParser: Sendable {

    // MARK: - Tag constants

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

    // MARK: - State

    private var buffer = ""
    private var insideToolCall = false
    private var callBuffer = ""
    /// `true` when the open tag was the Gemma 4 native `<|tool_call>` form.
    private var usingGemma4Format = false

    // MARK: - Processing

    /// Process a chunk of streamed text.
    ///
    /// - Parameter chunk: Raw token text as emitted by the generation loop.
    /// - Returns: A (possibly empty) array of ``GenerationEvent`` values.
    ///   Text outside tool-call delimiters is emitted as `.token` events;
    ///   a complete call produces a `.toolCall` event.
    mutating func process(_ chunk: String) -> [GenerationEvent] {
        buffer += chunk
        var events: [GenerationEvent] = []

        while true {
            if insideToolCall {
                let closeTag = usingGemma4Format ? Self.gemma4EndTurn : Self.jsonCloseTag
                if let range = buffer.range(of: closeTag) {
                    callBuffer += String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    if let event = parseCallBuffer(callBuffer) {
                        events.append(event)
                    }
                    callBuffer = ""
                    insideToolCall = false
                } else {
                    // Hold back partial close-tag suffix.
                    let maxHold = min(buffer.count, closeTag.count - 1)
                    var holdLen = 0
                    for l in stride(from: maxHold, through: 1, by: -1) {
                        if closeTag.hasPrefix(String(buffer.suffix(l))) {
                            holdLen = l
                            break
                        }
                    }
                    if buffer.count > holdLen {
                        callBuffer += String(buffer.prefix(buffer.count - holdLen))
                        buffer = holdLen > 0 ? String(buffer.suffix(holdLen)) : ""
                    }
                    break
                }
            } else {
                // Find the earliest of the two open-tag candidates.
                let g4Range   = buffer.range(of: Self.gemma4OpenTag)
                let jsonRange = buffer.range(of: Self.jsonOpenTag)

                let (chosenRange, isGemma4): (Range<String.Index>?, Bool)
                switch (g4Range, jsonRange) {
                case let (g4?, json?) where g4.lowerBound <= json.lowerBound:
                    (chosenRange, isGemma4) = (g4, true)
                case let (g4?, json?) where g4.lowerBound > json.lowerBound:
                    (chosenRange, isGemma4) = (json, false)
                case (let g4?, nil):
                    (chosenRange, isGemma4) = (g4, true)
                case (nil, let json?):
                    (chosenRange, isGemma4) = (json, false)
                default:
                    (chosenRange, isGemma4) = (nil, false)
                }

                if let range = chosenRange {
                    let before = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    if !before.isEmpty {
                        events.append(.token(before))
                    }
                    insideToolCall = true
                    usingGemma4Format = isGemma4
                } else {
                    break
                }
            }
        }

        // Hold back partial open-tag suffix when not inside a call.
        if !insideToolCall {
            let candidates = [Self.gemma4OpenTag, Self.jsonOpenTag]
            let maxTagLen  = candidates.map(\.count).max()! - 1
            let maxCheck   = min(buffer.count, maxTagLen)
            var holdLen    = 0
            for candidate in candidates {
                for l in stride(from: maxCheck, through: 1, by: -1) {
                    if candidate.hasPrefix(String(buffer.suffix(l))) {
                        holdLen = max(holdLen, l)
                    }
                }
            }
            if buffer.count > holdLen {
                let confirmed = String(buffer.prefix(buffer.count - holdLen))
                buffer = holdLen > 0 ? String(buffer.suffix(holdLen)) : ""
                if !confirmed.isEmpty {
                    events.append(.token(confirmed))
                }
            }
        }

        return events
    }

    /// Flush the held-back buffer at stream end.
    ///
    /// Call once after the generation loop finishes to emit any remaining
    /// visible text. An incomplete (unclosed) tool-call block is discarded —
    /// partial JSON cannot produce a valid `ToolCall`.
    mutating func finalize() -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        if !insideToolCall && !buffer.isEmpty {
            events.append(.token(buffer))
        }
        buffer = ""
        callBuffer = ""
        insideToolCall = false
        return events
    }

    // MARK: - Call body parsing

    private func parseCallBuffer(_ raw: String) -> GenerationEvent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("call:") {
            return parseGemma4NativeCall(trimmed)
        }
        return parseJSONCall(trimmed)
    }

    /// Parses Gemma 4 native format: `call:name{param1:<|"|>val<|"|>,param2:42}`.
    ///
    /// The brace body uses **unquoted JSON-like keys** with values that are
    /// either Gemma 4's `<|"|>...<|"|>` quoted-string token, or a bare
    /// numeric / boolean / null literal. JSON itself requires quoted keys,
    /// so the body cannot be handed to `JSONSerialization` directly — earlier
    /// versions did, with the result that *every* native tool call fell back
    /// to `arguments == "{}"`. The dedicated tokenizer below quotes keys and
    /// (when needed) values, then round-trips through `JSONSerialization` for
    /// canonicalisation.
    private func parseGemma4NativeCall(_ raw: String) -> GenerationEvent? {
        let body = String(raw.dropFirst("call:".count))
        let substituted = body.replacingOccurrences(of: Self.gemma4QuoteToken, with: "\"")

        guard let braceIndex = substituted.firstIndex(of: "{") else { return nil }
        let name = String(substituted[..<braceIndex]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let braceBody = String(substituted[braceIndex...])
        let argsString = parseGemma4Arguments(braceBody) ?? "{}"
        let id = "llama-\(name)-\(UUID().uuidString.prefix(8))"
        return .toolCall(ToolCall(id: id, toolName: name, arguments: argsString))
    }

    /// Tokenises Gemma 4's `{key:value,key:value}` brace body into a JSON object.
    ///
    /// Returns the canonical JSON string on success, or `nil` on parse failure
    /// so the caller can fall back to `"{}"` (the same behaviour the JSON
    /// fallback path uses for malformed call bodies).
    private func parseGemma4Arguments(_ braceBody: String) -> String? {
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

    /// Parses JSON fallback format: `{"name":"...","arguments":{...}}`.
    private func parseJSONCall(_ json: String) -> GenerationEvent? {
        guard let data = json.data(using: .utf8),
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
        return .toolCall(ToolCall(id: id, toolName: name, arguments: argsString))
    }

}
#endif
