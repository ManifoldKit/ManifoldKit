import Foundation
import ManifoldInference

// MARK: - Legacy Send input
//
// I6 collapsed the four near-identical input structs into a single ``TurnInput``
// + ``TurnConfig`` + ``TurnKind`` triple (see ConversationRuntime+TurnInput.swift).
// `SendInput` / `RegenerateInput` / `EditInput` / `BranchInput` remain as
// deprecation shims for one minor so adopters can migrate without a hard break.
// New callers should construct ``TurnInput`` and call
// ``ConversationRuntime/processTurn(_:)``.

/// Input for ``ConversationRuntime/send(_:)``.
///
/// Carries the user-supplied text plus the generation knobs the runtime
/// forwards to ``InferenceService/enqueueAsync(...)``. The `sessionID` is
/// required — the runtime is session-scoped at the call site (Phase 1.2's
/// public stance), and turning a no-session call into a "generic" turn
/// would require a parallel error path consumers shouldn't have to
/// pattern-match.
@available(*, deprecated, renamed: "TurnInput", message: "Build a TurnInput with .send(text:attachments:) and call processTurn(_:). SendInput will be removed in a future release.")
public struct SendInput: Sendable {
    public let sessionID: UUID
    public let userText: String
    /// Optional non-text attachments (typically `MessagePart.image` cases) to
    /// include alongside `userText` on the user `ChatMessageRecord`. When
    /// non-empty the runtime builds the user record's `contentParts` as
    /// `[.text(userText), <attachments>...]` so vision-capable backends see
    /// the images and the persisted record preserves them. The runtime does
    /// only fills in missing image placeholder hashes; backends own the
    /// remaining on-wire shape.
    public let attachments: [MessagePart]
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
        sessionID: UUID,
        userText: String,
        attachments: [MessagePart] = [],
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
        self.sessionID = sessionID
        self.userText = userText
        self.attachments = attachments
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

@available(*, deprecated)
extension SendInput {
    /// Translates the legacy struct into the canonical ``TurnInput`` used by
    /// ``ConversationRuntime/processTurn(_:)``. Used by the deprecated
    /// ``ConversationRuntime/send(_:)`` overload to forward without
    /// duplicating the per-field plumbing.
    var asTurnInput: TurnInput {
        TurnInput(
            sessionID: sessionID,
            kind: .send(text: userText, attachments: attachments),
            config: TurnConfig(
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
                streamingUpdateInterval: streamingUpdateInterval,
                streamingBatchCharacterLimit: streamingBatchCharacterLimit,
                thinkingStreamingUpdateInterval: thinkingStreamingUpdateInterval,
                thinkingStreamingBatchCharacterLimit: thinkingStreamingBatchCharacterLimit,
                loopDetectionEnabled: loopDetectionEnabled
            )
        )
    }
}

// MARK: - Regenerate input

/// Input for ``ConversationRuntime/regenerate(_:)``.
///
/// No `userText` — regenerate re-runs the last user turn with no new input.
/// The runtime finds the last assistant message, deletes it, and streams a
/// fresh response into a new assistant record.
@available(*, deprecated, renamed: "TurnInput", message: "Build a TurnInput with .regenerate and call processTurn(_:). RegenerateInput will be removed in a future release.")
public struct RegenerateInput: Sendable {
    public let sessionID: UUID
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
        sessionID: UUID,
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
        self.sessionID = sessionID
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

@available(*, deprecated)
extension RegenerateInput {
    var asTurnInput: TurnInput {
        TurnInput(
            sessionID: sessionID,
            kind: .regenerate,
            config: TurnConfig(
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
                streamingUpdateInterval: streamingUpdateInterval,
                streamingBatchCharacterLimit: streamingBatchCharacterLimit,
                thinkingStreamingUpdateInterval: thinkingStreamingUpdateInterval,
                thinkingStreamingBatchCharacterLimit: thinkingStreamingBatchCharacterLimit,
                loopDetectionEnabled: loopDetectionEnabled
            )
        )
    }
}

// MARK: - Edit input

/// Input for ``ConversationRuntime/edit(_:)``.
///
/// Identifies the message to edit by ID, carries the replacement content,
/// and includes the same generation knobs as ``SendInput`` and
/// ``RegenerateInput`` for the subsequent generation turn (if any).
@available(*, deprecated, renamed: "TurnInput", message: "Build a TurnInput with .edit(messageID:text:) and call processTurn(_:). EditInput will be removed in a future release.")
public struct EditInput: Sendable {
    public let sessionID: UUID
    /// The ID of the message whose content will be replaced.
    public let messageID: UUID
    /// The replacement content for the edited message.
    public let newContent: String
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
        sessionID: UUID,
        messageID: UUID,
        newContent: String,
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
        self.sessionID = sessionID
        self.messageID = messageID
        self.newContent = newContent
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

@available(*, deprecated)
extension EditInput {
    var asTurnInput: TurnInput {
        TurnInput(
            sessionID: sessionID,
            kind: .edit(messageID: messageID, text: newContent),
            config: TurnConfig(
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
                streamingUpdateInterval: streamingUpdateInterval,
                streamingBatchCharacterLimit: streamingBatchCharacterLimit,
                thinkingStreamingUpdateInterval: thinkingStreamingUpdateInterval,
                thinkingStreamingBatchCharacterLimit: thinkingStreamingBatchCharacterLimit,
                loopDetectionEnabled: loopDetectionEnabled
            )
        )
    }
}

// MARK: - Branch input

/// Input for ``ConversationRuntime/branch(_:)``.
///
/// Forks a conversation at a chosen message. The runtime copies messages from
/// `sourceSessionID` up to and including `branchMessageID` into a new session
/// identified by `newSessionID`, then optionally triggers a generation turn on
/// the new session if the last copied message is a user message.
@available(*, deprecated, renamed: "TurnInput", message: "Build a TurnInput with .branch(messageID:newSessionID:newSessionTitle:generateAfter:) and call processTurn(_:). BranchInput will be removed in a future release.")
public struct BranchInput: Sendable {
    /// The session to fork from.
    public let sourceSessionID: UUID
    /// The message to branch at (inclusive — this message is copied into the
    /// new session).
    public let branchMessageID: UUID
    /// The caller-supplied ID for the new session.
    public let newSessionID: UUID
    /// Title for the new session. `nil` preserves the source session's title.
    public let newSessionTitle: String?
    /// When `true` and the last copied message is `.user`, the runtime
    /// triggers a generation turn on the new session after copying.
    public let generateAfterBranch: Bool
    // Generation knobs — only used when generateAfterBranch == true.
    public let systemPrompt: String?
    public let temperature: Float
    public let topP: Float
    public let repeatPenalty: Float
    public let maxOutputTokens: Int?
    public let maxThinkingTokens: Int?

    public init(
        sourceSessionID: UUID,
        branchMessageID: UUID,
        newSessionID: UUID = UUID(),
        newSessionTitle: String? = nil,
        generateAfterBranch: Bool = false,
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil
    ) {
        self.sourceSessionID = sourceSessionID
        self.branchMessageID = branchMessageID
        self.newSessionID = newSessionID
        self.newSessionTitle = newSessionTitle
        self.generateAfterBranch = generateAfterBranch
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxOutputTokens = maxOutputTokens
        self.maxThinkingTokens = maxThinkingTokens
    }
}

@available(*, deprecated)
extension BranchInput {
    var asTurnInput: TurnInput {
        TurnInput(
            sessionID: sourceSessionID,
            kind: .branch(
                messageID: branchMessageID,
                newSessionID: newSessionID,
                newSessionTitle: newSessionTitle,
                generateAfter: generateAfterBranch
            ),
            config: TurnConfig(
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens
            )
        )
    }
}
