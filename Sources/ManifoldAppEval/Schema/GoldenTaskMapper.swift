import Foundation
import ManifoldRuntime

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
        var turns: [RuntimeScenario.ScenarioTurn] = []
        var scriptedTurns: [ScriptedGenerationBackend.TurnScript] = []

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
            scriptedTurns.append(tokenize(turn.cannedResponse))
        }

        return RuntimeScenario(
            id: fixture.id,
            displayName: fixture.id,
            scenarioDescription: "Mapped from GoldenTaskFixture '\(fixture.id)'.",
            turns: turns,
            scriptedTurns: scriptedTurns,
            expectedSubsequence: [],
            systemPrompt: fixture.systemPrompt
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
