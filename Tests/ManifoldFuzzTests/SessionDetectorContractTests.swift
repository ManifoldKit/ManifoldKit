import XCTest
@testable import ManifoldFuzz

// MARK: - Fixture helpers

private enum SessionFixture {

    /// Build a minimal ``RunRecord`` for a single turn inside a contract
    /// fixture. `events` is a convenience over the full `EventSnapshot`
    /// shape — callers pass `(t, kind, v)` tuples.
    static func record(
        raw: String,
        events: [(Double, String, String?)] = [],
        modelId: String = "contract-model"
    ) -> RunRecord {
        RunRecord(
            runId: UUID().uuidString,
            ts: "2026-04-19T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: "deadbeef",
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "mock",
                id: modelId,
                url: "mem://session-detector-contract",
                fileSHA256: nil,
                tokenizerHash: nil
            ),
            config: .init(
                seed: 0,
                temperature: 0.0,
                topP: 1.0,
                maxTokens: nil,
                systemPrompt: nil
            ),
            prompt: .init(
                corpusId: "contract",
                mutators: [],
                messages: []
            ),
            events: events.map { .init(t: $0.0, kind: $0.1, v: $0.2) },
            raw: raw,
            rendered: raw,
            thinkingRaw: "",
            thinkingParts: [],
            thinkingCompleteCount: 0,
            templateMarkers: nil,
            memory: .init(beforeBytes: nil, peakBytes: nil, afterBytes: nil),
            timing: .init(firstTokenMs: nil, totalMs: 0, tokensPerSec: nil),
            phase: "done",
            error: nil,
            stopReason: "naturalStop"
        )
    }

    /// A ``SessionCapture`` from a list of turn records plus an optional
    /// stop step between turns N and N+1 for race fixtures.
    static func capture(
        id: String,
        turns: [RunRecord],
        stopAfterIndex: Int? = nil,
        systemPrompt: String? = nil,
        sessionLabel: String? = nil
    ) -> SessionCapture {
        var steps: [SessionCapture.StepResult] = []
        var stepIndex = 0
        for (i, r) in turns.enumerated() {
            steps.append(.init(
                index: stepIndex,
                step: .send(text: ""),
                record: r,
                timeline: .executed,
                elapsedMs: 0
            ))
            stepIndex += 1
            if stopAfterIndex == i {
                steps.append(.init(
                    index: stepIndex,
                    step: .stop,
                    record: nil,
                    timeline: .stopRequested,
                    elapsedMs: 0
                ))
                stepIndex += 1
            }
        }
        let script = SessionScript(
            id: id,
            steps: steps.map(\.step),
            systemPrompt: systemPrompt,
            sessionLabel: sessionLabel
        )
        return SessionCapture(
            script: script,
            sessionID: UUID(),
            steps: steps
        )
    }
}

// MARK: - Shared assertion helpers (session variant)
//
// The session detectors ship a 4-case contract (positive / negative /
// boundary / adversarial) mirroring the single-turn ``DetectorContract``
// protocol. We don't reuse that exact protocol because its `detector`
// associated type is `any Detector` (single-record), not `SessionDetector`.
// The four-case discipline is preserved below with direct XCTest methods.

private enum SessionContractAsserter {
    static func assertEmpty(
        _ findings: [Finding],
        detectorId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(findings.isEmpty,
            "\(detectorId): expected no findings; got \(findings.map { "\($0.subCheck):\($0.trigger)" })",
            file: file, line: line)
    }

    static func assertNonEmpty(
        _ findings: [Finding],
        detectorId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(findings.isEmpty,
            "\(detectorId): expected at least one finding; got none",
            file: file, line: line)
    }

    static func assertDeterministic(
        detector: any SessionDetector,
        captures: [SessionCapture],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let first = detector.inspect(captures)
        let firstFP = first.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
        for i in 1..<10 {
            let next = detector.inspect(captures)
            let nextFP = next.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
            XCTAssertEqual(firstFP, nextFP,
                "boundary run \(i) differed from run 0 for detector \(detector.id)",
                file: file, line: line)
        }
    }
}

// MARK: - TurnBoundaryKVStateDetector contract

final class TurnBoundaryKVStateDetectorContractTests: XCTestCase {

    private let detector = TurnBoundaryKVStateDetector()

