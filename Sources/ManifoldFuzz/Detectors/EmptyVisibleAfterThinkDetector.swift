import Foundation

/// Inspired by 0d3c206 — the `hasVisibleContent` bug where a message with
/// only thinking content was treated as "has content" and the empty visible
/// string was rendered as a blank bubble. Catches the inverse of the
/// `EmptyOutputAfterWorkDetector`: the model *did* produce raw tokens and
/// *did* produce thinking, but the visible rendering is empty.
///
/// `rendered` holds the user-visible portion of the stream after the real
/// UI transform pipeline (#543). It is the right field to read for this
/// detector — `raw` would include `<think>` markers and inline syntax that
/// the user never actually sees as glyphs.
///
/// Ships at `.flaky` severity. Promotion to `.confirmed` requires the
/// calibration corpus + FP/TP gating planned in W2.C phase 2.
public struct EmptyVisibleAfterThinkDetector: Detector {
    public let id = "empty-visible-after-think"
    public let humanName = "Empty visible output after thinking"
    public let inspiredBy = "0d3c206 — hasVisibleContent bug"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        guard r.phase == "done",
              !r.raw.isEmpty,
              !r.thinkingRaw.isEmpty,
              r.rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }

        return [Finding(
            detectorId: id,
            subCheck: "visible-empty",
            severity: .flaky,
            trigger: "thinking=\(r.thinkingRaw.count)B rendered=empty",
            modelId: r.model.id
        )]
    }
}
