import Foundation

/// Inspired by the generic "anomaly catch-all" bucket. The intended design
/// flags records whose `totalMs` exceeds 5× the rolling median for the same
/// model+config window (last 20 records). That requires per-detector mutable
/// state, which the current `Detector` protocol (Sendable, stateless
/// `inspect`) does not support.
///
/// Ships with a crude fallback: any record whose `totalMs` exceeds 60s is
/// flagged. This is intentionally conservative — real long-running cloud
/// calls routinely blow past 60s, so false positives are expected, and
/// the calibration corpus + FP/TP gating (W2.C phase 2) is what will make
/// the real windowed detector useful.
///
/// FIXME: needs window history — see issue #489. Move to a stateful actor
/// once the Detector protocol grows a registry-level state slot, or emit
/// findings from a post-run aggregator that owns the history.
///
/// Ships at `.flaky` severity.
public struct TimeoutDetector: Detector {
    public let id = "timeout"
    public let humanName = "Wall-clock timeout outlier"
    public let inspiredBy = "generic anomaly catch-all"

    /// Fallback fixed threshold used until windowed-median support lands.
    public let fallbackThresholdMs: Double

    public init(fallbackThresholdMs: Double = 60_000) {
        self.fallbackThresholdMs = fallbackThresholdMs
    }

    public func inspect(_ r: RunRecord) -> [Finding] {
        guard r.timing.totalMs > fallbackThresholdMs else { return [] }
        return [Finding(
            detectorId: id,
            subCheck: "totalMs-over-threshold",
            severity: .flaky,
            trigger: "totalMs=\(Int(r.timing.totalMs)) threshold=\(Int(fallbackThresholdMs))",
            modelId: r.model.id
        )]
    }
}
