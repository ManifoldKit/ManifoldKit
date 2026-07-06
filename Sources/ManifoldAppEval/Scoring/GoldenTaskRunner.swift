import Foundation
import ManifoldInference
import ManifoldRuntime

/// Drives a ``GoldenTaskFixture`` through the deterministic lane and scores
/// every checkpoint.
///
/// ## Why re-running a growing turn prefix per checkpoint
///
/// Each checkpoint is evaluated by running the *scripted* scenario from turn
/// 0 through `checkpoint.afterTurnIndex` (inclusive) — a fresh
/// ``ConversationRuntime`` + in-memory store each time — rather than
/// interjecting into one continuous run. Because ``ScriptedGenerationBackend``
/// is fully deterministic, replaying a prefix reproduces byte-identical state
/// to "the same point in one continuous run," so this is not an
/// approximation — it trades O(n) re-execution (fixtures are unit-test scale;
/// this is cheap) for not needing to expose any partial/resumable execution
/// API on ``RuntimeScenarioRunner``, which stays a stable, minimal surface
/// also directly proven by MK's own 11-scenario registry and test suites.
///
/// The byte-identical-replay claim assumes the injected
/// `preTurnCompressionPolicy` and `toolExecutors` are *stateless* (value
/// types or effectively-pure conformances, like every built-in) — a stateful
/// class conformance would leak state across the per-checkpoint replays and
/// break the equivalence. Keep injections stateless.
@MainActor
public enum GoldenTaskRunner {

    public struct CheckpointResult: Sendable {
        public let checkpoint: GoldenCheckpoint
        /// Built-in scores keyed by ``BuiltInCheckpointAssertion/rawValue``,
        /// plus custom scores keyed by the app-registered scorer's `id`.
        /// Only assertion kinds the checkpoint actually declares are present.
        public let scores: [String: Score]

        public init(checkpoint: GoldenCheckpoint, scores: [String: Score]) {
            self.checkpoint = checkpoint
            self.scores = scores
        }
    }

    public struct Outcome: Sendable {
        public let fixture: GoldenTaskFixture
        public let checkpointResults: [CheckpointResult]

        public init(fixture: GoldenTaskFixture, checkpointResults: [CheckpointResult]) {
            self.fixture = fixture
            self.checkpointResults = checkpointResults
        }
    }

    public enum ScorerRegistrationError: Error, CustomStringConvertible {
        /// Two `customScorers` entries declared the same `id`.
        case duplicateScorerID(String)
        /// A custom scorer's `id` collides with a built-in checkpoint
        /// assertion key (``BuiltInCheckpointAssertion``) — the score map
        /// keys both by the same string, so the collision would silently
        /// overwrite one with the other.
        case reservedScorerID(String)

        public var description: String {
            switch self {
            case .duplicateScorerID(let id):
                return "GoldenTaskRunner: two customScorers declare the same id '\(id)'"
            case .reservedScorerID(let id):
                return "GoldenTaskRunner: customScorer id '\(id)' collides with a built-in checkpoint assertion key — pick a different id"
            }
        }
    }

