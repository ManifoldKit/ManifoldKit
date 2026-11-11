import XCTest
import ManifoldAppEval
import ManifoldInference

final class AppEvalEvidenceTests: XCTestCase {
    func test_missingRequiredEvidenceAndEmptyRuns_areIndeterminate() async {
        XCTAssertEqual(AppEvalVerdict.aggregate([EvalScore]()), .indeterminate)
        XCTAssertEqual(AppEvalVerdict.aggregate([EvalScore(value: .unavailable)]), .indeterminate)
        XCTAssertEqual(AppEvalVerdict.aggregate([EvalScore(value: .number(1))]), .indeterminate)
        XCTAssertEqual(AppEvalOutcome(fixtures: []).verdict.exitCode, 3)
        let emptyRun = await AppEvalRunner.run([])
        XCTAssertEqual(emptyRun.verdict, .indeterminate)
        let empty = FixtureOutcome(fixtureID: "empty", checkpoints: [])
        XCTAssertEqual(empty.verdict, .indeterminate)
        let mixed = FixtureOutcome(fixtureID: "mixed", checkpoints: [
            CheckpointOutcome(label: "pass", afterTurnIndex: 0, scores: ["assertion": EvalScore(value: .bool(true))]),
            CheckpointOutcome(label: "empty", afterTurnIndex: 1, scores: [:]),
        ])
        XCTAssertEqual(mixed.verdict, .indeterminate)
    }

    func test_measuredFailureWinsOverIncompleteEvidenceAndError() {
        XCTAssertEqual(AppEvalVerdict.aggregate([
            EvalScore(value: .unavailable), EvalScore(value: .bool(false)),
        ]), .fail)
        XCTAssertEqual(AppEvalVerdict.aggregate(verdicts: [.indeterminate, .error, .fail]), .fail)
        XCTAssertEqual(AppEvalVerdict.aggregate(verdicts: [.pass, .indeterminate, .error]), .error)
        XCTAssertEqual(AppEvalVerdict.aggregate(verdicts: [.pass, .indeterminate]), .indeterminate)
    }

    func test_informationalMeasurementsAreExplicitAndNeverEstablishAPassAlone() {
        let info = CheckpointOutcome(
            label: "metrics", afterTurnIndex: 0,
            scores: ["latency": EvalScore(value: .number(999)), "optional": EvalScore(value: .unavailable)],
            informationalScoreIDs: ["latency", "optional"]
        )
        let required = CheckpointOutcome(label: "assertion", afterTurnIndex: 0, scores: ["ok": EvalScore(value: .bool(true))])
        let gate = FixtureOutcome(fixtureID: "gate", checkpoints: [required, info])
        XCTAssertEqual(gate.verdict, .pass)
        let diagnostic = FixtureOutcome(fixtureID: "diagnostic", checkpoints: [
            CheckpointOutcome(label: "fault injection", afterTurnIndex: 0, scores: ["expected-fault": EvalScore(value: .bool(false))]),
        ], isInformational: true)
        let outcome = AppEvalOutcome(fixtures: [gate, diagnostic])
        XCTAssertEqual(diagnostic.verdict, .fail)
        XCTAssertEqual(outcome.verdict, .pass)
        XCTAssertEqual(AppEvalOutcome(fixtures: [diagnostic]).verdict, .indeterminate)
        XCTAssertEqual(FixtureOutcome(fixtureID: "only-info", checkpoints: [info]).verdict, .indeterminate)
        let report = AppEvalMarkdownRenderer.render(outcome)
        XCTAssertTrue(report.contains("FAIL (informational)"))
        XCTAssertTrue(report.contains("999.0000 (informational)"))
    }

    private struct TranscriptScorer: CheckpointScorer {
        let id = "transcript"
        func score(_ context: CheckpointEvaluationContext) async -> EvalScore {
            guard let messages = context.producedMessages else {
                return EvalScore(value: .unavailable)
            }
            return EvalScore(value: .bool(
                context.systemPrompt == "executed system" &&
                messages.map(\.content) == ["hi", "hello"] &&
                messages.map(\.role) == [.user, .assistant]
            ))
        }
    }

    func test_runtimeTranscriptProjectionPreservesOrderedRolesAndContent() async {
        let fixture = GoldenTaskFixture(
            id: "transcript", systemPrompt: "executed system",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: [GoldenCheckpoint(afterTurnIndex: 0, custom: ["transcript": .null])]
        )
        let outcome = await AppEvalRunner.run([fixture], customScorers: [TranscriptScorer()])
        XCTAssertEqual(outcome.verdict, .pass)
    }

    func test_missingScorerIsIndeterminateThroughRealRunner() async {
        let fixture = GoldenTaskFixture(
            id: "missing-scorer", turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: [GoldenCheckpoint(afterTurnIndex: 0, custom: ["judge:missing": .object([:])])]
        )
        let outcome = await AppEvalRunner.run([fixture])
        XCTAssertEqual(outcome.verdict, .indeterminate)
        XCTAssertEqual(outcome.verdict.exitCode, 3)
        XCTAssertTrue(AppEvalMarkdownRenderer.render(outcome).contains("INDETERMINATE"))
    }

    func test_ledgerKeepsMissingEvidenceEvenWhenMeasuredFailureWins() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-evidence-ledger-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = AppEvalOutcome(fixtures: [FixtureOutcome(fixtureID: "mixed", checkpoints: [
            CheckpointOutcome(label: "mixed", afterTurnIndex: 0, scores: [
                "failure": EvalScore(value: .bool(false)), "missing": EvalScore(value: .unavailable),
                "annotation": EvalScore(value: .unavailable),
            ], informationalScoreIDs: ["annotation"]),
        ])])
        XCTAssertEqual(outcome.verdict, .fail)
        try AppEvalHistoryLedger.append(outcome, to: url)
        let entry = try XCTUnwrap(AppEvalHistoryLedger.read(from: url).first)
        XCTAssertEqual(entry.failingCheckpointLabels, ["mixed"])
        XCTAssertEqual(entry.indeterminateCheckpointLabels, ["mixed"])
    }

    func test_ledgerRetainsIncompleteAndInformationalStatus_readsLegacyRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-ledger-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = AppEvalOutcome(fixtures: [FixtureOutcome(fixtureID: "missing", checkpoints: [
            CheckpointOutcome(label: "snapshot", afterTurnIndex: 0, scores: ["graph": EvalScore(value: .unavailable)]),
        ]), FixtureOutcome(fixtureID: "diagnostic", checkpoints: [], isInformational: true)])
        try AppEvalHistoryLedger.append(outcome, to: url)
        let entries = try AppEvalHistoryLedger.read(from: url)
        XCTAssertEqual(entries.first { $0.fixtureID == "missing" }?.verdict, "indeterminate")
        XCTAssertEqual(entries.first { $0.fixtureID == "missing" }?.indeterminateCheckpointLabels, ["snapshot"])
        XCTAssertEqual(entries.first { $0.fixtureID == "diagnostic" }?.isInformational, true)
        let legacy = #"{"schemaVersion":1,"fixtureID":"legacy","checkpointCount":1,"verdict":"pass"}"#
        let decoded = try JSONDecoder().decode(AppEvalLedgerEntry.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertFalse(decoded.isInformational)
        XCTAssertNil(decoded.indeterminateCheckpointLabels)
    }
}
