import Foundation

/// Inspired by 04c3f4f — iOS jetsam. Flags two shapes of memory pathology
/// that the harness can observe without hooking into the allocator:
///
/// 1. A memory-related error string (`memory`, `OOM`, `jetsam`, etc.) fires
///    during generation. This path is always enabled.
/// 2. Peak resident bytes exceed `beforeBytes` by more than a model-declared
///    budget by a factor of `growthFactor`. This path is behind a TODO —
///    the record carries `MemorySnapshot.beforeBytes`/`peakBytes` today but
///    there is no `declaredBudget` field yet.
///
/// Ships at `.flaky` severity. Promotion to `.confirmed` requires the
/// calibration corpus + FP/TP gating planned in W2.C phase 2.
public struct MemoryGrowthDetector: Detector {
    public let id = "memory-growth"
    public let humanName = "Memory growth / OOM"
    public let inspiredBy = "04c3f4f — iOS jetsam"

    /// Case-insensitive substrings that signal a memory-related error.
    static let errorNeedles: [String] = [
        "memory",
        "oom",
        "out of memory",
        "jetsam",
        "mach_vm",
        "malloc",
    ]

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        var findings: [Finding] = []

        // 1. Error-string path — always enabled.
        if let err = r.error {
            let lower = err.lowercased()
            if let hit = Self.errorNeedles.first(where: { lower.contains($0) }) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "memory-error",
                    severity: .flaky,
                    trigger: "err-needle=\(hit)",
                    modelId: r.model.id
                ))
            }
        }

        // 2. Growth-budget path.
        // TODO: wire memory capture in a follow-up. The declared-budget
        // comparison requires a per-model memory budget field on
        // `ModelSnapshot` / `ConfigSnapshot` that doesn't exist yet. Until
        // then, this branch stays disabled to avoid speculative thresholds.
        _ = r.memory.beforeBytes
        _ = r.memory.peakBytes

        return findings
    }
}
