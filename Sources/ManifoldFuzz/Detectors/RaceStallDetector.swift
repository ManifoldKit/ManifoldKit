import Foundation

/// Inspired by 8d6b013 — stop-while-decoding races that leave the stream
/// producer in a stalled state, no error, no tokens, forever. Fires when:
///
/// - `phase == "stalled"` (the harness's explicit stall signal), OR
/// - `firstTokenMs > 60_000` AND `error == nil` (no first token after a
///   full minute and no failure recorded).
///
/// Tie-break: the second branch uses strict `>`, so `firstTokenMs == 60_000`
/// is NOT a stall — 60 seconds flat is the outer edge of what a genuine
/// cold-start model load can take on a chilled laptop.
///
/// Ships at `.flaky` severity. Promotion to `.confirmed` requires the
/// calibration corpus + FP/TP gating planned in W2.C phase 2.
public struct RaceStallDetector: Detector {
    public let id = "race-stall"
    public let humanName = "Stream stall / race"
    public let inspiredBy = "8d6b013 — stop-while-decoding races"

    /// Upper bound on a "legitimate" first-token latency. Anything past this
    /// with no error is stall-shaped rather than slow-shaped.
    public let firstTokenStallMs: Double

    public init(firstTokenStallMs: Double = 60_000) {
        self.firstTokenStallMs = firstTokenStallMs
    }

    public func inspect(_ r: RunRecord) -> [Finding] {
        var findings: [Finding] = []

        if r.phase == "stalled" {
            findings.append(.init(
                detectorId: id,
                subCheck: "phase-stalled",
                severity: .flaky,
                trigger: "phase=stalled totalMs=\(Int(r.timing.totalMs))",
                modelId: r.model.id
            ))
        }

        if let first = r.timing.firstTokenMs,
           first > firstTokenStallMs,
           r.error == nil {
            findings.append(.init(
                detectorId: id,
                subCheck: "first-token-timeout",
                severity: .flaky,
                trigger: "firstTokenMs>\(Int(firstTokenStallMs))",
                modelId: r.model.id
            ))
        }

        return findings
    }
}
