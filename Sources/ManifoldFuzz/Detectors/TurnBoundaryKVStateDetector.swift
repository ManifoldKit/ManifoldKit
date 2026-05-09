import Foundation

/// Fires when turn N's `raw` contains a non-trivial verbatim substring from
/// turn N-1's `raw`. A non-trivial residue across a turn boundary points to
/// KV-cache bleed or session-context corruption that single-turn fuzzing
/// cannot see.
///
/// The stop-word adversarial (both turns repeat "the ") must not fire, so
/// we gate on a minimum substring length. The threshold is chosen to clear
/// common filler phrases while still catching whole sentences that copy
/// through.
public struct TurnBoundaryKVStateDetector: SessionDetector {
    public let id = "turn-boundary-kv-state"
    public let humanName = "Turn-boundary KV state residue"
    public let inspiredBy = "18710d2 — KV collision surface"

    /// Minimum length (in Swift `Character`s) of the longest-common shared
    /// substring between turn N-1 and turn N for the detector to fire. Must
    /// exceed the longest common adversarial phrase ("the answer is ").
    public let minResidueChars: Int

    public init(minResidueChars: Int = 24) {
        self.minResidueChars = minResidueChars
    }

    public func inspect(_ captures: [SessionCapture]) -> [Finding] {
        var findings: [Finding] = []
        for capture in captures {
            let records = capture.turnRecords
            guard records.count >= 2 else { continue }
            for i in 1..<records.count {
                let prev = records[i - 1].raw
                let curr = records[i].raw
                guard !prev.isEmpty, !curr.isEmpty else { continue }
                if let residue = longestCommonSubstring(prev, curr),
                   residue.count >= minResidueChars {
                    findings.append(.init(
                        detectorId: id,
                        subCheck: "residue-across-turns",
                        severity: .flaky,
                        trigger: "turn\(i - 1)→turn\(i): \(String(residue.prefix(80)))",
                        modelId: records[i].model.id
                    ))
                }
            }
        }
        return findings
    }

    /// Longest common contiguous substring. Classic O(n·m) DP on Character
    /// arrays. Inputs are small (per-turn raw strings are bounded by the
    /// configured `maxOutputTokens` → roughly 64–512 tokens), so an O(n·m)
    /// table is safe.
    func longestCommonSubstring(_ a: String, _ b: String) -> String? {
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
}
