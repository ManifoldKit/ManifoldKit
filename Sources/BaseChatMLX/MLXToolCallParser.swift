#if MLX
import Foundation
import BaseChatInference

/// Stateful, chunk-safe parser that extracts tool calls from MLX token streams.
///
/// Analogous to `ThinkingParser`, this struct watches the streamed token
/// output for `<tool_call>` / `</tool_call>` delimiter pairs, buffers the
/// JSON payload between them, and emits a `GenerationEvent.toolCall(_:)`
/// event when the close tag arrives.
///
/// ## Behaviour
///
/// - Text **outside** `<tool_call>…</tool_call>` blocks is emitted as
///   `.token` events so visible preamble text is preserved.
/// - Text **inside** a tool-call block is buffered and suppressed from
///   the `.token` stream.
/// - On the close tag, the buffered JSON is parsed: a valid
///   `{"name":…,"arguments":…}` object produces a `.toolCall` event;
///   invalid JSON is silently dropped.
/// - Multiple tool calls in a single response are handled: the parser
///   resets after each close tag and continues scanning.
/// - Partial tags split across chunks are held back until resolved, using
///   the same prefix-hold strategy as `ThinkingParser`.
///
/// ## Usage
///
/// ```swift
/// var parser = MLXToolCallParser()
/// for chunk in tokenStream {
///     for event in parser.process(chunk) { … }
/// }
/// for event in parser.finalize() { … }
/// ```
package struct MLXToolCallParser: Sendable {

    // MARK: - Tag constants (Qwen 2.5 / Qwen 3 format)

    private static let openTag  = "<tool_call>"
    private static let closeTag = "</tool_call>"

    // MARK: - State

    /// Accumulates raw text between chunk calls.
    private var buffer = ""

    /// When `true`, the parser has consumed an open tag and is buffering JSON.
    private var insideToolCall = false

    /// JSON bytes buffered since the last open tag.
    private var jsonBuffer = ""

    package init() {}

    // MARK: - Processing

    /// Process a chunk of streamed text.
    ///
    /// - Parameter chunk: Raw token text as emitted by the MLX generation loop.
    /// - Returns: A (possibly empty) array of `GenerationEvent` values derived
    ///   from the chunk. Outside tool-call blocks these are `.token` events;
    ///   on a complete `</tool_call>` they include a `.toolCall` event.
    package mutating func process(_ chunk: String) -> [GenerationEvent] {
        buffer += chunk
        var events: [GenerationEvent] = []

        while true {
            let tag = insideToolCall ? Self.closeTag : Self.openTag

            if let range = buffer.range(of: tag) {
                let before = String(buffer[..<range.lowerBound])
                buffer = String(buffer[range.upperBound...])

                if insideToolCall {
                    // Closing tag: accumulate final JSON fragment and emit tool call
                    jsonBuffer += before
                    if let toolCallEvent = parseToolCall(jsonBuffer) {
                        events.append(toolCallEvent)
                    }
                    jsonBuffer = ""
                    insideToolCall = false
                } else {
                    // Opening tag: emit any preceding visible text, then switch modes
                    if !before.isEmpty {
                        events.append(.token(before))
                    }
                    insideToolCall = true
                }
            } else {
                break
            }
        }

        // Hold back the longest suffix that could be a partial prefix of the
        // next delimiter, preventing premature emission of tag fragments.
        let nextTag = insideToolCall ? Self.closeTag : Self.openTag
        let maxCheck = min(buffer.count, nextTag.count - 1)
        var holdLength = 0
        for length in stride(from: maxCheck, through: 1, by: -1) {
            if nextTag.hasPrefix(String(buffer.suffix(length))) {
                holdLength = length
                break
            }
        }

        if buffer.count > holdLength {
            let confirmed = String(buffer.prefix(buffer.count - holdLength))
            buffer = holdLength > 0 ? String(buffer.suffix(holdLength)) : ""
            if !confirmed.isEmpty {
                if insideToolCall {
                    // Accumulate into JSON buffer; do not emit
                    jsonBuffer += confirmed
                } else {
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
    ///
    /// - Returns: Any remaining `.token` events, or an empty array when the
    ///   buffer is empty or only contains a dangling tool-call fragment.
    package mutating func finalize() -> [GenerationEvent] {
        guard !buffer.isEmpty || !jsonBuffer.isEmpty else { return [] }
        var events: [GenerationEvent] = []
        if !insideToolCall && !buffer.isEmpty {
            events.append(.token(buffer))
        }
        // Discard partial tool-call state — incomplete JSON cannot be used.
        buffer = ""
        jsonBuffer = ""
        insideToolCall = false
        return events
    }

    // MARK: - JSON Parsing

    /// Attempts to parse buffered JSON into a `ToolCall`.
    ///
    /// Expects `{"name":"…","arguments":{…}}`. The `arguments` object is
    /// re-serialised to a JSON string so `ToolCall.arguments` always carries
    /// a valid JSON string regardless of how the model formatted it.
    ///
    /// - Parameter json: The raw string between `<tool_call>` and `</tool_call>`.
    /// - Returns: A `.toolCall` event on success, or `nil` when parsing fails.
    private func parseToolCall(_ json: String) -> GenerationEvent? {
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
        return .toolCall(ToolCall(id: id, toolName: name, arguments: argumentsString))
    }
}
#endif
