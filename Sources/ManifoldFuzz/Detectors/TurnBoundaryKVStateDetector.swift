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
    /// Shared with `CancellationRaceDetector` via
    /// `LongestCommonSubstring.defaultMinChars` — see that type's doc
    /// comment for why the two must not drift apart.
    public let minResidueChars: Int

    public init(minResidueChars: Int = LongestCommonSubstring.defaultMinChars) {
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
                if let residue = LongestCommonSubstring.compute(prev, curr),
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
}
