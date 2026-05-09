import Foundation

/// Inspired by the OllamaBackend `thinking`-field drop discovered while smoking
/// the harness against qwen3.5:4b: the model spent 80+ seconds reasoning, the
/// backend swallowed every byte, and the user saw an empty assistant bubble.
///
/// Fires when generation took non-trivial time, completed cleanly, but produced
/// no visible content AND no thinking content. Either the backend dropped the
/// stream, the model produced nothing, or a stop condition fired silently.
public struct EmptyOutputAfterWorkDetector: Detector {
    public let id = "empty-output-after-work"
    public let humanName = "Empty output after non-trivial work"
    public let inspiredBy = "#487 — Ollama thinking-drop smoke finding"

    /// Time threshold above which a clean-but-empty completion is suspicious.
    /// Default raised to 8s to clear cold-start model loads (`ollama serve` first hit).
    public let workThresholdMs: Double

    public init(workThresholdMs: Double = 8_000) {
        self.workThresholdMs = workThresholdMs
    }

    public func inspect(_ r: RunRecord) -> [Finding] {
        // Skip seeds whose user prompt is intentionally empty/whitespace
        // (corpus ids `empty-prompt`, `whitespace-only`): an empty completion
        // is the expected outcome, not a bug.
        let lastUserText = r.prompt.messages.last(where: { $0.role == "user" })?.text ?? ""
        if lastUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }

        guard r.phase == "done",
              r.error == nil,
              r.timing.totalMs >= workThresholdMs,
              r.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              r.thinkingRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }

        // Bucketise totalMs into a stable categorical band so dedup keys are
        // hash-stable across runs of the same logical bug. The exact totalMs
        // is preserved on the RunRecord; only the trigger fingerprint coarsens.
        let bucket: String
        switch r.timing.totalMs {
        case ..<30_000: bucket = ">8s"
        case ..<120_000: bucket = ">30s"
        default: bucket = ">2m"
        }
        let trigger = "silent-empty (\(bucket))"
        return [Finding(
            detectorId: id,
            subCheck: "silent-empty",
            severity: .flaky,
            trigger: trigger,
            modelId: r.model.id
        )]
    }
}
