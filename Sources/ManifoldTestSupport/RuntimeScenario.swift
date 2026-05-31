#if DEBUG
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
public struct RuntimeScenario: Sendable {

    /// Stable identifier — used as the test name and demo card key.
    public let id: String

    /// Short human-readable name for the demo picker.
    public let displayName: String

    /// One-paragraph description of what this scenario exercises.
    public let scenarioDescription: String

    /// The user message(s) sent in order. One entry per turn.
    public let userMessages: [String]

    /// Per-turn event scripts for ``RuntimeScenarioRunner/RunMode/scripted`` runs.
    /// Must have the same count as ``userMessages``.
    public let scriptedTurns: [ScriptedGenerationBackend.TurnScript]

    /// The ``ConversationEventKind`` subsequence that must appear in the
    /// recorded trace for the scenario to pass — in both scripted and live mode.
    public let expectedSubsequence: [ConversationEventKind]

    public init(
        id: String,
        displayName: String,
        scenarioDescription: String,
        userMessages: [String],
        scriptedTurns: [ScriptedGenerationBackend.TurnScript],
        expectedSubsequence: [ConversationEventKind]
    ) {
        precondition(
            userMessages.count == scriptedTurns.count,
            "RuntimeScenario '\(id)': userMessages.count (\(userMessages.count)) must equal scriptedTurns.count (\(scriptedTurns.count))"
        )
        self.id = id
        self.displayName = displayName
        self.scenarioDescription = scenarioDescription
        self.userMessages = userMessages
        self.scriptedTurns = scriptedTurns
        self.expectedSubsequence = expectedSubsequence
    }
}
#endif
