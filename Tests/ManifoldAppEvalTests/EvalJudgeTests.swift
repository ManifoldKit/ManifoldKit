import XCTest
import ManifoldInference
import ManifoldRuntime
import ManifoldAppEval

// MARK: - RecordingJudge

/// A fake `EvalJudge` conformer: records every request it sees and answers
/// with either a fixed verdict or a thrown error, per test. Standing in for
/// fireside's `ClaudeCodeJudge` (a real subprocess judge, which stays in
/// fireside — see `EvalJudge`'s doc comment) so this module's tests can
/// exercise the full seam without invoking anything.
actor RecordingJudge: EvalJudge {
    private(set) var receivedRequests: [JudgeRequest] = []
    private(set) var callCount = 0
    private let verdict: JudgeVerdict
    private let errorToThrow: Error?

    init(verdict: JudgeVerdict) {
        self.verdict = verdict
        self.errorToThrow = nil
    }

    init(throwing error: Error) {
        self.verdict = JudgeVerdict(score: 0, rationale: "unused")
        self.errorToThrow = error
    }

    func judge(_ request: JudgeRequest) async throws -> JudgeVerdict {
        callCount += 1
        receivedRequests.append(request)
        if let errorToThrow {
            throw errorToThrow
        }
        return verdict
    }
}

struct StubJudgeError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - EvalJudgeTests

/// End-to-end coverage of the wave-2a judge seam: `JudgedCheckpointScorer`
/// routing a fixture's `custom` payload to a registered `EvalJudge`, the
/// minScore pass-bar reduction (a judge score must always carry verdict
/// weight — the B1 anti-inert guarantee), the absence cases (no judge wired,
/// no matching payload, malformed payload), judge-failure handling, and
/// verdict-flag surfacing in the rendered report.
final class EvalJudgeTests: XCTestCase {

    private func makeContext(
        checkpoint: GoldenCheckpoint,
        visibleText: String = "",
        fixtureID: String = "f"
    ) -> CheckpointEvaluationContext {
        CheckpointEvaluationContext(
            output: EvalRunOutput(visibleText: visibleText),
            snapshot: nil,
            checkpoint: checkpoint,
            eventKinds: [],
            producedMessageCount: 0,
            lastContextAssembledSlotCount: nil,
            lastCompressionInsertedRecordCount: nil,
            fixtureID: fixtureID
        )
    }

    private func judgedCheckpoint(payload: [String: JSONValue]? = nil) -> GoldenCheckpoint {
        GoldenCheckpoint(
            afterTurnIndex: 0,
            label: "extraction quality",
            custom: payload.map { ["judge:extraction-quality": .object($0)] }
        )
    }

    /// A valid judged payload with a 0.7 pass bar.
    private let validPayload: [String: JSONValue] = [
        "content": .string("A knight enters the tavern."),
        "candidate": .string(#"{"addedEntities":["knight"]}"#),
        "reference": .string(#"{"addedEntities":["knight","tavern"]}"#),
        "rubric": .string("Score 1.0 if every entity in reference is present in candidate."),
        "minScore": .number(0.7),
    ]

    private func judgedFixture(id: String) -> GoldenTaskFixture {
        GoldenTaskFixture(
            id: id,
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: [judgedCheckpoint(payload: validPayload)]
        )
    }

    // MARK: - Full path: fixture → judged checkpoint → verdict → EvalScore

    func test_fullPath_scoreAboveBar_passes() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.9, rationale: "all entities present"))
        let fixture = judgedFixture(id: "extraction-fixture")