    func test_positive_verbatimResidueFromPriorTurnFires() {
        // Turn 1 emits a sentence; turn 2 starts by copying that sentence
        // verbatim, well above the 24-char threshold.
        let shared = "The quick brown fox jumps over the lazy dog in the meadow."
        let turn1 = SessionFixture.record(raw: shared)
        let turn2 = SessionFixture.record(raw: shared + " Also, birds sing.")
        let capture = SessionFixture.capture(id: "positive", turns: [turn1, turn2])
        SessionContractAsserter.assertNonEmpty(detector.inspect([capture]), detectorId: detector.id)
    }

    func test_negative_independentOutputsDoNotFire() {
        let turn1 = SessionFixture.record(raw: "Paris is the capital of France.")
        let turn2 = SessionFixture.record(raw: "Tokyo sits on Honshu island.")
        let capture = SessionFixture.capture(id: "neg", turns: [turn1, turn2])
        SessionContractAsserter.assertEmpty(detector.inspect([capture]), detectorId: detector.id)
    }

    /// Boundary: shared substring is exactly `minResidueChars` long (24).
    /// The guard is `>= minResidueChars` so it MUST fire; ten inspections
    /// must return identical findings.
    func test_boundary_deterministicAtThreshold() {
        // 24 characters exactly. Must fire, must be deterministic.
        let boundary = "abcdefghijklmnopqrstuvwx" // 24 chars
        precondition(boundary.count == 24)
        let turn1 = SessionFixture.record(raw: "prefix " + boundary + " suffix")
        let turn2 = SessionFixture.record(raw: "unrelated " + boundary)
        let capture = SessionFixture.capture(id: "boundary", turns: [turn1, turn2])
        SessionContractAsserter.assertDeterministic(detector: detector, captures: [capture])
        // Also assert it DOES fire (boundary is MUST-fire here).
        XCTAssertFalse(detector.inspect([capture]).isEmpty)
    }

    /// Adversarial: both turns legitimately repeat the common short phrase
    /// "the answer is ". Below the 24-char threshold — must stay silent.
    func test_adversarial_commonStopWordPhraseDoesNotFire() {
        let turn1 = SessionFixture.record(raw: "I believe the answer is 42.")
        let turn2 = SessionFixture.record(raw: "Well, the answer is probably 7.")
        let capture = SessionFixture.capture(id: "adv", turns: [turn1, turn2])
        SessionContractAsserter.assertEmpty(detector.inspect([capture]), detectorId: detector.id)
    }
}

// MARK: - CancellationRaceDetector contract

final class CancellationRaceDetectorContractTests: XCTestCase {

    private let detector = CancellationRaceDetector()

    /// Positive: turn 1 streams several tokens; a stop fires; turn 2's raw
    /// contains one of turn 1's post-stop tokens verbatim — a leak.
    func test_positive_postStopTokenLeakFires() {
        let turn1 = SessionFixture.record(
            raw: "begin middlephrase end",
            events: [
                (0.0, "token", "begin "),
                (0.5, "token", "middlephrase "),
                (0.9, "token", "end"),
            ]
        )
        let turn2 = SessionFixture.record(raw: "completely new response with middlephrase in it")
        let capture = SessionFixture.capture(id: "race-pos", turns: [turn1, turn2], stopAfterIndex: 0)
        let findings = detector.inspect([capture])
        XCTAssertFalse(findings.isEmpty)
    }

    /// Negative: no stop step, turns are clean.
    func test_negative_noStopMeansNoFiring() {
        let turn1 = SessionFixture.record(
            raw: "answer one",
            events: [(0.0, "token", "answer "), (0.5, "token", "one")]
        )
        let turn2 = SessionFixture.record(raw: "entirely different second reply")
        let capture = SessionFixture.capture(id: "race-neg", turns: [turn1, turn2], stopAfterIndex: nil)
        let findings = detector.inspect([capture])
        XCTAssertTrue(findings.isEmpty)
    }

    /// Boundary: stop exists, turn-1 has exactly one post-first-event token,
    /// and that token (`raceword`) appears in turn 2. Ten inspections return
    /// identical findings.
    func test_boundary_deterministicAtSinglePostStopToken() {
        let turn1 = SessionFixture.record(
            raw: "hello raceword",
            events: [
                (0.0, "token", "hello "),
                (0.4, "token", "raceword"),
            ]
        )
        let turn2 = SessionFixture.record(raw: "a new answer with raceword embedded")
        let capture = SessionFixture.capture(id: "race-boundary", turns: [turn1, turn2], stopAfterIndex: 0)

        let first = detector.inspect([capture])
        let firstFP = first.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
        for i in 1..<10 {
            let next = detector.inspect([capture])
            let nextFP = next.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
            XCTAssertEqual(firstFP, nextFP, "boundary run \(i) differed")
        }
        XCTAssertFalse(first.isEmpty, "boundary must fire")
    }

