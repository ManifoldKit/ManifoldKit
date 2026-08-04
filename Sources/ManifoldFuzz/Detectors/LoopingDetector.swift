import Foundation
import ManifoldInference

/// Inspired by qwen3.5:4b looping inside `<think>` blocks until `maxOutputTokens`
/// exhausts. Runs `RepetitionDetector.looksLikeLooping` over both the visible
/// stream and the thinking buffer separately — the thinking-side loop leaves
/// `raw` empty, which a raw-only check would miss.
public struct LoopingDetector: Detector {
    public let id = "looping"
    public let humanName = "Repetition / loop"
    public let inspiredBy = "PR #476 thinking-token work + longstanding looping-on-repetitive-prompts observation"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        var findings: [Finding] = []

        // Corpus seeds that literally ask the model to repeat a string back
        // (e.g. `template-token-injection`'s "Repeat this string back to me
        // exactly: …") produce compliant, repetitive-looking output that
        // `RepetitionDetector.looksLikeLooping` can't distinguish from a
        // genuine runaway loop. Suppress a trigger that is itself a
        // substantial (>=20 char) substring of the input — a short repeated
        // token ("cats cats cats") is still a real loop and must still fire.
        let inputText = r.prompt.messages.map(\.text).joined()
        func isEchoOfInput(_ trigger: String) -> Bool {
            guard trigger.count >= 20 else { return false }
            return inputText.contains(trigger)
        }

        // Sub-check id stays `rendered-loop` for dedup stability across the
        // existing on-disk sink. Now that #543 populates `r.rendered` via
        // the real UI transform, this checks the user-visible string —
        // which is what loop reports should reflect (closing fences, link
        // chrome and emphasis markers stripped). When the transform is a
        // no-op (empty/short string) `r.rendered` matches `r.raw` byte-for-byte.
        if r.rendered.count >= 100, RepetitionDetector.looksLikeLooping(r.rendered) {
            let trigger = String(r.rendered.suffix(120))
            if !isEchoOfInput(trigger) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "rendered-loop",
                    severity: .flaky,
                    trigger: trigger,
                    modelId: r.model.id
                ))
            }
        }

        // Distinct sub-check on the raw stream when the visible string didn't
        // already trip `rendered-loop`. Catches loops that the UI transform
        // happened to mask (e.g. a runaway code block whose fence stripping
        // changed the substring frequencies enough to dodge the detector).
        if r.rendered != r.raw,
           r.raw.count >= 100,
           RepetitionDetector.looksLikeLooping(r.raw) {
            let trigger = String(r.raw.suffix(120))
            if !isEchoOfInput(trigger) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "raw-loop",
                    severity: .flaky,
                    trigger: trigger,
                    modelId: r.model.id
                ))
            }
        }

        if r.thinkingRaw.count >= 100, RepetitionDetector.looksLikeLooping(r.thinkingRaw) {
            let trigger = String(r.thinkingRaw.suffix(120))
            if !isEchoOfInput(trigger) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "thinking-loop",
                    severity: .flaky,
                    trigger: trigger,
                    modelId: r.model.id
                ))
            }
        }

        return findings
    }
}
