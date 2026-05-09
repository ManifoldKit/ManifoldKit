import Foundation
import ManifoldInference

// MARK: - TurnConfig
//
// I6 collapses the four near-identical input structs (SendInput / RegenerateInput
// / EditInput / BranchInput) into a single normalised pair: TurnConfig (the
// shared sampling/streaming/loop-detection knobs) and TurnKind (the per-flow
// payload). Adding a new knob is now a single-touch change rather than a
// 4× edit across paralleled init signatures. Old structs are kept as
// deprecation shims for one minor — see ConversationRuntime.swift.

/// The sampling, streaming, and loop-detection knobs shared by every
/// ``ConversationRuntime`` turn flow.
///
/// Identical for `send`, `regenerate`, `edit`, and `branch`. The runtime reads
/// these once per turn and forwards them to ``InferenceService/enqueueAsync(...)``.
public struct TurnConfig: Sendable, Equatable {
    public let systemPrompt: String?
    public let temperature: Float
    public let topP: Float
    public let repeatPenalty: Float
    public let maxOutputTokens: Int?
    public let maxThinkingTokens: Int?
    public let streamingUpdateInterval: Duration
    public let streamingBatchCharacterLimit: Int
    public let thinkingStreamingUpdateInterval: Duration
    public let thinkingStreamingBatchCharacterLimit: Int
    public let loopDetectionEnabled: Bool

    public init(
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        streamingUpdateInterval: Duration = .milliseconds(33),
        streamingBatchCharacterLimit: Int = 128,
        thinkingStreamingUpdateInterval: Duration = .milliseconds(33),
        thinkingStreamingBatchCharacterLimit: Int = 128,
        loopDetectionEnabled: Bool = true
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxOutputTokens = maxOutputTokens
        self.maxThinkingTokens = maxThinkingTokens
        self.streamingUpdateInterval = streamingUpdateInterval
        self.streamingBatchCharacterLimit = streamingBatchCharacterLimit
        self.thinkingStreamingUpdateInterval = thinkingStreamingUpdateInterval
        self.thinkingStreamingBatchCharacterLimit = thinkingStreamingBatchCharacterLimit
        self.loopDetectionEnabled = loopDetectionEnabled
    }
}

// MARK: - TurnKind

/// The per-flow payload distinguishing one turn from another.
///
/// Each case carries only the fields that flow truly needs — `send` adds new
/// user text plus optional attachments; `regenerate` re-runs the last user
/// turn; `edit` rewrites a message and re-runs trailing generation;
/// `branch` forks a session at a chosen message and optionally generates on
/// the new fork.
public enum TurnKind: Sendable {
    /// New user message — persists `text` (and any image/file attachments) as
    /// a `.user` record before generation begins.
    ///
    /// `attachments` is `[MessagePart]` — the existing structured-content
    /// type. `MessagePart.image` is the only attachment shape the runtime
    /// owns today; future shapes (file, audio) are added by extending
    /// `MessagePart` rather than this enum.
    case send(text: String, attachments: [MessagePart] = [])

    /// Re-runs the last user turn. The runtime deletes the trailing assistant
    /// message synchronously, then drives a fresh generation from the
    /// preserved history.
    case regenerate

    /// Replaces `messageID`'s content with `text`, deletes all trailing
    /// messages, and (when the edited message was `.user`) drives a fresh
    /// generation. Editing a `.assistant` message persists the edit but
    /// does not re-generate.
    case edit(messageID: UUID, text: String)

    /// Forks the session at `messageID` (inclusive) into a new session
    /// identified by `newSessionID`. When `generateAfter` is `true` and the
    /// last copied message is `.user`, the runtime drives a generation turn
    /// on the new session.
    ///
    /// `newSessionTitle == nil` preserves the source session's title.
    case branch(
        messageID: UUID,
        newSessionID: UUID = UUID(),
        newSessionTitle: String? = nil,
        generateAfter: Bool = false
    )
}

// MARK: - TurnInput

/// The unified input for every ``ConversationRuntime`` turn flow.
///
/// Compose with ``TurnConfig`` (defaults are sensible across all four flows)
/// and a ``TurnKind`` payload. The runtime exposes
/// ``ConversationRuntime/processTurn(_:)`` as the canonical entry point;
/// the per-flow methods (``ConversationRuntime/send(_:)``,
/// ``ConversationRuntime/regenerate(_:)`` etc.) are kept as thin wrappers
/// that build a `TurnInput` for callers still passing the legacy `*Input`
/// structs.
public struct TurnInput: Sendable {
    /// The session this turn targets. For `.branch`, this is the **source**
    /// session — the new session ID lives on the kind payload.
    public let sessionID: UUID
    public let kind: TurnKind
    public let config: TurnConfig

    public init(
        sessionID: UUID,
        kind: TurnKind,
        config: TurnConfig = TurnConfig()
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.config = config
    }
}
