import Foundation
import ManifoldInference
import ManifoldRuntime

/// A self-contained scenario definition that drives both the CI test matrix
/// and the demo picker UI from a single source of truth.
///
/// A `RuntimeScenario` bundles:
/// - A scripted turn sequence (``scriptedTurns``) for hermetic CI runs via
///   ``ScriptedGenerationBackend``.
/// - Structural assertions (``expectedSubsequence``) that must hold in both
///   scripted and live runs — the same kind-level subsequence is checked
///   regardless of which backend drives the conversation.
/// - Display metadata (``displayName``, ``scenarioDescription``) for the
///   demo picker UI that the Architect view (P5) will surface.
/// - An optional ``preTurnCompressionPolicy`` for scenarios that exercise the
///   runtime's history-compression path. When supplied,
///   ``RuntimeScenarioRunner`` wires it into ``ConversationRuntime`` so
///   compression fires deterministically — without requiring real token-usage
///   data from the scripted backend.
public struct RuntimeScenario: Sendable {

    // MARK: - ScenarioTurn

    /// One user-driven action in a scenario's turn loop.
    ///
    /// A scenario's ``turns`` describe *what the user does* (send a message,
    /// regenerate the last reply, cancel mid-stream). The backend's event
    /// scripts live separately in ``scriptedTurns`` — one entry per backend
    /// `generate` call. The two counts are equal for plain send/regenerate
    /// turns but diverge for a tool round trip, where a single `.send` action
    /// drives two backend rounds (the tool call, then the follow-up answer).
    public struct ScenarioTurn: Sendable {

        /// The user action this turn performs.
        public enum Action: Sendable {
            /// Send a new user message.
            case send(text: String)
            /// Regenerate the last assistant reply (no new user text).
            case regenerate
        }

        public let action: Action

        /// When non-nil, the runner cancels this turn's stream the moment it has
        /// observed this many ``ConversationEvent/tokenEmitted`` events. Requires
        /// scripted mode (the runner drives the scripted backend's emission gate
        /// to make the cancel point deterministic). Author the matching
        /// ``ScriptedGenerationBackend/TurnScript`` with at least this many
        /// tokens.
        public let cancelAfterTokens: Int?

        /// Optional per-turn override of ``TurnConfig/streamingBatchCharacterLimit``.
        /// Cancellation turns set this to `1` so each token flushes as its own
        /// `.tokenEmitted` event, making "cancel after N tokens" exact.
        public let streamingBatchCharacterLimit: Int?

        public init(
            action: Action,
            cancelAfterTokens: Int? = nil,
            streamingBatchCharacterLimit: Int? = nil
        ) {
            self.action = action
            self.cancelAfterTokens = cancelAfterTokens
            self.streamingBatchCharacterLimit = streamingBatchCharacterLimit
        }

        /// A plain `.send` turn with no cancellation.
        public static func send(_ text: String) -> ScenarioTurn {
            ScenarioTurn(action: .send(text: text))
        }

        /// A `.regenerate` turn.
        public static var regenerate: ScenarioTurn {
            ScenarioTurn(action: .regenerate)
        }
    }

    /// Stable identifier — used as the test name and demo card key.
    public let id: String

    /// Short human-readable name for the demo picker.
    public let displayName: String

    /// One-paragraph description of what this scenario exercises.
    public let scenarioDescription: String

    /// The user-driven actions in order — one per turn. Plain send-only
    /// scenarios are built from the ``userMessages`` convenience initializer;
    /// scenarios exercising regenerate, cancellation, or tool round trips use
    /// the designated ``turns`` initializer.
    public let turns: [ScenarioTurn]

    /// The text of each `.send` action, in order. Derived from ``turns`` for
    /// backward compatibility with the demo picker and send-only consumers.
    public var userMessages: [String] {
        turns.compactMap { turn in
            if case let .send(text) = turn.action { return text }
            return nil
        }
    }

