import Foundation
import ManifoldInference
import ManifoldRuntime

/// The grouped form of a mapped fixture: one script *group* per user turn.
///
/// A plain turn maps to one backend script; a turn with a
/// ``GoldenScriptedToolCall`` maps to two (the tool-call round, then the
/// follow-up answer round) — so backend scripts cannot be sliced by turn
/// index directly. `GoldenTaskRunner` builds its per-checkpoint prefix
/// scenarios from these groups, flattening only after slicing at a turn
/// boundary.
struct MappedGoldenTask {
    let turns: [RuntimeScenario.ScenarioTurn]
    /// One entry per turn; each entry holds that turn's backend `generate`
    /// scripts in order.
    let scriptGroups: [[ScriptedGenerationBackend.TurnScript]]
    /// Fixed-response executors synthesized from ``GoldenScriptedToolCall/result``
    /// payloads — one per distinct tool name that declared a result.
    let syntheticToolExecutors: [any ToolExecutor]
}

/// Maps a ``GoldenTaskFixture`` onto a ``RuntimeScenario`` for the
/// deterministic (scripted) lane.
///
/// ## Scope note: `.edit` turns are not yet mappable
///
/// ``RuntimeScenario/ScenarioTurn/Action`` (the runner's turn-kind enum) only
/// carries `.send` and `.regenerate` — it has no `.edit` case. Adding one
/// would require a `messageID`, but a JSON fixture cannot know a message's
/// UUID ahead of time (message IDs are assigned by ``ConversationRuntime``
/// when a turn is driven). Mapping an edit turn correctly needs a
/// message-ID-lookup scheme threaded through the runner, not a pure
/// schema→`RuntimeScenario` translation — a real design gap, not an oversight
/// to paper over with a fake mapping. `GoldenTaskFixture` still declares
/// `.edit` in ``GoldenTurn/Kind`` for forward-compatibility, but
/// ``map(_:)`` throws ``MapError/editNotYetSupported(turnIndex:)`` if a
/// fixture uses it. Tracked as wave-1 scope; revisit once an app fixture
/// actually needs edit coverage.
public enum GoldenTaskMapper {

    public enum MapError: Error, CustomStringConvertible {
        case editNotYetSupported(turnIndex: Int)
        case sendTurnMissingText(turnIndex: Int)

        public var description: String {
            switch self {
            case .editNotYetSupported(let index):
                return "GoldenTaskMapper: turn \(index) is .edit, which wave 1 does not yet map to RuntimeScenario (see GoldenTaskMapper doc comment)"
            case .sendTurnMissingText(let index):
                return "GoldenTaskMapper: turn \(index) is .send but has no text"
            }
        }
    }

    /// Builds a ``RuntimeScenario`` from `fixture`, ready to run via
    /// ``RuntimeScenarioRunner/run(_:mode:ragService:preTurnCompressionPolicy:)``.
    ///
    /// The scenario's `expectedSubsequence` is deliberately empty — checkpoint
    /// evaluation (event subsequence, content, tool calls, compression,
    /// context slots) happens per-checkpoint in ``GoldenTaskRunner``, not as
    /// one whole-scenario assertion.
    public static func map(_ fixture: GoldenTaskFixture) throws -> RuntimeScenario {
        let mapped = try mapGrouped(fixture)
        return RuntimeScenario(
            id: fixture.id,
            displayName: fixture.id,
            scenarioDescription: "Mapped from GoldenTaskFixture '\(fixture.id)'.",
            turns: mapped.turns,
            scriptedTurns: mapped.scriptGroups.flatMap { $0 },
            expectedSubsequence: [],
            toolExecutors: mapped.syntheticToolExecutors,
            systemPrompt: fixture.systemPrompt
        )
    }

    /// Grouped mapping — used by `GoldenTaskRunner` so per-checkpoint prefix
    /// scenarios can slice backend scripts at turn boundaries even when a
    /// tool-call turn contributes more than one script.
    static func mapGrouped(_ fixture: GoldenTaskFixture) throws -> MappedGoldenTask {
        var turns: [RuntimeScenario.ScenarioTurn] = []
        var scriptGroups: [[ScriptedGenerationBackend.TurnScript]] = []
        var syntheticExecutorsByName: [String: AppEvalEchoTool] = [:]

        for (index, turn) in fixture.turns.enumerated() {
            switch turn.kind {
            case .send:
                guard let text = turn.text else {
                    throw MapError.sendTurnMissingText(turnIndex: index)
                }
                turns.append(scenarioTurn(for: turn, action: .send(text: text)))
            case .regenerate:
                turns.append(scenarioTurn(for: turn, action: .regenerate))
            case .edit:
                throw MapError.editNotYetSupported(turnIndex: index)
            }

            var group: [ScriptedGenerationBackend.TurnScript] = []
            if let scriptedCall = turn.scriptedToolCall {
                // Round 1: the scripted model requests the tool (no visible
                // text); the runtime dispatches it and re-prompts, which pops
                // the follow-up script below. Mirrors how MK's own
                // tool-round-trip scenario scripts a call.
                group.append(.toolCall(ToolCall(
                    id: "\(fixture.id)-turn\(index)-call",
                    toolName: scriptedCall.name,
                    arguments: scriptedCall.arguments ?? "{}"
                )))
                if let result = scriptedCall.result, syntheticExecutorsByName[scriptedCall.name] == nil {
                    syntheticExecutorsByName[scriptedCall.name] = AppEvalEchoTool(
                        toolName: scriptedCall.name,
                        response: result
                    )
                }
            }
            group.append(tokenize(turn.cannedResponse))
            scriptGroups.append(group)
        }

        return MappedGoldenTask(
            turns: turns,
            scriptGroups: scriptGroups,
            syntheticToolExecutors: syntheticExecutorsByName.keys.sorted().compactMap { syntheticExecutorsByName[$0] }
        )
    }

    private static func scenarioTurn(
        for turn: GoldenTurn,
        action: RuntimeScenario.ScenarioTurn.Action
    ) -> RuntimeScenario.ScenarioTurn {
        RuntimeScenario.ScenarioTurn(
            action: action,
            cancelAfterTokens: turn.cancelAfterTokens,
            // A cancel-after-N-tokens turn needs each token flushed as its own
            // event (mirrors RuntimeScenarioRegistry.cancelMidStream) so the
            // count is exact.
            streamingBatchCharacterLimit: turn.cancelAfterTokens != nil ? 1 : nil
        )
    }

    /// Splits `cannedResponse` into word-level tokens for
    /// ``ScriptedGenerationBackend``, reattaching each word's leading space so
    /// concatenating the tokens reproduces the original string exactly. `nil`
    /// produces an empty turn script (stream finishes with no visible text).
    private static func tokenize(_ cannedResponse: String?) -> ScriptedGenerationBackend.TurnScript {
        guard let cannedResponse, !cannedResponse.isEmpty else {
            return .empty
        }
        let words = cannedResponse.split(separator: " ", omittingEmptySubsequences: false)
        let tokens = words.enumerated().map { index, word in
            index == 0 ? String(word) : " \(word)"
        }
        return .tokens(tokens)
    }
}
