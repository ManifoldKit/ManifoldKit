import XCTest
import ManifoldInference
import ManifoldAppEval

// MARK: - ScenarioStateProbeTests

/// Exercises the state-probe seam end-to-end through ``GoldenTaskRunner``:
/// a fake probe returns an opaque snapshot, and a custom scorer reads it back
/// via ``CheckpointEvaluationContext/snapshot``.
final class ScenarioStateProbeTests: XCTestCase {

    private struct FakeSnapshot: Sendable {
        let extractedFactCount: Int
    }

    private struct FakeProbe: ScenarioStateProbe {
        let factCount: Int
        func snapshot(after checkpoint: GoldenCheckpoint, runResult: RuntimeScenarioRunner.Result) async -> (any Sendable)? {
            FakeSnapshot(extractedFactCount: factCount)
        }
    }

    private struct FactCountScorer: CheckpointScorer {
        let id = "fact-count"
        func score(_ context: CheckpointEvaluationContext) async -> EvalScore {
            guard let snapshot = context.snapshot as? FakeSnapshot else {
                return EvalScore(value: .unavailable, explanation: "no FakeSnapshot present")
            }
            return EvalScore(value: .bool(snapshot.extractedFactCount >= 1))
        }
    }

    private func makeFixture(customPayload: JSONValue) -> GoldenTaskFixture {
        GoldenTaskFixture(
            id: "probe-seam",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: [
                GoldenCheckpoint(afterTurnIndex: 0, custom: ["fact-count": customPayload]),
            ]
        )
    }

    func test_probe_snapshotReachesCustomScorer() async throws {
        let fixture = makeFixture(customPayload: .bool(true))
        let outcome = try await GoldenTaskRunner.run(
            fixture,
            probe: FakeProbe(factCount: 2),
            customScorers: [FactCountScorer()]
        )

        let checkpoint = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(checkpoint.scores["fact-count"])
        XCTAssertEqual(score.value, .bool(true))
    }

    func test_noProbeRegistered_scoresUnavailable_notZero() async throws {
        let fixture = makeFixture(customPayload: .bool(true))
        let outcome = try await GoldenTaskRunner.run(
            fixture,
            probe: nil,
            customScorers: [FactCountScorer()]
        )

        let checkpoint = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(checkpoint.scores["fact-count"])
        // Absence must never read as a numeric/boolean failure — it is its
        // own distinct state.
        XCTAssertEqual(score.value, .unavailable)
    }

    func test_customKeyWithNoRegisteredScorer_scoresUnavailable() async throws {
        let fixture = makeFixture(customPayload: .bool(true))
        let outcome = try await GoldenTaskRunner.run(fixture, probe: FakeProbe(factCount: 2), customScorers: [])

        let checkpoint = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(checkpoint.scores["fact-count"])
        XCTAssertEqual(score.value, .unavailable)
    }
}
