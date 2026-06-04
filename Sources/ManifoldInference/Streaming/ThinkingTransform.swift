/// Stream transform that separates reasoning from visible text.
///
/// Drop-in replacement for the former `ThinkingParser`. Watches a single
/// open/close marker pair (`ThinkingMarkers`) and re-routes text inside a
/// thinking block to `.thinkingToken`, firing `.thinkingComplete` exactly on
/// the depth 1→0 transition. Partial markers straddling a chunk boundary are
/// held back via the shared ``overlap(_:_:)`` primitive.
///
/// As a ``StreamTransform`` it re-scans only `.token` payloads; `.thinkingToken`,
/// `.thinkingComplete`, `.toolCall`, and every other event case pass through
/// untouched. Behavior on a single `.token` chunk is byte-identical to the
/// original `ThinkingParser.process`.
public struct ThinkingTransform: StreamTransform {
    public let markers: ThinkingMarkers
    private var depth = 0
    private var buffer = ""

    public init(markers: ThinkingMarkers = .qwen3) {
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

    /// Single-chunk scan — preserves the exact `ThinkingParser.process` logic.
    private mutating func scan(_ chunk: String) -> [GenerationEvent] {
        buffer += chunk
        var events: [GenerationEvent] = []

        while true {
            let tag = depth > 0 ? markers.close : markers.open

            if let range = buffer.range(of: tag) {
                // Emit everything before the tag as the current mode's event type.
                let before = String(buffer[..<range.lowerBound])
                if !before.isEmpty {
                    events.append(depth > 0 ? .thinkingToken(before) : .token(before))
                }

                // Transition state.
                if depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        // Only fire thinkingComplete on 1→0 transition (not nested closes).
                        events.append(.thinkingComplete)
                    }
                } else {
                    depth += 1
                }

                buffer = String(buffer[range.upperBound...])
            } else {
                break
            }
        }

        // Hold back only the longest suffix of the buffer that could be a
        // non-empty prefix of the next marker, flushing everything else.
        let nextMarker = depth > 0 ? markers.close : markers.open
        let holdLength = overlap(buffer, nextMarker)
        if buffer.count > holdLength {
            let confirmed = String(buffer.prefix(buffer.count - holdLength))
            buffer = holdLength > 0 ? String(buffer.suffix(holdLength)) : ""
            if !confirmed.isEmpty {
                events.append(depth > 0 ? .thinkingToken(confirmed) : .token(confirmed))
            }
        }

        return events
    }

    /// Flush the held-back buffer at stream end.
    /// Returns `.thinkingToken` if inside an unclosed block, `.token` otherwise.
    public mutating func finalize() -> [GenerationEvent] {
        guard !buffer.isEmpty else { return [] }
        let remaining = buffer
        buffer = ""
        return [depth > 0 ? .thinkingToken(remaining) : .token(remaining)]
    }
}
