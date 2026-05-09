import Foundation

/// Inspired by 18710d2 — KV-cache collisions that surface as
/// `Decode failed during generation` after a prior stop. The canonical
/// shape: user cancels mid-decode, the cache pointer is left dangling,
/// the next turn trips the same error.
///
/// Today's harness is single-turn, so the "prior stop event in the same
/// session" condition collapses to: error string matches AND the record
/// itself records a stop (stopReason == "userStop" or phase == "stopped").
/// Multi-turn support arrives in #492; this detector will pick up the
/// richer session context automatically once events span turns.
///
/// Ships at `.flaky` severity. Promotion to `.confirmed` requires the
/// calibration corpus + FP/TP gating planned in W2.C phase 2.
public struct KVCollisionDetector: Detector {
    public let id = "kv-collision"
    public let humanName = "KV-cache decode collision"
    public let inspiredBy = "18710d2 — KV-collision on stop-then-resume"

    /// Case-insensitive substring that marks the canonical llama.cpp decode
    /// failure observed post-collision. Kept narrow to avoid matching
    /// natural-language echoes of the phrase.
    static let errorNeedle = "decode failed during generation"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        guard let err = r.error else { return [] }
        let lower = err.lowercased()
        guard lower.contains(Self.errorNeedle) else { return [] }

        // A naturally occurring error echo is unlikely in `error`, but guard
        // against a record that only *almost* matches (e.g., "Decode failed"
        // without the "during generation" tail) — we require the full phrase.
        guard r.phase == "stopped" || r.stopReason == "userStop" || r.stopReason == "error"
        else { return [] }

        return [Finding(
            detectorId: id,
            subCheck: "decode-after-stop",
            severity: .flaky,
            trigger: "phase=\(r.phase) stopReason=\(r.stopReason ?? "nil")",
            modelId: r.model.id
        )]
    }
}