    /// Per-turn event scripts for ``RuntimeScenarioRunner/RunMode/scripted`` runs —
    /// one entry per backend `generate` call. Equal in count to ``turns`` for
    /// plain send/regenerate scenarios; longer when a tool round trip drives
    /// multiple backend rounds from a single user action.
    public let scriptedTurns: [ScriptedGenerationBackend.TurnScript]

    /// Tool executors registered in the runner's ``ToolRegistry`` before the
    /// turn loop runs. Non-empty only for tool round-trip scenarios; when empty
    /// the runner builds an ``InferenceService`` with no registry (the legacy
    /// behaviour every send-only scenario relies on).
    public let toolExecutors: [any ToolExecutor]

    /// The ``ConversationEventKind`` subsequence that must appear in the
    /// recorded trace for the scenario to pass — in both scripted and live mode.
    public let expectedSubsequence: [ConversationEventKind]

    /// Optional pre-turn compression policy. When non-nil,
    /// ``RuntimeScenarioRunner`` passes this to
    /// ``ConversationRuntime/init(messageStore:sessionStore:inferenceService:preTurnCompressionPolicy:)``
    /// so the scenario can exercise the ``ConversationEvent/historyCompressed``
    /// path deterministically.
    ///
    /// Pre-turn compression fires before the user message is appended to the
    /// store, so ``ConversationEvent/historyCompressed`` appears *before* the
    /// ``ConversationEvent/contextAssembled`` event for the same turn.
    public let preTurnCompressionPolicy: (any PreTurnCompressionPolicy)?

    /// Optional system prompt, plumbed through to each turn's ``TurnConfig/systemPrompt``.
    ///
    /// Added for ManifoldAppEval (app-facing goldens routinely need a fixed
    /// system prompt to make model behaviour reproducible) — MK's own
    /// built-in scenarios all leave this `nil`, matching their historical
    /// no-system-prompt behaviour.
    public let systemPrompt: String?

    /// Convenience initializer for send-only scenarios: each user message is a
    /// `.send` turn driving exactly one backend script. The two arrays must be
    /// equal in count.
    public init(
        id: String,
        displayName: String,
        scenarioDescription: String,
        userMessages: [String],
        scriptedTurns: [ScriptedGenerationBackend.TurnScript],
        expectedSubsequence: [ConversationEventKind],
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil,
        systemPrompt: String? = nil
    ) {
        precondition(
            userMessages.count == scriptedTurns.count,
            "RuntimeScenario '\(id)': userMessages.count (\(userMessages.count)) must equal scriptedTurns.count (\(scriptedTurns.count))"
        )
        self.id = id
        self.displayName = displayName
        self.scenarioDescription = scenarioDescription
        self.turns = userMessages.map { .send($0) }
        self.scriptedTurns = scriptedTurns
        self.expectedSubsequence = expectedSubsequence
        self.toolExecutors = []
        self.preTurnCompressionPolicy = preTurnCompressionPolicy
        self.systemPrompt = systemPrompt
    }

    /// Designated initializer for scenarios that mix turn kinds (send /
    /// regenerate), request mid-stream cancellation, or drive tool round trips.
    ///
    /// Unlike the convenience initializer there is no count equality check:
    /// ``scriptedTurns`` tracks backend `generate` calls, which can exceed
    /// ``turns`` when a single user action triggers a multi-round tool loop.
    public init(
        id: String,
        displayName: String,
        scenarioDescription: String,
        turns: [ScenarioTurn],
        scriptedTurns: [ScriptedGenerationBackend.TurnScript],
        expectedSubsequence: [ConversationEventKind],
        toolExecutors: [any ToolExecutor] = [],
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil,
        systemPrompt: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.scenarioDescription = scenarioDescription
        self.turns = turns
        self.scriptedTurns = scriptedTurns
        self.expectedSubsequence = expectedSubsequence
        self.toolExecutors = toolExecutors
        self.preTurnCompressionPolicy = preTurnCompressionPolicy
        self.systemPrompt = systemPrompt
    }
}