    /// Runs every checkpoint in `fixture` and scores it.
    ///
    /// - Parameters:
    ///   - probe: Optional app-supplied state probe, called once per
    ///     checkpoint after driving the prefix scenario.
    ///   - customScorers: App-registered scorers, dispatched by
    ///     ``GoldenCheckpoint/custom`` key. A `custom` key with no matching
    ///     scorer id scores `.unavailable`. Duplicate ids, or ids that
    ///     collide with built-in assertion keys, throw
    ///     ``ScorerRegistrationError``.
    ///   - toolExecutors: Executors registered for the run's tool round
    ///     trips, in addition to any synthetic fixed-response executors the
    ///     mapper builds from ``GoldenScriptedToolCall/result`` payloads. A
    ///     caller-supplied executor wins over a synthetic one with the same
    ///     tool name, so an app can exercise its real executor against a
    ///     scripted call.
    ///   - preTurnCompressionPolicy: Optional override wired into the mapped
    ///     scenario before running. The declarative schema has no field for
    ///     this — a synthetic message-count-triggered compression policy is
    ///     an artifact of driving compression deterministically in a scripted
    ///     lane, not a portable fixture concept — so fixtures that need
    ///     compression to fire deterministically (the wave-1 dogfood) supply
    ///     one here rather than in JSON.
    public static func run(
        _ fixture: GoldenTaskFixture,
        probe: (any ScenarioStateProbe)? = nil,
        customScorers: [any CheckpointScorer] = [],
        toolExecutors: [any ToolExecutor] = [],
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil
    ) async throws -> Outcome {
        let mapped = try GoldenTaskMapper.mapGrouped(fixture)
        let scorersByID = try validatedScorers(customScorers)
        let mergedExecutors = mergeExecutors(caller: toolExecutors, synthetic: mapped.syntheticToolExecutors)

        var results: [CheckpointResult] = []
        for checkpoint in fixture.checkpoints {
            let prefixScenario = try prefixScenario(
                fixture: fixture,
                mapped: mapped,
                throughTurnIndex: checkpoint.afterTurnIndex,
                toolExecutors: mergedExecutors,
                preTurnCompressionPolicy: preTurnCompressionPolicy
            )
            let runResult = try await RuntimeScenarioRunner.run(prefixScenario)

            let context = evaluationContext(for: checkpoint, runResult: runResult, fixtureID: fixture.id)
            let snapshot = await probe?.snapshot(after: checkpoint, runResult: runResult)
            let contextWithSnapshot = CheckpointEvaluationContext(
                output: context.output,
                snapshot: snapshot,
                checkpoint: context.checkpoint,
                eventKinds: context.eventKinds,
                producedMessageCount: context.producedMessageCount,
                lastContextAssembledSlotCount: context.lastContextAssembledSlotCount,
                lastCompressionInsertedRecordCount: context.lastCompressionInsertedRecordCount,
                fixtureID: context.fixtureID
            )

            var scores: [String: Score] = [:]
            if let score = BuiltInCheckpointScorers.scoreRequiredContent(contextWithSnapshot) {
                scores[BuiltInCheckpointAssertion.requiredContent.rawValue] = score
            }
            if let score = BuiltInCheckpointScorers.scoreForbiddenContent(contextWithSnapshot) {
                scores[BuiltInCheckpointAssertion.forbiddenContent.rawValue] = score
            }
            if let score = BuiltInCheckpointScorers.scoreExpectedEvents(contextWithSnapshot) {
                scores[BuiltInCheckpointAssertion.expectedEvents.rawValue] = score
            }
            if let score = BuiltInCheckpointScorers.scoreExpectedToolCalls(contextWithSnapshot) {
                scores[BuiltInCheckpointAssertion.expectedToolCalls.rawValue] = score
            }
            if let score = BuiltInCheckpointScorers.scoreExpectedCompression(contextWithSnapshot) {
                scores[BuiltInCheckpointAssertion.expectedCompression.rawValue] = score
            }
            if let score = BuiltInCheckpointScorers.scoreExpectedContextSlots(contextWithSnapshot) {
                scores[BuiltInCheckpointAssertion.expectedContextSlots.rawValue] = score
            }
            for (scorerID, payload) in (checkpoint.custom ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let scorer = scorersByID[scorerID] else {
                    scores[scorerID] = Score(
                        value: .unavailable,
                        explanation: "no CheckpointScorer registered for custom key '\(scorerID)'",
                        metadata: ["assertion": "custom", "payload": describePayload(payload)]
                    )
                    continue
                }
                scores[scorerID] = await scorer.score(contextWithSnapshot)
            }

            results.append(CheckpointResult(checkpoint: checkpoint, scores: scores))
        }

        return Outcome(fixture: fixture, checkpointResults: results)
    }

    // MARK: - Scorer / executor validation

