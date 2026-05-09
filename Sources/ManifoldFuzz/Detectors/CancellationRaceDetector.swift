import Foundation

/// Fires on a stop-then-resend sequence where turn 2's raw output contains
/// a verbatim token that arrived on turn 1 **after** the stop step started.
/// That is a cancellation race: tokens leaked from the stopped generation
/// into the next one, which points at an incomplete backend-level cancel.
///
/// The adversarial case (user legitimately sends the same message twice) is
/// ruled out by requiring the leaked token to have arrived on turn 1 at an
/// event timestamp later than the first event of turn 1 — i.e., the token
/// must have been emitted mid-stream, not as the instant first response.
/// That correlates with the stop-while-decoding race window.
public struct CancellationRaceDetector: SessionDetector {
    public let id = "cancellation-race"
    public let humanName = "Cancellation race token interleave"
    public let inspiredBy = "8d6b013 — stop-while-decoding"

    /// Minimum length of a leaked token (in characters) required to trigger.
    /// Short stop-words like " the" survive too many ordinary recaps; the
    /// default filters those out while preserving whole-word leaks.
    public let minTokenChars: Int

    public init(minTokenChars: Int = 6) {
        self.minTokenChars = minTokenChars
    }

    public func inspect(_ captures: [SessionCapture]) -> [Finding] {
        var findings: [Finding] = []
        for capture in captures {
            findings.append(contentsOf: inspectOneCapture(capture))
        }
        return findings
    }

    private func inspectOneCapture(_ capture: SessionCapture) -> [Finding] {
        let stopIndices = capture.steps.enumerated().compactMap { (off, step) -> Int? in
            step.timeline == .stopRequested ? off : nil
        }
        guard !stopIndices.isEmpty else { return [] }

        var findings: [Finding] = []
        for stopIdx in stopIndices {
            // Find turn-1 (the turn before the stop) and turn-2 (the turn
            // after). Stop without a preceding turn is meaningless; stop
            // without a following turn has no interleave surface.
            guard let turn1 = mostRecentTurn(before: stopIdx, in: capture),
                  let turn2 = nextTurn(after: stopIdx, in: capture) else { continue }

            let turn1Events = turn1.record?.events ?? []
            let turn2Raw = turn2.record?.raw ?? ""
            if turn1Events.isEmpty || turn2Raw.isEmpty { continue }

            // A post-stop token: any `token` event emitted after the first
            // event of turn 1 (i.e., mid-stream). If the stop step landed
            // between the token events and turn 2's stream started, a leaked
            // token from turn 1 appearing verbatim in turn 2 is the bug.
            guard let firstEventT = turn1Events.first?.t else { continue }

            for event in turn1Events {
                guard event.kind == "token", let text = event.v else { continue }
                guard event.t > firstEventT else { continue }
                guard text.count >= minTokenChars else { continue }
                if turn2Raw.contains(text) {
                    findings.append(.init(
                        detectorId: id,
                        subCheck: "post-stop-token-leak",
                        severity: .flaky,
                        trigger: "leaked '\(text.prefix(60))' into turn after stop",
                        modelId: turn2.record?.model.id ?? "unknown"
                    ))
                    // One finding per stop boundary suffices.
                    break
                }
            }
        }
        return findings
    }

    private func mostRecentTurn(before idx: Int, in capture: SessionCapture) -> SessionCapture.StepResult? {
        var i = idx - 1
        while i >= 0 {
            if capture.steps[i].timeline == .executed { return capture.steps[i] }
            i -= 1
        }
        return nil
    }

    private func nextTurn(after idx: Int, in capture: SessionCapture) -> SessionCapture.StepResult? {
        var i = idx + 1
        while i < capture.steps.count {
            if capture.steps[i].timeline == .executed { return capture.steps[i] }
            i += 1
        }
        return nil
    }
}
