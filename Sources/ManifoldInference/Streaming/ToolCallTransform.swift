/// A single tool-call dialect: an open/close marker pair plus a body parser.
///
/// Family targets (`ManifoldMLX`, `ManifoldLlama`) supply these — the open and
/// close delimiters their model dialect uses, and a `@Sendable` closure that
/// turns the buffered body text into a `ToolCall` (or `nil` to drop). Keeping
/// `parseBody` as an injected closure is what lets the dialect-specific JSON /
/// Gemma-4 brace parsing stay in the family targets while the scanning core
/// stays in `ManifoldInference`, free of MLX/Llama deps and free of `try?`.
public struct ToolCallMarker: Sendable {
    /// Delimiter that opens a tool-call block (e.g. `<tool_call>`, `<|tool_call>`).
    public let open: String
    /// Delimiter that closes the block (e.g. `</tool_call>`, `<|end_of_turn>`).
    public let close: String
    /// Turns the buffered body between `open` and `close` into a `ToolCall`,
    /// or returns `nil` to drop a malformed call.
    public let parseBody: @Sendable (String) -> ToolCall?

    public init(
        open: String,
        close: String,
        parseBody: @escaping @Sendable (String) -> ToolCall?
    ) {
        self.open = open
        self.close = close
        self.parseBody = parseBody
    }
}

/// Stream transform that extracts tool calls from a token stream.
///
/// Drop-in replacement for both the former `MLXToolCallParser` (single
/// `<tool_call>` dialect) and `LlamaToolCallParser` (two competing dialects:
/// Gemma-4 native `<|tool_call>`…`<|end_of_turn>` and JSON
/// `<tool_call>`…`</tool_call>`). The N-candidate, earliest-open-wins selection
/// that used to live by hand in `LlamaToolCallParser` now lives here once.
///
/// - Outside a tool block, text is emitted as `.token`.
/// - On the earliest matching open marker (ties broken by array order, so a
///   caller that lists Gemma-4 before JSON keeps Llama's historical
///   preference), the parser switches into the block.
/// - Inside a block, body text is buffered and suppressed from `.token`.
/// - On the matching close, `marker.parseBody(body)` runs; a non-nil result
///   emits `.toolCall`, and `nil` silently drops the call (matching both
///   legacy parsers).
/// - Partial open/close markers straddling a chunk boundary are held back via
///   the shared ``overlap`` primitives — the open-tag holdback is the max
///   overlap across *all* candidate opens.
///
/// As a ``StreamTransform`` it re-scans only `.token` payloads; all other event
/// cases pass through untouched.
public struct ToolCallTransform: StreamTransform {
    public let markers: [ToolCallMarker]

    private var buffer = ""
    /// Index into `markers` of the dialect whose open tag is currently active,
    /// or `nil` when not inside a tool-call block.
    private var activeMarker: Int?
    /// Body text buffered since the active open tag.
    private var bodyBuffer = ""

    public init(markers: [ToolCallMarker]) {
        self.markers = markers
    }

    public mutating func process(_ events: [GenerationEvent]) -> [GenerationEvent] {
        var out: [GenerationEvent] = []
        for event in events {
            if case .token(let text) = event {
                out += scan(text)
            } else {
                out.append(event)
            }
        }
        return out
    }

    private var openMarkers: [String] { markers.map(\.open) }

    private mutating func scan(_ chunk: String) -> [GenerationEvent] {
        buffer += chunk
        var events: [GenerationEvent] = []

        while true {
            if let active = activeMarker {
                // Inside a block: scan for this dialect's close tag.
                let closeTag = markers[active].close
                if let range = buffer.range(of: closeTag) {
                    bodyBuffer += String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    if let call = markers[active].parseBody(bodyBuffer) {
                        events.append(.toolCall(call))
                    }
                    bodyBuffer = ""
                    activeMarker = nil
                } else {
                    // No close yet: drain everything but a partial close suffix
                    // into the body buffer and stop scanning until more arrives.
                    let holdLen = overlap(buffer, closeTag)
                    if buffer.count > holdLen {
                        bodyBuffer += String(buffer.prefix(buffer.count - holdLen))
                        buffer = holdLen > 0 ? String(buffer.suffix(holdLen)) : ""
                    }
                    break
                }
            } else {
                // Outside a block: find the earliest of all candidate open tags.
                // Ties (same lowerBound) resolve to the first matching marker in
                // declaration order, preserving Llama's Gemma-4-before-JSON rule.
                var chosen: (index: Int, range: Range<String.Index>)?
                for (index, marker) in markers.enumerated() {
                    if let range = buffer.range(of: marker.open) {
                        if let current = chosen {
                            if range.lowerBound < current.range.lowerBound {
                                chosen = (index, range)
                            }
                        } else {
                            chosen = (index, range)
                        }
                    }
                }

                if let (index, range) = chosen {
                    let before = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    if !before.isEmpty {
                        events.append(.token(before))
                    }
                    activeMarker = index
                } else {
                    break
                }
            }
        }

        // Hold back a partial open-tag suffix when not inside a block. The
        // holdback is the max overlap across ALL candidate opens so a partial
        // form of any dialect's open tag is never emitted as visible text.
        if activeMarker == nil {
            let holdLen = maxOverlap(buffer, openMarkers)
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
    /// Remaining visible text outside a block is emitted as `.token`. An
    /// incomplete (unclosed) tool-call block is discarded — partial body text
    /// cannot produce a valid `ToolCall` — matching both legacy parsers.
    public mutating func finalize() -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        if activeMarker == nil, !buffer.isEmpty {
            events.append(.token(buffer))
        }
        buffer = ""
        bodyBuffer = ""
        activeMarker = nil
        return events
    }
}
