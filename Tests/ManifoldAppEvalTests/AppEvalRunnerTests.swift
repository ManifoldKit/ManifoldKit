import XCTest
import ManifoldInference
import ManifoldAppEval

// MARK: - AppEvalRunnerTests

/// Per-fixture error containment (`AppEvalRunner.run`) plus the
/// scorer-registration validation at `GoldenTaskRunner.run`'s public
/// boundary.
final class AppEvalRunnerTests: XCTestCase {

    private func goodFixture(id: String) -> GoldenTaskFixture {
        GoldenTaskFixture(
            id: id,
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: [GoldenCheckpoint(afterTurnIndex: 0, requiredContent: ["hello"])]
        )
    }

    /// A fixture whose mapping throws (an `.edit` turn, unmappable in wave 1).
    private func malformedFixture(id: String) -> GoldenTaskFixture {
        GoldenTaskFixture(
            id: id,
            turns: [GoldenTurn(kind: .edit, text: "replacement")],
            checkpoints: []
        )
    }

    // MARK: - Error containment (M5)

    func test_run_containsMalformedFixtureAsErrorRow_batchContinues() async throws {
        let outcome = await AppEvalRunner.run([
            goodFixture(id: "alpha-good"),
            malformedFixture(id: "beta-broken"),
            goodFixture(id: "gamma-good"),
        ])

        XCTAssertEqual(outcome.fixtures.count, 3, "one bad fixture must not abort the batch")

        let errorRow = try XCTUnwrap(outcome.fixtures.first { $0.fixtureID == "beta-broken" })
        XCTAssertEqual(errorRow.verdict, .error)
        let description = try XCTUnwrap(errorRow.errorDescription)
        XCTAssertTrue(description.contains("edit"), "error row should carry the mapper's diagnostic: \(description)")
        XCTAssertTrue(errorRow.checkpoints.isEmpty)

        let goodRows = outcome.fixtures.filter { $0.fixtureID != "beta-broken" }
        for row in goodRows {
            XCTAssertEqual(row.verdict, .pass, "\(row.fixtureID) should still evaluate normally")
            XCTAssertNil(row.errorDescription)
        }

        // Aggregate: error present, no fail → .error, exit code 2.
        XCTAssertEqual(outcome.verdict, .error)
        XCTAssertEqual(outcome.verdict.exitCode, 2)
    }

    func test_run_failBeatsErrorInAggregate() async throws {
        var failing = goodFixture(id: "delta-failing")
        failing = GoldenTaskFixture(
            id: failing.id,
            turns: failing.turns,
            checkpoints: [GoldenCheckpoint(afterTurnIndex: 0, requiredContent: ["never-appears"])]
        )
        let outcome = await AppEvalRunner.run([failing, malformedFixture(id: "epsilon-broken")])

        XCTAssertEqual(outcome.verdict, .fail, "a real assertion failure outranks a broken fixture in the aggregate")
        XCTAssertEqual(outcome.verdict.exitCode, 1)
    }

    func test_run_allGood_passVerdictAndExitCodeZero() async throws {
        let outcome = await AppEvalRunner.run([goodFixture(id: "zeta-good")])
        XCTAssertEqual(outcome.verdict, .pass)
        XCTAssertEqual(outcome.verdict.exitCode, 0)
    }

    func test_errorRow_rendersAndLedgersAsError() async throws {
        let outcome = await AppEvalRunner.run([malformedFixture(id: "eta-broken")])

        let report = AppEvalMarkdownRenderer.render(outcome)
        XCTAssertTrue(report.contains("**Fixture verdict: ERROR**"), report)
        XCTAssertTrue(report.contains("edit"), "the contained error must be visible in the report")

        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("appeval-error-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        try AppEvalHistoryLedger.append(outcome, to: ledgerURL)
        let entries = try AppEvalHistoryLedger.read(from: ledgerURL)
        XCTAssertEqual(entries.first?.verdict, "error")
    }

    // MARK: - Scorer-registration validation (M10)

    private struct StubScorer: CheckpointScorer {
        let id: String
        func score(_ context: CheckpointEvaluationContext) async -> Score {
            Score(value: .bool(true))
        }
    }

    func test_duplicateCustomScorerIDs_throwDescriptiveError() async {
        do {
            _ = try await GoldenTaskRunner.run(
                goodFixture(id: "dup-scorers"),
                customScorers: [StubScorer(id: "same"), StubScorer(id: "same")]
            )
            XCTFail("expected ScorerRegistrationError.duplicateScorerID")
        } catch let error as GoldenTaskRunner.ScorerRegistrationError {
            guard case .duplicateScorerID(let id) = error else {
                return XCTFail("expected .duplicateScorerID, got \(error)")
            }
            XCTAssertEqual(id, "same")
        } catch {
            XCTFail("expected ScorerRegistrationError, got \(error)")
        }
    }

    func test_customScorerIDCollidingWithBuiltInKey_throwsDescriptiveError() async {
        do {
            _ = try await GoldenTaskRunner.run(
                goodFixture(id: "reserved-scorer"),
                customScorers: [StubScorer(id: "expectedCompression")]
            )
            XCTFail("expected ScorerRegistrationError.reservedScorerID")
        } catch let error as GoldenTaskRunner.ScorerRegistrationError {
            guard case .reservedScorerID(let id) = error else {
                return XCTFail("expected .reservedScorerID, got \(error)")
            }
            XCTAssertEqual(id, "expectedCompression")
        } catch {
            XCTFail("expected ScorerRegistrationError, got \(error)")
        }
    }
}
