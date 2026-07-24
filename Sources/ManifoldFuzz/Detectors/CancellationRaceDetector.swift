import Foundation

/// Fires on a stop-then-resend sequence where turn 2's raw output contains a
/// long verbatim run of text that arrived on turn 1 **after** the stop step
/// started. That is a cancellation race: decoded tail text leaked from the
/// stopped generation into the next one, which points at an incomplete
/// backend-level cancel.
///
/// The adversarial case (user legitimately sends the same message twice) is
/// ruled out by requiring the leaked text to have arrived on turn 1 at an
/// event timestamp later than the first event of turn 1 — i.e., it must have
/// been emitted mid-stream, not as the instant first response. That
/// correlates with the stop-while-decoding race window.
///
/// A second adversarial case — two *unrelated* verbose turns that happen to
/// share ordinary function words ("which", "where", "capital") — sank #2361:
/// matching on any single mid-stream `token` event (as short as
/// `minTokenChars`) treats common English words as evidence of a leak. Two
/// long-form generations sharing a handful of function words is expected,
/// not a race. `TurnBoundaryKVStateDetector` solved the identical shape for
/// turn-to-turn residue with a longest-common-contiguous-substring gate
/// instead of a token-membership check; this detector mirrors that design —
/// concatenate turn 1's post-stop token stream into one tail string and
/// require the longest run shared with turn 2's raw output to clear
/// `minResidueChars`, well above what an incidental shared phrase reaches.
public struct CancellationRaceDetector: SessionDetector {
    public let id = "cancellation-race"
    public let humanName = "Cancellation race token interleave"
    public let inspiredBy = "8d6b013 — stop-while-decoding; #2361 — FP fix"

    /// Minimum length (in Swift `Character`s) of the longest common
    /// contiguous substring between turn 1's post-stop token tail and turn
    /// 2's raw output required to fire. Mirrors
    /// `TurnBoundaryKVStateDetector.minResidueChars` — chosen to clear
    /// incidental shared function words/phrases ("which", "where", "the
    /// capital of") while still catching a genuine leaked run of decoded
    /// text.
    public let minResidueChars: Int

    public init(minResidueChars: Int = 24) {
        self.minResidueChars = minResidueChars
    }

    public func inspect(_ captures: [SessionCapture]) -> [Finding] {
        var findings: [Finding] = []
        for capture in captures {
            findings.append(contentsOf: inspectOneCapture(capture))
        }
        return findings
    }

    private func inspectOneCapture(_ capture: SessionCapture) -> [Finding] {
        let stopIndices = capture.steps.enumerated().compactMap { (off, step) -> Int? in
            step.timeline == .stopRequested ? off : nil
        }
        guard !stopIndices.isEmpty else { return [] }

        var findings: [Finding] = []
        for stopIdx in stopIndices {
            // Find turn-1 (the turn before the stop) and turn-2 (the turn
            // after). Stop without a preceding turn is meaningless; stop
            // without a following turn has no interleave surface.
            guard let turn1 = mostRecentTurn(before: stopIdx, in: capture),
                  let turn2 = nextTurn(after: stopIdx, in: capture) else { continue }

            let turn1Events = turn1.record?.events ?? []
            let turn2Raw = turn2.record?.raw ?? ""
            if turn1Events.isEmpty || turn2Raw.isEmpty { continue }

            // The post-stop tail: every `token` event emitted after the
            // first event of turn 1 (i.e., mid-stream), concatenated in
            // order. If the stop step landed between those token events and
            // turn 2's stream started, a long run of that tail appearing
            // verbatim in turn 2 is the bug.
            guard let firstEventT = turn1Events.first?.t else { continue }
            let postStopTail = turn1Events
                .filter { $0.kind == "token" && $0.t > firstEventT }
                .compactMap(\.v)
                .joined()
            guard !postStopTail.isEmpty else { continue }

            if let residue = Self.longestCommonSubstring(postStopTail, turn2Raw),
               residue.count >= minResidueChars {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "post-stop-token-leak",
                    severity: .flaky,
                    trigger: "leaked '\(residue.prefix(60))' into turn after stop",
                    modelId: turn2.record?.model.id ?? "unknown"
                ))
            }
        }
        return findings
    }

    /// Longest common contiguous substring. Classic O(n·m) DP on Character
    /// arrays — same algorithm as `TurnBoundaryKVStateDetector`. Inputs are
    /// small (per-turn raw strings are bounded by the configured
    /// `maxOutputTokens` → roughly 64–512 tokens), so an O(n·m) table is
    /// safe.
    static func longestCommonSubstring(_ a: String, _ b: String) -> String? {
        let ac = Array(a)
        let bc = Array(b)
        let n = ac.count
        let m = bc.count
        if n == 0 || m == 0 { return nil }
        var prevRow = [Int](repeating: 0, count: m + 1)
        var currRow = [Int](repeating: 0, count: m + 1)
        var best = 0
        var bestEnd = 0 // exclusive end index in `ac`
        for i in 1...n {
            for j in 1...m {
                if ac[i - 1] == bc[j - 1] {
                    currRow[j] = prevRow[j - 1] + 1
                    if currRow[j] > best {
                        best = currRow[j]
                        bestEnd = i
                    }
                } else {
                    currRow[j] = 0
                }
            }
            swap(&prevRow, &currRow)
            for k in 0..<currRow.count { currRow[k] = 0 }
        }
        if best == 0 { return nil }
        let start = bestEnd - best
        return String(ac[start..<bestEnd])
    }

    private func mostRecentTurn(before idx: Int, in capture: SessionCapture) -> SessionCapture.StepResult? {
        var i = idx - 1
        while i >= 0 {
            if capture.steps[i].timeline == .executed { return capture.steps[i] }
            i -= 1
        }
        return nil
    }

    private func nextTurn(after idx: Int, in capture: SessionCapture) -> SessionCapture.StepResult? {
        var i = idx + 1
        while i < capture.steps.count {
            if capture.steps[i].timeline == .executed { return capture.steps[i] }
            i += 1
        }
        return nil
    }
}
