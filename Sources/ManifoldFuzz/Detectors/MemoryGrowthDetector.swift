import Foundation

/// Inspired by 04c3f4f — iOS jetsam. Flags two shapes of memory pathology
/// that the harness can observe without hooking into the allocator:
///
/// 1. A memory-related error string (`memory`, `OOM`, `jetsam`, etc.) fires
///    during generation. This path is always enabled.
/// 2. Peak resident bytes exceed the model-declared budget
///    (`ModelSnapshot.memoryBudgetBytes`). The record carries
///    `MemorySnapshot.peakBytes` and, when capture supplies it, the per-model
///    budget; both must be present for this branch to fire.
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

        // 2. Growth-budget path. Fires only when both the captured peak and the
        // per-model budget are present — absent data is a no-op, never a
        // speculative threshold.
        if let peak = r.memory.peakBytes,
           let budget = r.model.memoryBudgetBytes,
           budget > 0,
           peak > budget {
            findings.append(.init(
                detectorId: id,
                subCheck: "budget-exceeded",
                severity: .flaky,
                trigger: "peak>\(budget)",
                modelId: r.model.id
            ))
        }

        return findings
    }
}
