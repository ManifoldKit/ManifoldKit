import Foundation

/// Inspired by e9ba9d1 — `InferenceError.contextExhausted` firing even when
/// the prompt + requested output comfortably fits in the model's context
/// window. The detector flags records whose error description indicates a
/// context-exhaustion refusal.
///
/// The "false trigger" guard (prompt token estimate < contextLimit * 0.5)
/// is deliberately disabled today. The `RunRecord` does not carry a
/// per-request prompt-token count. Until that field lands, we flag every
/// context-exhausted error — false positives are acceptable at `.flaky`
/// severity and the calibration corpus will filter legitimate exhaustions.
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

        // TODO: wire prompt-token estimate + contextLimit comparison. Once
        // `ConfigSnapshot` / `PromptSnapshot` carries a token budget, gate
        // this positive with `promptTokens < contextLimit / 2` to filter
        // legitimate exhaustions.
        return [Finding(
            detectorId: id,
            subCheck: "context-exhausted-fired",
            severity: .flaky,
            trigger: "error=\"\(err.prefix(120))\"",
            modelId: r.model.id
        )]
    }
}
