import ManifoldInference

/// The typed result of one or more ``GoldenTaskRunner`` runs — the input to
/// ``AppEvalMarkdownRenderer`` and ``AppEvalHistoryLedger``.
///
/// Deliberately a plain data aggregate with no clock reads, no
/// non-deterministic ordering, and no formatting logic of its own — see
/// ``AppEvalMarkdownRenderer`` for the "pure function of a typed struct"
/// convention this is built to satisfy.
public struct AppEvalOutcome: Sendable {
    public let fixtures: [FixtureOutcome]
    public let verdict: AppEvalVerdict

    public init(fixtures: [FixtureOutcome]) {
        self.fixtures = fixtures
        self.verdict = AppEvalVerdict.aggregate(verdicts: fixtures.map(\.verdict))
    }

    /// Builds an outcome from one or more ``GoldenTaskRunner`` outcomes.
    public static func make(from runnerOutcomes: [GoldenTaskRunner.Outcome]) -> AppEvalOutcome {
        AppEvalOutcome(fixtures: runnerOutcomes.map(FixtureOutcome.init(runnerOutcome:)))
    }
}

/// One fixture's checkpoint results plus its aggregated verdict.
public struct FixtureOutcome: Sendable {
    public let fixtureID: String
    public let checkpoints: [CheckpointOutcome]
    public let verdict: AppEvalVerdict
    /// Non-nil only for ``AppEvalVerdict/error`` rows: a description of the
    /// load/map/run error that prevented this fixture from being evaluated.
    /// Errors are first-class rows (mirroring the absence convention), not a
    /// batch abort — see ``AppEvalRunner/run(_:probe:customScorers:toolExecutors:preTurnCompressionPolicy:)``.
    public let errorDescription: String?

    public init(fixtureID: String, checkpoints: [CheckpointOutcome]) {
        self.fixtureID = fixtureID
        self.checkpoints = checkpoints
        self.verdict = AppEvalVerdict.aggregate(checkpoints.flatMap { $0.scores.values })
        self.errorDescription = nil
    }

    /// An error row: the fixture could not be evaluated at all (mapper /
    /// loader / runner error). Distinct from a scoring failure so CI can tell
    /// "the gate caught a regression" from "the gate itself is broken".
    public init(fixtureID: String, errorDescription: String) {
        self.fixtureID = fixtureID
        self.checkpoints = []
        self.verdict = .error
        self.errorDescription = errorDescription
    }

    init(runnerOutcome: GoldenTaskRunner.Outcome) {
        self.init(
            fixtureID: runnerOutcome.fixture.id,
            checkpoints: runnerOutcome.checkpointResults.map(CheckpointOutcome.init(result:))
        )
    }
}

/// One checkpoint's scores, keyed by assertion/scorer id.
public struct CheckpointOutcome: Sendable {
    public let label: String
    public let afterTurnIndex: Int
    /// Scores keyed by ``BuiltInCheckpointAssertion/rawValue`` (built-ins) or
    /// the custom scorer's `id` — sorted by key before iteration wherever this
    /// is rendered (never dictionary-order, which is non-deterministic).
    public let scores: [String: Score]

    public init(label: String, afterTurnIndex: Int, scores: [String: Score]) {
        self.label = label
        self.afterTurnIndex = afterTurnIndex
        self.scores = scores
    }

    init(result: GoldenTaskRunner.CheckpointResult) {
        self.init(
            label: result.checkpoint.displayLabel,
            afterTurnIndex: result.checkpoint.afterTurnIndex,
            scores: result.scores
        )
    }
}
