/// A single tool-call dialect: an open/close marker pair plus a body parser.
///
/// Family targets (`ManifoldMLX`, `ManifoldLlama`) supply these — the open and
/// close delimiters their model dialect uses, and a `@Sendable` closure that
/// turns the buffered body text into a `ToolCall` (or `nil` to drop). Keeping
/// `parseBody` as an injected closure is what lets the dialect-specific JSON /
/// Gemma-4 brace parsing stay in the family targets while the scanning core
/// stays in `ManifoldInference`, free of MLX/Llama deps and free of `try?`.
///
/// Two additive shapes (#1982) extend the original open/close/single-call form
/// without breaking it:
///
/// - **EOS-keyed close (`closesAtEnd`).** Some dialects — notably Mistral's
///   `[TOOL_CALLS]` — emit a bare JSON payload right after a literal open token
///   with NO closing delimiter; the block ends at end-of-generation. Such a
///   marker buffers its body to the stream end and is parsed in `finalize()`
///   instead of on a close tag. `close` is irrelevant for these markers (pass
///   `""`); the scanner never searches for it.
/// - **Multi-call body (`parseBodyMulti`).** A single block can carry MORE than
///   one call (Mistral's payload is a JSON *array*). When provided, the
///   transform prefers it and emits one `.toolCall` per element.
public struct ToolCallMarker: Sendable {
    /// Delimiter that opens a tool-call block (e.g. `<tool_call>`, `<|tool_call>`).
    public let open: String
    /// Delimiter that closes the block (e.g. `</tool_call>`, `<|end_of_turn>`).
    /// Irrelevant when ``closesAtEnd`` is `true` (the block closes at EOS).
    public let close: String
    /// Turns the buffered body between `open` and `close` into a `ToolCall`,
    /// or returns `nil` to drop a malformed call.
    public let parseBody: @Sendable (String) -> ToolCall?
    /// When `true`, the block has no closing delimiter — it ends at
    /// end-of-generation. The scanner buffers the whole body (subject to the
    /// runaway byte cap) and parses it in `finalize()`. Defaults to `false`,
    /// preserving the historical close-tag-keyed behavior (#1982).
    public let closesAtEnd: Bool
    /// Optional multi-call parser: turns the buffered body into ZERO or more
    /// `ToolCall`s (e.g. a JSON array of calls). When non-nil the transform
    /// prefers it over ``parseBody`` and emits one `.toolCall` per element.
    /// Defaults to `nil`, leaving single-call dialects unchanged (#1982).
    public let parseBodyMulti: (@Sendable (String) -> [ToolCall])?

    /// Original single-call, close-tag-keyed dialect. Unchanged: `closesAtEnd`
    /// is `false` and there is no multi-call parser.
    public init(
        open: String,
        close: String,
        parseBody: @escaping @Sendable (String) -> ToolCall?
    ) {
        self.open = open
        self.close = close
        self.parseBody = parseBody
        self.closesAtEnd = false
        self.parseBodyMulti = nil
    }