    /// Validates and indexes `customScorers` by id. Throws on duplicates and
    /// on ids that collide with built-in assertion keys — both are
    /// app-supplied input at a public boundary, so they must fail with a
    /// descriptive error rather than trap (`Dictionary(uniqueKeysWithValues:)`)
    /// or silently overwrite a built-in score.
    private static func validatedScorers(
        _ customScorers: [any CheckpointScorer]
    ) throws -> [String: any CheckpointScorer] {
        let reserved = Set(BuiltInCheckpointAssertion.allCases.map(\.rawValue))
        var byID: [String: any CheckpointScorer] = [:]
        for scorer in customScorers {
            if reserved.contains(scorer.id) {
                throw ScorerRegistrationError.reservedScorerID(scorer.id)
            }
            if byID[scorer.id] != nil {
                throw ScorerRegistrationError.duplicateScorerID(scorer.id)
            }
            byID[scorer.id] = scorer
        }
        return byID
    }

    /// Caller-supplied executors win over synthetic fixed-response ones with
    /// the same tool name (so an app can exercise its real executor against a
    /// fixture-scripted call).
    private static func mergeExecutors(
        caller: [any ToolExecutor],
        synthetic: [any ToolExecutor]
    ) -> [any ToolExecutor] {
        let callerNames = Set(caller.map { $0.definition.name })
        return caller + synthetic.filter { !callerNames.contains($0.definition.name) }
    }

    // MARK: - Prefix scenario construction

    /// Builds the scripted scenario covering turns `0...index`, flattening
    /// the per-turn script groups only after slicing at the turn boundary —
    /// a tool-call turn contributes two backend scripts, so scripts cannot be
    /// sliced by turn index directly.
    private static func prefixScenario(
        fixture: GoldenTaskFixture,
        mapped: MappedGoldenTask,
        throughTurnIndex index: Int,
        toolExecutors: [any ToolExecutor],
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)?
    ) throws -> RuntimeScenario {
        guard index >= 0, index < mapped.turns.count else {
            throw PrefixError.turnIndexOutOfRange(index: index, turnCount: mapped.turns.count)
        }
        return RuntimeScenario(
            id: fixture.id,
            displayName: fixture.id,
            scenarioDescription: "Mapped from GoldenTaskFixture '\(fixture.id)' (turns 0...\(index)).",
            turns: Array(mapped.turns[0...index]),
            scriptedTurns: mapped.scriptGroups[0...index].flatMap { $0 },
            expectedSubsequence: [],
            toolExecutors: toolExecutors,
            preTurnCompressionPolicy: preTurnCompressionPolicy,
            systemPrompt: fixture.systemPrompt
        )
    }

    public enum PrefixError: Error, CustomStringConvertible {
        case turnIndexOutOfRange(index: Int, turnCount: Int)

        public var description: String {
            switch self {
            case .turnIndexOutOfRange(let index, let turnCount):
                return "GoldenTaskRunner: checkpoint.afterTurnIndex \(index) is out of range for a \(turnCount)-turn fixture"
            }
        }
    }

    // MARK: - Context extraction

    private static func evaluationContext(
        for checkpoint: GoldenCheckpoint,
        runResult: RuntimeScenarioRunner.Result,
        fixtureID: String
    ) -> CheckpointEvaluationContext {
        let events = runResult.trace.events

        let visibleText = runResult.producedMessages
            .filter { $0.role == .assistant }
            .map(\.content)
            .joined(separator: "\n")

        let toolCalls: [ToolCall] = events.compactMap { event in
            if case .toolCallRequested(let call) = event { return call }
            return nil
        }

        let lastContextAssembledSlotCount: Int? = events.reversed().lazy.compactMap { event -> Int? in
            if case .contextAssembled(let slots) = event { return slots.count }
            return nil
        }.first

        let lastCompressionInsertedRecordCount: Int? = events.reversed().lazy.compactMap { event -> Int? in
            if case .historyCompressed(_, let insertedRecords) = event { return insertedRecords.count }
            return nil
        }.first

        let output = EvalRunOutput(
            visibleText: visibleText,
            toolCalls: toolCalls
        )

        return CheckpointEvaluationContext(
            output: output,
            snapshot: nil,
            checkpoint: checkpoint,
            eventKinds: runResult.trace.kinds,
            producedMessageCount: runResult.producedMessages.count,
            lastContextAssembledSlotCount: lastContextAssembledSlotCount,
            lastCompressionInsertedRecordCount: lastCompressionInsertedRecordCount,
            fixtureID: fixtureID
        )
    }

    private static func describePayload(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array: return "[array]"
        case .object: return "{object}"
        }
    }
}
