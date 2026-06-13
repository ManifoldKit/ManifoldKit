import Foundation

/// Inspired by e9ba9d1 — `InferenceError.contextExhausted` firing even when
/// the prompt + requested output comfortably fits in the model's context
/// window. The detector flags records whose error description indicates a
/// context-exhaustion refusal.
///
/// When the capture supplies both `PromptSnapshot.estimatedPromptTokens` and
/// `ConfigSnapshot.contextLimit`, the detector gates the positive on the
/// "false trigger" guard: it fires only when the prompt comfortably fits
/// (`promptTokens < contextLimit / 2`), since a context-exhausted error there
/// is a misfire rather than a legitimate exhaustion. When either field is
/// absent the guard is a no-op and every context-exhausted error is flagged —
/// false positives are acceptable at `.flaky` severity and the calibration
/// corpus will filter legitimate exhaustions.
///
/// Ships at `.flaky` severity. Promotion to `.confirmed` requires the
/// calibration corpus + FP/TP gating planned in W2.C phase 2.
public struct ContextExhaustionSilentDetector: Detector {
    public let id = "context-exhaustion-silent"
    public let humanName = "Silent context-exhaustion false trigger"
    public let inspiredBy = "e9ba9d1 — context-exhausted misfire"

    /// Canonical fragment from `InferenceError.contextExhausted`'s
    /// `errorDescription`. Matched case-insensitively.
    static let errorNeedle = "exceeds context window"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        guard let err = r.error else { return [] }
        guard err.lowercased().contains(Self.errorNeedle) else { return [] }

        // False-trigger guard: when both the prompt-token estimate and the
        // context limit are present, a context-exhausted error is only a
        // misfire if the prompt comfortably fit (well under half the window).
        // If the prompt was actually large the exhaustion is legitimate — skip.
        // Absent either field, the guard is a no-op and we flag the error.
        if let promptTokens = r.prompt.estimatedPromptTokens,
           let contextLimit = r.config.contextLimit,
           contextLimit > 0,
           promptTokens >= contextLimit / 2 {
            return []
        }

        return [Finding(
            detectorId: id,
            subCheck: "context-exhausted-fired",
            severity: .flaky,
            trigger: "error=\"\(err.prefix(120))\"",
            modelId: r.model.id
        )]
    }
}
