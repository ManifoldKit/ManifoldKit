import ManifoldInference
import ManifoldRuntime

/// The batch entry point: runs a list of fixtures through
/// ``GoldenTaskRunner`` with **per-fixture error containment** and returns
/// one ``AppEvalOutcome`` ready for the renderer and ledger.
///
/// A fixture whose mapping or run throws does NOT abort the batch — it
/// becomes an ``AppEvalVerdict/error``-verdict ``FixtureOutcome`` row
/// (errors as first-class rows, the same convention as `.unavailable`
/// absence), so one malformed fixture can't hide the results of every
/// other fixture in the corpus.
@MainActor
public enum AppEvalRunner {

    /// Runs every fixture, containing per-fixture errors as `.error` rows.
    ///
    /// Parameters mirror
    /// ``GoldenTaskRunner/run(_:probe:customScorers:toolExecutors:preTurnCompressionPolicy:)``
    /// and apply to every fixture in the batch.
    public static func run(
        _ fixtures: [GoldenTaskFixture],
        probe: (any ScenarioStateProbe)? = nil,
        customScorers: [any CheckpointScorer] = [],
        toolExecutors: [any ToolExecutor] = [],
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil
    ) async -> AppEvalOutcome {
        var rows: [FixtureOutcome] = []
        for fixture in fixtures {
            do {
                let outcome = try await GoldenTaskRunner.run(
                    fixture,
                    probe: probe,
                    customScorers: customScorers,
                    toolExecutors: toolExecutors,
                    preTurnCompressionPolicy: preTurnCompressionPolicy
                )
                rows.append(FixtureOutcome(runnerOutcome: outcome))
            } catch {
                rows.append(FixtureOutcome(
                    fixtureID: fixture.id,
                    errorDescription: String(describing: error)
                ))
            }
        }
        return AppEvalOutcome(fixtures: rows)
    }
}
