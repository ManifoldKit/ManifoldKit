import Foundation

/// Detects repetitive patterns in generated text and provides quantitative metrics.
///
/// Useful for catching model "looping" during streaming generation, where the model
/// repeats the same phrase or sentence indefinitely. ``ChatViewModel`` uses this
/// automatically when ``ChatViewModel/loopDetectionEnabled`` is `true`.
public enum RepetitionDetector {

    /// Returns `true` when the tail of `text` appears to be a contiguous repeated chunk.
    ///
    /// Detection modes:
    /// - **Triple repeat (3x):** Any unit of 8-120 characters repeated three consecutive times.
    /// - **Double repeat (2x):** Any unit of 50+ characters repeated twice consecutively.
    ///
    /// Requires at least 100 characters for 2x detection and 48 for 3x detection.
    public static func looksLikeLooping(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(trimmed)

        // 2x detection for longer units (50+ chars repeated twice).
        // A single sentence repeated once is common in prose; requiring 50+ chars
        // and checking only the tail reduces false positives.
        if characters.count >= 100 {
            let maxUnit2x = min(characters.count / 2, 200)
            for unitLength in stride(from: maxUnit2x, through: 50, by: -1) {
                let last = characters.suffix(unitLength)
                let prev = characters.dropLast(unitLength).suffix(unitLength)
                if prev.count == unitLength && last.elementsEqual(prev) {
                    return true
                }
            }
        }

        // 3x detection (original algorithm with tightened min unit)
        guard characters.count >= 48 else { return false }
        let maxUnit = min(120, characters.count / 3)
        guard maxUnit >= 8 else { return false }

        for unitLength in stride(from: maxUnit, through: 8, by: -1) {
            let last = characters.suffix(unitLength)
            let middle = characters.dropLast(unitLength).suffix(unitLength)
            let first = characters.dropLast(unitLength * 2).suffix(unitLength)
            if first.count == unitLength
                && last.elementsEqual(middle)
                && middle.elementsEqual(first) {
                return true
            }
        }

        return false
    }

    /// Returns a repetition rate in `[0, 1]` measuring the fraction of characters
    /// that participate in repeated n-gram sequences.
    ///
    /// - Note: This uses a sampled sliding-window approach to keep complexity manageable.
    ///   For texts over 2000 characters, it samples evenly-spaced windows rather than
    ///   scanning every position. Intended for test benchmarks, not the hot generation path.
    ///
    /// - Parameters:
    ///   - text: The text to analyse.
    ///   - unitRange: The range of n-gram lengths to check (default 20...50).
    /// - Returns: `0.0` for fully unique text, approaching `1.0` for fully repeated text.
    public static func repetitionRate(of text: String, unitRange: ClosedRange<Int> = 20...50) -> Double {
        let characters = Array(text)
        guard characters.count > unitRange.lowerBound else { return 0.0 }

        var markedIndices = Set<Int>()

        for unitLength in unitRange {
            guard characters.count >= unitLength * 2 else { continue }

            // Sample positions to keep work bounded: at most ~200 start positions per unit length.
            let totalPositions = characters.count - unitLength * 2 + 1
            let stride = max(1, totalPositions / 200)

            var i = 0
            while i < totalPositions {
                let unit = characters[i..<(i + unitLength)]
                // Only scan forward from each sampled position, bounded.
                var j = i + unitLength
                let jLimit = min(j + unitLength * 4, characters.count - unitLength + 1)
                while j < jLimit {
                    let candidate = characters[j..<(j + unitLength)]
                    if unit.elementsEqual(candidate) {
                        for idx in i..<(i + unitLength) { markedIndices.insert(idx) }
                        for idx in j..<(j + unitLength) { markedIndices.insert(idx) }
                    }
                    j += 1
                }
                i += stride
            }
        }

        return Double(markedIndices.count) / Double(characters.count)
    }
}
