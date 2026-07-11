import XCTest
import ManifoldInference
import ManifoldAppEval

// MARK: - GoldenTaskRunnerContentMatchOptionsTests

/// Proves ``CheckpointEvaluationContext/latestTurnVisibleText`` is actually
/// wired by ``GoldenTaskRunner`` (issue #2201) — not just a field a hand-built
/// unit-test context can set. A custom scorer captures the real context
/// produced by a genuine two-turn run and feeds it back through
/// ``BuiltInCheckpointScorers/ContentMatchOptions``, confirming the harness's
/// own transcript-slicing (not a test fixture) produces the scope split.
final class GoldenTaskRunnerContentMatchOptionsTests: XCTestCase {

    private struct CapturingScorer: CheckpointScorer {
        let id = "capture-context"
        let onCapture: @Sendable (CheckpointEvaluationContext) -> Void
        func score(_ context: CheckpointEvaluationContext) async -> EvalScore {
            onCapture(context)
            return EvalScore(value: .bool(true))
        }
    }

    /// Two-turn fixture: turn 0's assistant reply mentions an
    /// "earlier-turn-only-phrase"; turn 1's reply mentions "latest-turn-phrase"
    /// only. The checkpoint sits after turn 1.
    private func twoTurnFixture() -> GoldenTaskFixture {
        GoldenTaskFixture(
            id: "content-match-options-live-wiring",
            turns: [
                GoldenTurn(kind: .send, text: "first", cannedResponse: "earlier-turn-only-phrase"),
                GoldenTurn(kind: .send, text: "second", cannedResponse: "latest-turn-phrase"),
            ],
            checkpoints: [
                GoldenCheckpoint(afterTurnIndex: 1, custom: ["capture-context": .bool(true)]),
            ]
        )
    }

    func test_latestTurnVisibleText_isPopulatedByRealRun_andExcludesEarlierTurnText() async throws {
        var captured: CheckpointEvaluationContext?
        let scorer = CapturingScorer { context in captured = context }

        _ = try await GoldenTaskRunner.run(twoTurnFixture(), customScorers: [scorer])

        let context = try XCTUnwrap(captured, "GoldenTaskRunner must invoke the custom scorer with a real context")

        // Cumulative (output.visibleText) sees both turns' text.
        XCTAssertTrue(context.output.visibleText.contains("earlier-turn-only-phrase"))
        XCTAssertTrue(context.output.visibleText.contains("latest-turn-phrase"))

        // latestTurnVisibleText, populated by GoldenTaskRunner's own
        // evaluationContext(for:runResult:fixtureID:), must exclude turn 0's text.
        XCTAssertFalse(
            context.latestTurnVisibleText.contains("earlier-turn-only-phrase"),
            "latestTurnVisibleText leaked an earlier turn's text: \(context.latestTurnVisibleText)"
        )
        XCTAssertTrue(context.latestTurnVisibleText.contains("latest-turn-phrase"))
    }

    /// Same real run, but drives the verdict flip through the public
    /// `ContentMatchOptions` seam a consumer (e.g. Fireside) would actually use.
    func test_realRun_requiredContent_latestTurnScope_flipsVerdict_vsCumulativeDefault() async throws {
        var captured: CheckpointEvaluationContext?
        let scorer = CapturingScorer { context in captured = context }

        _ = try await GoldenTaskRunner.run(twoTurnFixture(), customScorers: [scorer])
        let context = try XCTUnwrap(captured)

        let checkpointWithRequirement = GoldenCheckpoint(
            afterTurnIndex: 1,
            requiredContent: ["earlier-turn-only-phrase"]
        )
        let contextForAssertion = CheckpointEvaluationContext(
            output: context.output,
            snapshot: context.snapshot,
            checkpoint: checkpointWithRequirement,
            eventKinds: context.eventKinds,
            producedMessageCount: context.producedMessageCount,
            lastContextAssembledSlotCount: context.lastContextAssembledSlotCount,
            lastCompressionInsertedRecordCount: context.lastCompressionInsertedRecordCount,
            fixtureID: context.fixtureID,
            latestTurnVisibleText: context.latestTurnVisibleText
        )

        let defaultScore = try XCTUnwrap(BuiltInCheckpointScorers.scoreRequiredContent(contextForAssertion))
        XCTAssertEqual(defaultScore.value, .bool(true), "default cumulative scope should see turn 0's text")

        let latestTurnScore = try XCTUnwrap(
            BuiltInCheckpointScorers.scoreRequiredContent(
                contextForAssertion,
                options: .init(scope: .latestTurn)
            )
        )
        XCTAssertEqual(latestTurnScore.value, .bool(false), "latestTurn scope should not see turn 0's text via a real run")
    }
}
