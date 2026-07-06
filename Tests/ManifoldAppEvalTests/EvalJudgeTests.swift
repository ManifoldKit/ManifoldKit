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
/// absence cases (no judge wired, no matching payload, malformed payload),
/// judge-failure handling, and verdict-flag surfacing in the rendered report.
final class EvalJudgeTests: XCTestCase {

    private func makeContext(
        checkpoint: GoldenCheckpoint,
        visibleText: String = ""
    ) -> CheckpointEvaluationContext {
        CheckpointEvaluationContext(
            output: EvalRunOutput(visibleText: visibleText),
            snapshot: nil,
            checkpoint: checkpoint,
            eventKinds: [],
            producedMessageCount: 0,
            lastContextAssembledSlotCount: nil,
            lastCompressionInsertedRecordCount: nil
        )
    }

    private func judgedCheckpoint(payload: [String: JSONValue]? = nil) -> GoldenCheckpoint {
        GoldenCheckpoint(
            afterTurnIndex: 0,
            label: "extraction quality",
            custom: payload.map { ["judge:extraction-quality": .object($0)] }
        )
    }

    private let validPayload: [String: JSONValue] = [
        "content": .string("A knight enters the tavern."),
        "candidate": .string(#"{"addedEntities":["knight"]}"#),
        "reference": .string(#"{"addedEntities":["knight","tavern"]}"#),
        "rubric": .string("Score 1.0 if every entity in reference is present in candidate."),
    ]

    // MARK: - Full path: fixture → judged checkpoint → verdict → Score

    func test_fullPath_fixtureThroughGoldenTaskRunner_producesJudgeScore() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.75, rationale: "missing tavern", flags: ["missed_entity"]))
        let fixture = GoldenTaskFixture(
            id: "extraction-fixture",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: [judgedCheckpoint(payload: validPayload)]
        )

        let outcome = try await GoldenTaskRunner.run(
            fixture,
            customScorers: [
                JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: fixture.id, judge: judge),
            ]
        )

        let checkpointResult = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(checkpointResult.scores["judge:extraction-quality"])
        XCTAssertEqual(score.value, .number(0.75))
        XCTAssertEqual(score.explanation, "missing tavern")
        XCTAssertEqual(score.metadata["flags"], "missed_entity")

        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 1)
        let received = await judge.receivedRequests
        XCTAssertEqual(received.first?.id, "extraction-fixture#extraction quality")
        XCTAssertEqual(received.first?.candidate, #"{"addedEntities":["knight"]}"#)
        XCTAssertEqual(received.first?.reference, #"{"addedEntities":["knight","tavern"]}"#)
    }

    func test_directScore_passingVerdict() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 1.0, rationale: "perfect match"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: "f", judge: judge)
        let context = makeContext(checkpoint: judgedCheckpoint(payload: validPayload))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .number(1.0))
        XCTAssertEqual(score.explanation, "perfect match")
    }

    // MARK: - Absence: no judge registered

    func test_absentJudge_scoresUnavailable_neverZeroOrPass() async throws {
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: "f", judge: nil)
        let context = makeContext(checkpoint: judgedCheckpoint(payload: validPayload))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .unavailable)
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("no EvalJudge registered"), explanation)
    }

    // MARK: - Absence: no matching custom payload

    func test_noMatchingPayload_scoresUnavailable() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 1.0, rationale: "n/a"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: "f", judge: judge)
        // Checkpoint declares no `custom` payload at all.
        let context = makeContext(checkpoint: GoldenCheckpoint(afterTurnIndex: 0))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .unavailable)
        let callCount = await judge.callCount
        XCTAssertEqual(callCount, 0, "a scorer with no matching payload must never invoke the judge")
    }

    // MARK: - Malformed payload

    func test_malformedPayload_missingCandidate_scoresUnavailable() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 1.0, rationale: "n/a"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: "f", judge: judge)
        let malformed: [String: JSONValue] = ["rubric": .string("grade it")]
        let context = makeContext(checkpoint: judgedCheckpoint(payload: malformed))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .unavailable)
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("judge-request object"), explanation)
    }

    // MARK: - Judge failure (throws)

    func test_judgeThrows_scoresUnavailable_neverBoolFalse() async throws {
        let judge = RecordingJudge(throwing: StubJudgeError(description: "subprocess timed out"))
        let scorer = JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: "f", judge: judge)
        let context = makeContext(checkpoint: judgedCheckpoint(payload: validPayload))

        let score = await scorer.score(context)
        XCTAssertEqual(score.value, .unavailable, "a transport failure must never read as a failing assertion")
        let explanation = try XCTUnwrap(score.explanation)
        XCTAssertTrue(explanation.contains("subprocess timed out"), explanation)
    }

    // MARK: - Verdict-flag surfacing in the rendered report

    func test_verdictFlags_surfaceInRenderedReport() async throws {
        let judge = RecordingJudge(verdict: JudgeVerdict(score: 0.4, rationale: "hallucinated a fact", flags: ["hallucinated_entity", "wrong_fact_value"]))
        let fixture = GoldenTaskFixture(
            id: "flagged-fixture",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: [judgedCheckpoint(payload: validPayload)]
        )

        let outcome = await AppEvalRunner.run(
            [fixture],
            customScorers: [
                JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: fixture.id, judge: judge),
            ]
        )

        let report = AppEvalMarkdownRenderer.render(outcome)
        XCTAssertTrue(report.contains("hallucinated a fact"), report)
        XCTAssertTrue(report.contains("hallucinated_entity"), report)
        XCTAssertTrue(report.contains("wrong_fact_value"), report)
    }
}
