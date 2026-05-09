import Foundation

/// Inspired by df94418 (`<think>` blocks leaking into UI) and the failure modes
/// enabled by PR #476's structured thinking events: content can now be
/// misclassified between `.text` and `.thinking` parts in either direction.
public struct ThinkingClassificationDetector: Detector {
    public let id = "thinking-classification"
    public let humanName = "Thinking classification"
    public let inspiredBy = "PR #476 thinking-token work"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        var findings: [Finding] = []

        // Sub-checks 1 and 2 are only meaningful for backends that declare
        // native thinking markers (e.g. Qwen3 with <think>…</think>).
        // FoundationBackend and LlamaBackend set templateMarkers = nil; a
        // prompt that *discusses* <think> tags would otherwise produce false
        // positives here. Skip both sub-checks when no markers are declared.
        if let markers = r.templateMarkers {
            // 1. Visible-text leak: literal markers survive into the
            //    user-visible string. Now that #543 populates `r.rendered`
            //    via the real UI transform, this catches cases the raw-only
            //    check used to overlap with sub-check 2 — a marker that
            //    appears in raw but is stripped by the transform shouldn't
            //    be flagged here.
            if r.rendered.contains(markers.open) || r.rendered.contains(markers.close) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "visible-text-leak",
                    severity: .flaky,
                    trigger: extractContext(r.rendered, around: markers.open),
                    modelId: r.model.id
                ))
            }

            // 2. Misclassified-as-text: open marker appears in the raw stream
            //    but no structured thinking events were emitted (parser
            //    failed; reasoning fell into `.text`). Distinct from
            //    sub-check 1 because the marker may still be in `raw` even
            //    after the UI transform hides it from the user.
            if r.raw.contains(markers.open) && r.thinkingRaw.isEmpty {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "misclassified-as-text",
                    severity: .flaky,
                    trigger: extractContext(r.raw, around: markers.open),
                    modelId: r.model.id
                ))
            }
        }

        // 3. Orphan thinking-complete: complete event fired without any thinking tokens.
        if r.thinkingCompleteCount > 0 && r.thinkingRaw.isEmpty {
            findings.append(.init(
                detectorId: id,
                subCheck: "orphan-thinking-complete",
                severity: .flaky,
                trigger: "thinkingCompleteCount=\(r.thinkingCompleteCount), thinkingRaw=empty",
                modelId: r.model.id
            ))
        }

        // 4. Unbalanced events: thinking emitted but never closed cleanly,
        //    yet the stream completed normally. Skip when the model was cut
        //    off by the token cap — truncating mid-`<think>` is the cap's
        //    fault, not the parser's.
        if !r.thinkingRaw.isEmpty
            && r.thinkingCompleteCount == 0
            && r.phase == "done"
            && r.stopReason != "maxTokens" {
            findings.append(.init(
                detectorId: id,
                subCheck: "unbalanced-thinking-events",
                severity: .flaky,
                trigger: "thinkingRaw=\(r.thinkingRaw.prefix(80))…",
                modelId: r.model.id
            ))
        }

        return findings
    }

    private func extractContext(_ s: String, around needle: String, span: Int = 60) -> String {
        guard let range = s.range(of: needle) else { return String(s.prefix(120)) }
        let start = s.index(range.lowerBound, offsetBy: -span, limitedBy: s.startIndex) ?? s.startIndex
        let end = s.index(range.upperBound, offsetBy: span, limitedBy: s.endIndex) ?? s.endIndex
        return "…\(s[start..<end])…"
    }
}