    /// Multi-call / EOS-keyed dialect (Mistral `[TOOL_CALLS]` shape). The body
    /// is parsed by `parseBodyMulti` and may yield multiple calls; `close` may
    /// be omitted when `closesAtEnd` is `true`. `parseBody` is stubbed to return
    /// `nil` so the stored property stays non-optional — the transform consults
    /// `parseBodyMulti` first regardless.
    public init(
        open: String,
        close: String = "",
        closesAtEnd: Bool = false,
        parseBodyMulti: @escaping @Sendable (String) -> [ToolCall]
    ) {
        self.open = open
        self.close = close
        self.parseBody = { _ in nil }
        self.closesAtEnd = closesAtEnd
        self.parseBodyMulti = parseBodyMulti
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
/// - On the matching close, the body is parsed (`marker.parseBodyMulti` when
///   present, else `marker.parseBody`); each resulting call emits a `.toolCall`.
///   An empty result no longer vanishes silently — it emits a non-fatal
///   `.toolCallParseFailed(rawBody:)` diagnostic carrying the buffered body so
///   hosts can distinguish a broken tool call from no tool call (#1857).
/// - A `closesAtEnd` marker (#1982, Mistral `[TOOL_CALLS]`) has NO close tag:
///   the scanner drains the whole body to the stream end and `finalize()` parses
///   it, emitting `.toolCall`s (or `.toolCallParseFailed`) — see `finalize()`.
/// - On the body-size cap or an unterminated block at `finalize()`, the partial
///   body is discarded by default. Constructing the transform with
///   `surfaceTruncatedToolBody: true` instead emits a non-fatal
///   `.toolCallTruncated(rawBody:)` diagnostic so a mid-stream truncation is
///   observable (#1858, opt-in — default behavior is unchanged).
/// - Partial open/close markers straddling a chunk boundary are held back via
///   the shared `overlap` primitives — the open-tag holdback is the max
///   overlap across *all* candidate opens.
///
/// As a ``StreamTransform`` it re-scans only `.token` payloads; all other event
/// cases pass through untouched.
public struct ToolCallTransform: StreamTransform {
    public let markers: [ToolCallMarker]

    /// Upper bound (in UTF-8 bytes) on a single buffered tool-call body before
    /// the active block is abandoned as malformed. A well-formed tool call is a
    /// small JSON object; an unbounded body means we never saw a close tag (a
    /// truncated, runaway, or adversarial stream). Without this cap the body
    /// buffer grows for the whole remaining stream and is then handed to an
    /// O(n)+ `parseBody`. 256 KB is far above any legitimate call and well
    /// below a memory-pressure threat.
    private static let maxBodyBytes = 256 * 1024

    /// Opt-in: surface the buffered body of an unterminated tool-call block as a
    /// non-fatal `.toolCallTruncated(rawBody:)` diagnostic instead of discarding
    /// it. Defaults to `false` so the historical silent-discard behavior is
    /// unchanged (#1858). Applies both to the `finalize()` flush of an open
    /// block and to the body-size-cap drop of a runaway unclosed body.
    public let surfaceTruncatedToolBody: Bool

    private var buffer = ""
    /// Index into `markers` of the dialect whose open tag is currently active,
    /// or `nil` when not inside a tool-call block.
    private var activeMarker: Int?
    /// Body text buffered since the active open tag.
    private var bodyBuffer = ""

    public init(markers: [ToolCallMarker], surfaceTruncatedToolBody: Bool = false) {
        self.markers = markers
        self.surfaceTruncatedToolBody = surfaceTruncatedToolBody
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

    /// Parse a completed body and turn it into emit events. Prefers the marker's
    /// multi-call parser (#1982 — a single block may carry several calls, e.g. a
    /// JSON array) and falls back to the single-call `parseBody`. An empty result
    /// surfaces the `.toolCallParseFailed(rawBody:)` diagnostic, preserving #1857.
    private func emitEvents(for marker: ToolCallMarker, body: String) -> [GenerationEvent] {
        let calls = marker.parseBodyMulti?(body) ?? marker.parseBody(body).map { [$0] } ?? []
        if calls.isEmpty {
            return [.toolCallParseFailed(rawBody: body)]
        }
        return calls.map { .toolCall($0) }
    }

    private mutating func scan(_ chunk: String) -> [GenerationEvent] {
        buffer += chunk
        var events: [GenerationEvent] = []

        while true {
            if let active = activeMarker {
                // A closesAtEnd marker (#1982) has no close tag: drain everything
                // into the body and wait for more tokens. `finalize()` parses the
                // buffered body. Never call `range(of: "")` for such a marker —
                // its `close` is empty/irrelevant.
                if markers[active].closesAtEnd {
                    bodyBuffer += buffer
                    buffer = ""
                    if bodyBuffer.utf8.count > Self.maxBodyBytes {
                        Log.inference.warning(
                            "ToolCallTransform: dropping closesAtEnd tool-call body exceeding \(Self.maxBodyBytes)-byte cap"
                        )
                        if surfaceTruncatedToolBody {
                            events.append(.toolCallTruncated(rawBody: bodyBuffer))
                        }
                        bodyBuffer = ""
                        activeMarker = nil
                        continue
                    }
                    break
                }
                // Inside a block: scan for this dialect's close tag.
                let closeTag = markers[active].close
                if let range = buffer.range(of: closeTag) {
                    bodyBuffer += String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    events += emitEvents(for: markers[active], body: bodyBuffer)
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
                    // Guard against an unbounded body: a close tag that never
                    // arrives would otherwise buffer the entire rest of the
                    // stream. Drop the malformed call and resume scanning the
                    // held-back buffer for a fresh open tag.
                    if bodyBuffer.utf8.count > Self.maxBodyBytes {
                        Log.inference.warning(
                            "ToolCallTransform: dropping tool-call body exceeding \(Self.maxBodyBytes)-byte cap without a close tag"
                        )
                        if surfaceTruncatedToolBody {
                            events.append(.toolCallTruncated(rawBody: bodyBuffer))
                        }
                        bodyBuffer = ""
                        activeMarker = nil
                        continue
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
    /// Remaining visible text outside a block is emitted as `.token`.
    ///
    /// A `closesAtEnd` marker (#1982) is the EXPECTED close path, not a
    /// truncation: its body has no close tag, so the buffered body is parsed here
    /// and `.toolCall`s (or `.toolCallParseFailed`) are emitted — independent of
    /// `surfaceTruncatedToolBody`, which governs only the truncation of genuine
    /// close-tag dialects.
    ///
    /// An incomplete (unclosed) close-tag tool-call block is discarded by
    /// default — partial body text cannot produce a valid `ToolCall` — matching
    /// both legacy parsers. When the transform was constructed with
    /// `surfaceTruncatedToolBody: true`, the partial body is instead surfaced as
    /// a non-fatal `.toolCallTruncated(rawBody:)` diagnostic so a mid-tool-call
    /// stream truncation is observable (#1858).
    public mutating func finalize() -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        if activeMarker == nil {
            if !buffer.isEmpty {
                events.append(.token(buffer))
            }
        } else if markers[activeMarker!].closesAtEnd {
            // EOS-keyed close: this is the normal terminus for the block, not a
            // truncation. Fold any held-back buffer into the body and parse it.
            let body = bodyBuffer + buffer
            events += emitEvents(for: markers[activeMarker!], body: body)
        } else if surfaceTruncatedToolBody {
            // Inside an unterminated block: the held-back `buffer` is a partial
            // close suffix that still belongs to the body, so fold it in before
            // surfacing. Default behavior (flag off) discards silently.
            let partial = bodyBuffer + buffer
            if !partial.isEmpty {
                events.append(.toolCallTruncated(rawBody: partial))
            }
        }
        buffer = ""
        bodyBuffer = ""
        activeMarker = nil
        return events
    }
}
