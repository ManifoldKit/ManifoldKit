import XCTest
import ManifoldAppEval

// MARK: - ResearchSessionCompressionDogfoodTests

/// The wave-1 dogfood (design v2 §5): MK's own flagship compression golden
/// (`RuntimeScenarioRegistry.researchSession`, the P4a Glass Box scenario)
/// re-expressed as a JSON fixture (`Fixtures/research-session-compression.json`)
/// and run through the full deterministic lane — schema load, mapper, scripted
/// backend, checkpoint scoring, and the report/ledger writers — proving the
/// harness end-to-end on a real MK scenario before any app adopts it.
///
/// The fixture mirrors `.researchSession`'s four turns and canned responses.
/// `FixedCountPreTurnCompressionPolicy(compressAfterMessages: 4)` is wired in
/// via `GoldenTaskRunner.run(preTurnCompressionPolicy:)` — the schema has no
/// field for a synthetic message-count compression trigger (see
/// `GoldenTaskRunner`'s doc comment on that parameter).
final class ResearchSessionCompressionDogfoodTests: XCTestCase {

    func test_researchSessionCompressionFixture_allCheckpointsPass() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "research-session-compression", withExtension: "json", subdirectory: "Fixtures")
        )
        let fixture = try GoldenTaskLoader.load(from: url)

        let outcome = try await GoldenTaskRunner.run(
            fixture,
            preTurnCompressionPolicy: FixedCountPreTurnCompressionPolicy(compressAfterMessages: 4)
        )

        XCTAssertEqual(outcome.checkpointResults.count, 2)

        for result in outcome.checkpointResults {
            for (assertion, score) in result.scores {
                if case .bool(false) = score.value {
                    XCTFail("checkpoint '\(result.checkpoint.displayLabel)' failed \(assertion): \(score.explanation ?? "no explanation")")
                }
            }
        }

        // The compression checkpoint specifically: proves the deterministic
        // lane actually drove FixedCountPreTurnCompressionPolicy and the
        // built-in expectedCompression scorer read its effect correctly.
        let compressionCheckpoint = try XCTUnwrap(
            outcome.checkpointResults.first { $0.checkpoint.afterTurnIndex == 2 }
        )
        let compressionScore = try XCTUnwrap(compressionCheckpoint.scores["expectedCompression"])
        XCTAssertEqual(compressionScore.value, .bool(true))
        let eventsScore = try XCTUnwrap(compressionCheckpoint.scores["expectedEvents"])
        XCTAssertEqual(eventsScore.value, .bool(true))
    }

    /// Sabotage-adjacent guard: an unrealistic minInsertedRecords bound must
    /// actually fail, proving the checkpoint is exercising real compression
    /// output and not vacuously passing.
    func test_researchSessionCompressionFixture_stricterBoundFails() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "research-session-compression", withExtension: "json", subdirectory: "Fixtures")
        )
        var fixture = try GoldenTaskLoader.load(from: url)
        fixture = GoldenTaskFixture(
            id: fixture.id,
            systemPrompt: fixture.systemPrompt,
            turns: fixture.turns,
            checkpoints: [
                GoldenCheckpoint(
                    afterTurnIndex: 2,
                    label: "unrealistic bound",
                    expectedCompression: GoldenExpectedCompression(minInsertedRecords: 99)
                ),
            ]
        )

        let outcome = try await GoldenTaskRunner.run(
            fixture,
            preTurnCompressionPolicy: FixedCountPreTurnCompressionPolicy(compressAfterMessages: 4)
        )

        let result = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(result.scores["expectedCompression"])
        XCTAssertEqual(score.value, .bool(false))
    }

    /// Also emits a report and ledger line for this fixture — the in-train
    /// consumer the design requires for the report/ledger surfaces (design v2
    /// item 4: "had no live consumer in the v1 train" was the API-quality
    /// finding this closes).
    func test_researchSessionCompressionFixture_emitsReportAndLedger() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "research-session-compression", withExtension: "json", subdirectory: "Fixtures")
        )
        let fixture = try GoldenTaskLoader.load(from: url)
        let outcome = try await GoldenTaskRunner.run(
            fixture,
            preTurnCompressionPolicy: FixedCountPreTurnCompressionPolicy(compressAfterMessages: 4)
        )
        let appEvalOutcome = AppEvalOutcome.make(from: [outcome])

        let report = AppEvalMarkdownRenderer.render(appEvalOutcome)
        XCTAssertTrue(report.contains("research-session-compression"))
        XCTAssertTrue(report.contains("# ManifoldAppEval Report"))

        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("appeval-dogfood-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        try AppEvalHistoryLedger.append(appEvalOutcome, to: ledgerURL)
        let entries = try AppEvalHistoryLedger.read(from: ledgerURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].fixtureID, "research-session-compression")
        XCTAssertEqual(entries[0].verdict, "pass")
    }
}