    /// Adversarial: the user intentionally sent the same message twice.
    /// Turn 2's raw matches turn 1's raw (legitimate repetition), but no
    /// `stopRequested` step exists — must NOT fire.
    func test_adversarial_legitimateRepeatWithoutStopDoesNotFire() {
        let sameReply = "The capital of France is Paris."
        let turn1 = SessionFixture.record(
            raw: sameReply,
            events: [(0.0, "token", "The "), (0.3, "token", "capital of France is Paris.")]
        )
        let turn2 = SessionFixture.record(
            raw: sameReply,
            events: [(0.0, "token", "The "), (0.3, "token", "capital of France is Paris.")]
        )
        let capture = SessionFixture.capture(id: "race-adv", turns: [turn1, turn2], stopAfterIndex: nil)
        XCTAssertTrue(detector.inspect([capture]).isEmpty)
    }
}

// MARK: - SessionContextLeakDetector contract

final class SessionContextLeakDetectorContractTests: XCTestCase {

    private let detector = SessionContextLeakDetector()

    /// Positive: session A has a distinctive system prompt; session B's
    /// assistant output contains that system prompt verbatim.
    func test_positive_crossSessionLeakFires() {
        let secret = "The passphrase is octopus-melody-1928."
        let aTurn = SessionFixture.record(raw: "Acknowledged.", modelId: "m")
        let bTurn = SessionFixture.record(raw: "Sure — here's the answer. " + secret, modelId: "m")

        let aCapture = SessionFixture.capture(id: "A", turns: [aTurn], systemPrompt: secret, sessionLabel: "A")
        let bCapture = SessionFixture.capture(id: "B", turns: [bTurn], sessionLabel: "B")

        let findings = detector.inspect([aCapture, bCapture])
        XCTAssertFalse(findings.isEmpty)
    }

    /// Negative: two independent sessions with distinct prompts and outputs.
    func test_negative_independentSessionsDoNotFire() {
        let aTurn = SessionFixture.record(raw: "Sure, I'll help.", modelId: "m")
        let bTurn = SessionFixture.record(raw: "Here's a new idea.", modelId: "m")
        let a = SessionFixture.capture(id: "A", turns: [aTurn], systemPrompt: "Be concise about weather.", sessionLabel: "A")
        let b = SessionFixture.capture(id: "B", turns: [bTurn], systemPrompt: "Be verbose about cooking.", sessionLabel: "B")
        XCTAssertTrue(detector.inspect([a, b]).isEmpty)
    }

    /// Boundary: the secret is exactly `minLeakChars` long (16) and it
    /// appears in the other session's output. Must fire, deterministically.
    func test_boundary_deterministicAtExactThreshold() {
        let secret = "abcdefghijklmnop" // 16 chars
        precondition(secret.count == 16)
        let aTurn = SessionFixture.record(raw: "hi", modelId: "m")
        let bTurn = SessionFixture.record(raw: "answer: " + secret, modelId: "m")
        let a = SessionFixture.capture(id: "A", turns: [aTurn], systemPrompt: secret, sessionLabel: "A")
        let b = SessionFixture.capture(id: "B", turns: [bTurn], sessionLabel: "B")

        let first = detector.inspect([a, b])
        let firstFP = first.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
        for i in 1..<10 {
            let next = detector.inspect([a, b])
            let nextFP = next.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
            XCTAssertEqual(firstFP, nextFP, "boundary run \(i) differed")
        }
        XCTAssertFalse(first.isEmpty, "boundary must fire")
    }

    /// Adversarial: both sessions use a short boilerplate greeting
    /// ("Hello!") that's below the threshold and naturally shows up in both
    /// outputs. Must NOT fire.
    func test_adversarial_boilerplateGreetingDoesNotFire() {
        let greeting = "Hello!"
        let a = SessionFixture.capture(
            id: "A",
            turns: [SessionFixture.record(raw: "Hello! How can I help?", modelId: "m")],
            systemPrompt: greeting,
            sessionLabel: "A"
        )
        let b = SessionFixture.capture(
            id: "B",
            turns: [SessionFixture.record(raw: "Hello! What's on your mind?", modelId: "m")],
            systemPrompt: greeting,
            sessionLabel: "B"
        )
        XCTAssertTrue(detector.inspect([a, b]).isEmpty)
    }
}
