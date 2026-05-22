/// Stateful, chunk-safe parser that separates reasoning from visible text.
///
/// Emits `[GenerationEvent]` from each chunk rather than a plain `String`,
/// allowing callers to route thinking content separately from visible content.
/// Parameterized by `ThinkingMarkers` so the same logic handles both
/// `<think>`/`</think>` (Qwen3, DeepSeek-R1) and custom model formats.
public struct ThinkingParser {
    public let markers: ThinkingMarkers
    private var depth = 0
    private var buffer = ""

    public init(markers: ThinkingMarkers = .qwen3) {
        self.markers = markers
    }

    /// Process a chunk of streamed text. Returns a mix of `.token`,
    /// `.thinkingToken`, and `.thinkingComplete` events.
    public mutating func process(_ chunk: String) -> [GenerationEvent] {
        buffer += chunk
        var events: [GenerationEvent] = []

        while true {
            let tag = depth > 0 ? markers.close : markers.open

            if let range = buffer.range(of: tag) {
                // Emit everything before the tag as the current mode's event type
                let before = String(buffer[..<range.lowerBound])
                if !before.isEmpty {
                    events.append(depth > 0 ? .thinkingToken(before) : .token(before))
                }

                // Transition state
                if depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        // Only fire thinkingComplete on 1→0 transition (not for nested close tags)
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
        // non-empty prefix of the next marker, preventing premature emission of
        // partial tags while flushing everything else immediately.
        let nextMarker = depth > 0 ? markers.close : markers.open
        let maxCheck = min(buffer.count, nextMarker.count - 1)
        var holdLength = 0
        for length in stride(from: maxCheck, through: 1, by: -1) {
            if nextMarker.hasPrefix(String(buffer.suffix(length))) {
                holdLength = length
                break
            }
        }
        if buffer.count > holdLength {
            let confirmed = String(buffer.prefix(buffer.count - holdLength))
            buffer = holdLength > 0 ? String(buffer.suffix(holdLength)) : ""
            if !confirmed.isEmpty {
                events.append(depth > 0 ? .thinkingToken(confirmed) : .token(confirmed))
            }
        }

        return events
    }

    /// Flush the held-back buffer at stream end. Call once after the generation loop ends.
    /// Returns `.thinkingToken` if inside an unclosed block, `.token` otherwise.
    public mutating func finalize() -> [GenerationEvent] {
        guard !buffer.isEmpty else { return [] }
        let remaining = buffer
        buffer = ""
        return [depth > 0 ? .thinkingToken(remaining) : .token(remaining)]
    }
}

