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

    /// Runs every checkpoint in `fixture` and scores it.
    ///
    /// - Parameters:
    ///   - probe: Optional app-supplied state probe, called once per
    ///     checkpoint after driving the prefix scenario.
    ///   - customScorers: App-registered scorers, dispatched by
    ///     ``GoldenCheckpoint/custom`` key. A `custom` key with no matching
    ///     scorer id scores `.unavailable`.
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
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil
    ) async throws -> Outcome {
        var fullScenario = try GoldenTaskMapper.map(fixture)
        if let preTurnCompressionPolicy {
            fullScenario = withCompressionPolicy(fullScenario, preTurnCompressionPolicy)
        }
        let scorersByID = Dictionary(uniqueKeysWithValues: customScorers.map { ($0.id, $0) })

        var results: [CheckpointResult] = []
        for checkpoint in fixture.checkpoints {
            let prefixScenario = try prefixed(fullScenario, throughTurnIndex: checkpoint.afterTurnIndex)
            let runResult = try await RuntimeScenarioRunner.run(prefixScenario)

            let context = evaluationContext(for: checkpoint, runResult: runResult)
            let snapshot = await probe?.snapshot(after: checkpoint, runResult: runResult)
            let contextWithSnapshot = CheckpointEvaluationContext(
                output: context.output,
                snapshot: snapshot,
                checkpoint: context.checkpoint,
                eventKinds: context.eventKinds,
                producedMessageCount: context.producedMessageCount,
                lastContextAssembledSlotCount: context.lastContextAssembledSlotCount,
                lastCompressionInsertedRecordCount: context.lastCompressionInsertedRecordCount
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

    // MARK: - Prefix scenario construction

    private static func withCompressionPolicy(
        _ scenario: RuntimeScenario,
        _ policy: any PreTurnCompressionPolicy
    ) -> RuntimeScenario {
        RuntimeScenario(
            id: scenario.id,
            displayName: scenario.displayName,
            scenarioDescription: scenario.scenarioDescription,
            turns: scenario.turns,
            scriptedTurns: scenario.scriptedTurns,
            expectedSubsequence: [],
            toolExecutors: scenario.toolExecutors,
            preTurnCompressionPolicy: policy,
            systemPrompt: scenario.systemPrompt
        )
    }

    private static func prefixed(_ scenario: RuntimeScenario, throughTurnIndex index: Int) throws -> RuntimeScenario {
        guard index >= 0, index < scenario.turns.count else {
            throw PrefixError.turnIndexOutOfRange(index: index, turnCount: scenario.turns.count)
        }
        return RuntimeScenario(
            id: scenario.id,
            displayName: scenario.displayName,
            scenarioDescription: scenario.scenarioDescription,
            turns: Array(scenario.turns[0...index]),
            scriptedTurns: Array(scenario.scriptedTurns[0...index]),
            expectedSubsequence: [],
            toolExecutors: scenario.toolExecutors,
            preTurnCompressionPolicy: scenario.preTurnCompressionPolicy,
            systemPrompt: scenario.systemPrompt
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
        runResult: RuntimeScenarioRunner.Result
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
            lastCompressionInsertedRecordCount: lastCompressionInsertedRecordCount
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
