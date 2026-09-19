import Foundation

/// Fires when a stop that actually overlapped turn 1 is followed by turn 2
/// whose visible output begins with a suffix of turn 1's observed tail.
///
/// ## What this can and can't detect (read before touching the stop-timing logic)
///
/// #2361 found two independent blind spots in the old check. First,
/// `SessionScriptRunner` awaited turn 1 to completion before executing the
/// next `.stop`, so the stop was idle by construction. The runner now pairs an
/// immediately adjacent turn/stop, waits until the one `EventRecorder`
/// consumer observes visible output, and calls `stopGeneration()` while the
/// service still reports an active turn. Stops that lose that race or observe
/// no visible content produce an explicit `stop-window-unexercised` finding;
/// they never count as clean cancellation coverage.
///
/// Second, the old detector searched for a long common substring anywhere in
/// turn 2. The narrower observation recorded here is a suffix of the stopped
/// turn's observed tail appearing at the very start of its successor. That
/// positional gate rejects mid-answer "which" / "where" false positives, but
/// it still cannot distinguish leaked state from an ordinary shared answer
/// prefix. The finding therefore remains an ambiguous candidate that requires
/// manual provenance work; replay repetition never confirms it as a race.
///
/// `textObservedAfterStopReturned` means exactly that the recorder consumed
/// the event after `stopGeneration()` returned. It does not prove when the
/// backend emitted or decoded the event because an async stream may already
/// have buffered it. Findings use "observed" language deliberately.
public struct CancellationRaceDetector: SessionDetector {
    public let id = "cancellation-race"
    public let humanName = "Cancellation stop-boundary overlap candidate"
    public let inspiredBy = "8d6b013 — stop-while-decoding; #2361 — real in-flight stop + positional residue"

    /// Minimum positional suffix/prefix overlap, in Swift `Character`s.
    /// Six catches one leaked subword-sized chunk; requiring that chunk at
    /// both boundaries supplies the discrimination the old 24-character
    /// anywhere-match lacked.
    public let minResidueChars: Int

    public init(minResidueChars: Int = 6) {
        self.minResidueChars = minResidueChars
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

            guard let observation = capture.steps[stopIdx].stopObservation else {
                findings.append(unexercisedFinding(
                    reason: "stop has no overlap observation (synthetic or legacy capture)",
                    turn1: turn1,
                    turn2: turn2
                ))
                continue
            }
            guard observation.qualification == .inFlight else {
                findings.append(unexercisedFinding(
                    reason: qualificationDescription(observation.qualification),
                    turn1: turn1,
                    turn2: turn2
                ))
                continue
            }

            let turn2Raw = turn2.record?.raw ?? ""
            let stoppedTurnTail = observation.tailObservedBeforeStopReturned
                + observation.textObservedAfterStopReturned
            guard !stoppedTurnTail.isEmpty, !turn2Raw.isEmpty else { continue }

            if let residue = longestSuffixPrefixOverlap(stoppedTurnTail, turn2Raw),
               residue.count >= minResidueChars {
                let afterStopCount = observation.textObservedAfterStopReturned.count
                findings.append(.init(
                    detectorId: id,
                    subCheck: "stopped-turn-tail-at-successor-prefix",
                    severity: .flaky,
                    trigger: "ambiguous stop-boundary overlap requiring manual triage: "
                        + "stopped-turn suffix '\(residue.prefix(60))' begins successor; "
                        + "\(afterStopCount) character(s) were observed after stop returned "
                        + "(backend emission time unknown; overlap alone does not prove leakage)",
                    modelId: turn2.record?.model.id ?? "unknown"
                ))
            }
        }
        return findings
    }

    private func unexercisedFinding(
        reason: String,
        turn1: SessionCapture.StepResult,
        turn2: SessionCapture.StepResult
    ) -> Finding {
        .init(
            detectorId: id,
            subCheck: "stop-window-unexercised",
            severity: .flaky,
            trigger: "cancellation coverage not qualified: \(reason); manual triage required, "
                + "and repetition cannot confirm a race",
            modelId: turn2.record?.model.id ?? turn1.record?.model.id ?? "unknown"
        )
    }

    private func qualificationDescription(_ qualification: SessionCapture.StopQualification) -> String {
        switch qualification {
        case .inFlight:
            return "in-flight"
        case .completedBeforeStop:
            return "turn completed before stop reached the active service"
        case .noVisibleContent:
            return "turn ended without visible content before a stop window opened"
        case .notPairedWithTurn:
            return "stop was not immediately paired with a send/regenerate step"
        case .cancelledBeforeObservation:
            return "runner was cancelled before the stop window was observed"
        }
    }

    private func longestSuffixPrefixOverlap(_ oldTail: String, _ successor: String) -> String? {
        let maxLength = min(oldTail.count, successor.count)
        guard maxLength >= minResidueChars else { return nil }

        for length in stride(from: maxLength, through: minResidueChars, by: -1) {
            let suffix = oldTail.suffix(length)
            if suffix.elementsEqual(successor.prefix(length)) {
                return String(suffix)
            }
        }
        return nil
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
