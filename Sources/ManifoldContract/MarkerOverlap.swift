/// Prefix-hold overlap math — the single source of truth for chunk-boundary
/// holdback across every streaming markup transform.
///
/// Production inference servers all ship the same algorithm under different
/// names: llama.cpp's `string_find_partial_stop`, Ollama's `overlap`, and
/// vLLM's partial-stop handling. The idea is identical: when a streamed buffer
/// ends with text that *could* be the start of a marker, that suffix must be
/// held back until the next chunk arrives to disambiguate, so a partial
/// `<tool_ca` never leaks as visible text and a real `<tool_call>` is never
/// split across `.token` events.
///
/// This file extracts that proven primitive **once**. `ThinkingTransform` and
/// `ToolCallTransform` both call it instead of each re-deriving the loop.

/// Length of the longest suffix of `buffer` that is also a (non-empty) prefix
/// of `marker`.
///
/// Returns `0` when no suffix of `buffer` is a prefix of `marker`. The returned
/// length never exceeds `marker.count - 1`: a suffix equal to the *full* marker
/// is a completed match the caller should have already consumed via
/// `range(of:)`, not held back.
///
/// - Note: Operates on `Character` counts (grapheme clusters), matching the
///   `String.range(of:)` / `String.suffix(_:)` semantics the transforms use.
///   This keeps holdback boundaries aligned with how Swift slices the buffer
///   and avoids ever splitting a UTF-8 scalar.
package func overlap(_ buffer: Substring, _ marker: String) -> Int {
    let maxCheck = min(buffer.count, marker.count - 1)
    var length = maxCheck
    while length >= 1 {
        if marker.hasPrefix(buffer.suffix(length)) {
            return length
        }
        length -= 1
    }
    return 0
}

/// Convenience overload for a full `String` buffer.
package func overlap(_ buffer: String, _ marker: String) -> Int {
    overlap(buffer[...], marker)
}

/// Maximum overlap of `buffer` against any marker in `markers`.
///
/// This is Ollama's `max(overlap(acc, markerA), overlap(acc, markerB))` shape,
/// generalized to N markers. When several open markers compete (e.g. Llama's
/// Gemma-4 `<|tool_call>` vs the JSON `<tool_call>`), the buffer must hold back
/// enough to disambiguate *any* of them, so the holdback is the max across all
/// candidates — never less, or a partial form of the longer marker leaks.
func maxOverlap(_ buffer: Substring, _ markers: [String]) -> Int {
    var best = 0
    for marker in markers {
        let o = overlap(buffer, marker)
        if o > best { best = o }
    }
    return best
}

/// Convenience overload for a full `String` buffer.
func maxOverlap(_ buffer: String, _ markers: [String]) -> Int {
    maxOverlap(buffer[...], markers)
}