        let outcome = try await GoldenTaskRunner.run(
            fixture,
            customScorers: [
                JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge),
            ]
        )

        let checkpointResult = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(checkpointResult.scores["judge:extraction-quality"])
        XCTAssertEqual(score.value, .bool(true), "0.9 >= minScore 0.7 must pass")
        // The raw number stays visible even though the verdict is boolean.
        XCTAssertEqual(score.metadata["judgeScore"], "0.9000")
        XCTAssertEqual(score.metadata["minScore"], "0.7000")
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("all entities present"), explanation)

        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 1)
        let received = await judge.receivedRequests
        // Request id is derived from the runner-supplied fixture id, not a
        // constructor parameter — no drift possible.
        XCTAssertEqual(received.first?.id, "extraction-fixture#extraction quality")
        XCTAssertEqual(received.first?.candidate, #"{"addedEntities":["knight"]}"#)
        XCTAssertEqual(received.first?.reference, #"{"addedEntities":["knight","tavern"]}"#)
    }

    /// The B1 sabotage bar: a judge hardcoded to 0.0 must FAIL the fixture
    /// (verdict .fail, exit code 1) — never sail through as a verdict-inert
    /// `.number(0)` inside a passing outcome.
    func test_fullPath_scoreBelowBar_failsFixture_exitCode1() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.0, rationale: "hallucinated everything"))
        let fixture = judgedFixture(id: "zero-score-fixture")

        let outcome = await AppEvalRunner.run(
            [fixture],
            customScorers: [
                JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge),
            ]
        )

        XCTAssertEqual(outcome.verdict, .fail, "a 0.0 judge score below the bar must fail the aggregate verdict")
        XCTAssertEqual(outcome.verdict.exitCode, 1)

        let fixtureRow = try XCTUnwrap(outcome.fixtures.first)
        XCTAssertEqual(fixtureRow.verdict, .fail)
        let checkpoint = try XCTUnwrap(fixtureRow.checkpoints.first)
        let score = try XCTUnwrap(checkpoint.scores["judge:extraction-quality"])
        XCTAssertEqual(score.value, .bool(false))
        XCTAssertEqual(score.metadata["judgeScore"], "0.0000")
    }

    func test_directScore_exactlyAtBar_passes() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.7, rationale: "borderline"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge)
        let context = makeContext(checkpoint: judgedCheckpoint(payload: validPayload))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .bool(true), "score == minScore is a pass (>=, not >)")
    }

    // MARK: - Missing minScore: an invalid declaration must fail, never pass

    func test_missingMinScore_failsCheckpoint_withValidationExplanation() async throws {
        var payload = validPayload
        payload["minScore"] = nil
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 1.0, rationale: "would have passed"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge)
        let context = makeContext(checkpoint: judgedCheckpoint(payload: payload))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .bool(false), "a judge assertion with no pass bar must never be able to pass")
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("minScore"), explanation)
        XCTAssertEqual(score.metadata["reason"], "missing-minScore")
        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 0, "an invalid declaration must not bill a judge call")
    }

    func test_missingMinScore_failsFixtureVerdict() async throws {
        var payload = validPayload
        payload["minScore"] = nil
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 1.0, rationale: "unused"))
        let fixture = GoldenTaskFixture(
            id: "barless-fixture",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: [judgedCheckpoint(payload: payload)]
        )

        let outcome = await AppEvalRunner.run(
            [fixture],
            customScorers: [JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge)]
        )
        XCTAssertEqual(outcome.verdict, .fail)
        XCTAssertEqual(outcome.verdict.exitCode, 1)
    }

    // MARK: - Absence: no judge registered

    func test_absentJudge_scoresUnavailable_neverZeroOrPass() async throws {
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", judge: nil)
        let context = makeContext(checkpoint: judgedCheckpoint(payload: validPayload))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .unavailable)
        XCTAssertEqual(score.metadata["reason"], "judge-absent")
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("no EvalJudge registered"), explanation)
    }

    // MARK: - Absence: no matching custom payload

    func test_noMatchingPayload_scoresUnavailable() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 1.0, rationale: "n/a"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge)
        // Checkpoint declares no `custom` payload at all.
        let context = makeContext(checkpoint: GoldenCheckpoint(afterTurnIndex: 0))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .unavailable)
        XCTAssertEqual(score.metadata["reason"], "no-payload")
        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 0, "a scorer with no matching payload must never invoke the judge")
    }

    // MARK: - Malformed payload

    func test_malformedPayload_missingCandidate_scoresUnavailable() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 1.0, rationale: "n/a"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge)
        let malformed: [String: JSONValue] = ["rubric": .string("grade it"), "minScore": .number(0.5)]
        let context = makeContext(checkpoint: judgedCheckpoint(payload: malformed))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .unavailable)
        XCTAssertEqual(score.metadata["reason"], "invalid-payload")
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("judge-request object"), explanation)
    }

    // MARK: - Judge failure (throws)

    func test_judgeThrows_scoresUnavailable_neverBoolFalse() async throws {
        let judge = RecordingJudge(throwing: StubJudgeError(description: "subprocess timed out"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge)
        let context = makeContext(checkpoint: judgedCheckpoint(payload: validPayload))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .unavailable, "a transport failure must never read as a failing assertion")
        XCTAssertEqual(score.metadata["reason"], "judge-error")
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("subprocess timed out"), explanation)
    }

    // MARK: - Verdict-flag surfacing in the rendered report

    func test_verdictFlagsAndRawScore_surfaceInRenderedReport() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.4, rationale: "hallucinated a fact", flags: ["hallucinated_entity", "wrong_fact_value"]))
        let fixture = judgedFixture(id: "flagged-fixture")

        let outcome = await AppEvalRunner.run(
            [fixture],
            customScorers: [
                JudgedCheckpointScorer(id: "judge:extraction-quality", judge: judge),
            ]
        )

        // 0.4 < 0.7 bar: a verdict-bearing failure...
        XCTAssertEqual(outcome.verdict, .fail)

        // ...with the rationale, flags, and RAW numeric score all still
        // visible in the rendered report despite the boolean reduction.
        let report = AppEvalMarkdownRenderer.render(outcome)
        XCTAssertTrue(report.contains("hallucinated a fact"), report)
        XCTAssertTrue(report.contains("hallucinated_entity"), report)
        XCTAssertTrue(report.contains("wrong_fact_value"), report)
        XCTAssertTrue(report.contains("0.4000"), "raw judge score must stay visible in the report: \(report)")
    }
}
