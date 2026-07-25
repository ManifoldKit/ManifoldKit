import Foundation

/// Fires when turn 2's raw output contains a long verbatim run of text from
/// turn 1's own mid-stream tail (the portion of turn 1's stream after its
/// first event), gated on a `.stop` step existing somewhere between the two
/// turns.
///
/// ## What this can and can't detect (read before touching the stop-timing logic)
///
/// The name and original doc comment framed this as catching a live
/// cancellation race — tokens still in flight when `.stop` fires leaking
/// into the next turn. #2361's investigation found that framing describes a
/// condition this harness cannot produce: `SessionScriptRunner.execute` is
/// strictly sequential — a `.send` step's `runTurn` is fully `await`ed
/// (its stream consumed to completion by `EventRecorder.consume`) before the
/// loop advances to the script's next step, so by the time a `.stop` step's
/// `stopGeneration()` call runs, turn 1 has already reached `phase: "done"`
/// and the service is idle. There is no in-flight decode for `.stop` to race
/// with in this harness.
///
/// There is also no shared clock to detect an overlap even if one could
/// occur: `EventSnapshot.t` (`EventRecorder.consume`) is measured from each
/// turn's own `ContinuousClock.now`, reset per turn — turn 1's event
/// timestamps and the `.stop` step's `elapsedMs` are not on the same axis.
/// **Do not** try to filter on "did this token arrive after the stop's
/// timestamp" — turn 1's timestamps are always smaller than they'd need to
/// be to compare against a later step's, so that filter would silently
/// select the empty set on every capture and permanently disable the
/// detector.
///
/// So today this detector only checks: does a long run of turn 1's own
/// (naturally completed) tail leak verbatim into turn 2, on captures where a
/// `.stop` step happens to sit between them. #2361 was filed against exactly
/// that check, and the check itself was unsound: it matched on any single
/// mid-stream `token` event (as short as the old `minTokenChars`), so two
/// long-form generations sharing an ordinary function word ("which",
/// "where") — or, worse, echoing a word from the *user's own prompt* on both
/// turns (`edit-then-regenerate.json`: "capital of France" → "capital of
/// Germany") — satisfied it trivially. `TurnBoundaryKVStateDetector` solved
/// the identical false-positive shape for turn-to-turn residue with a
/// longest-common-contiguous-substring gate instead of a token-membership
/// check; this detector mirrors that design (via the shared
/// `LongestCommonSubstring` helper) — concatenate turn 1's mid-stream token
/// stream into one tail string and require the longest run shared with turn
/// 2's raw output to clear `minResidueChars`, well above what an incidental
/// shared word/phrase reaches.
public struct CancellationRaceDetector: SessionDetector {
    public let id = "cancellation-race"
    public let humanName = "Cancellation race token interleave"
    public let inspiredBy = "8d6b013 — stop-while-decoding; #2361 — FP fix (see doc comment: harness can't race)"

    /// Minimum length (in Swift `Character`s) of the longest common
    /// contiguous substring between turn 1's mid-stream tail and turn 2's
    /// raw output required to fire. Shared with
    /// `TurnBoundaryKVStateDetector.minResidueChars` via
    /// `LongestCommonSubstring.defaultMinChars` — chosen to clear incidental
    /// shared function words/phrases ("which", "where", "the capital of")
    /// while still catching a genuine leaked run of decoded text.
    public let minResidueChars: Int

    public init(minResidueChars: Int = LongestCommonSubstring.defaultMinChars) {
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

            let turn1Events = turn1.record?.events ?? []
            let turn2Raw = turn2.record?.raw ?? ""
            if turn1Events.isEmpty || turn2Raw.isEmpty { continue }

            // turn 1's mid-stream tail: every `token` event emitted after
            // the first event of turn 1, concatenated in order. This is
            // NOT "the part of turn 1 still in flight when stop landed" —
            // see the type's doc comment: the harness always finishes turn
            // 1 before `.stop` runs, so there is no such window. It's just
            // "turn 1 minus its opening token" — a long run of THAT
            // appearing verbatim in turn 2 (on a capture where a `.stop`
            // step happens to sit between them) is what this checks.
            guard let firstEventT = turn1Events.first?.t else { continue }
            let midStreamTail = turn1Events
                .filter { $0.kind == "token" && $0.t > firstEventT }
                .compactMap(\.v)
                .joined()
            guard !midStreamTail.isEmpty else { continue }

            if let residue = LongestCommonSubstring.compute(midStreamTail, turn2Raw),
               residue.count >= minResidueChars {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "turn1-tail-residue-in-turn-after-stop",
                    severity: .flaky,
                    trigger: "turn1-tail residue '\(residue.prefix(60))' found verbatim in turn after stop",
                    modelId: turn2.record?.model.id ?? "unknown"
                ))
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
