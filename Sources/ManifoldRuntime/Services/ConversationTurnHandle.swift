import Foundation
import ManifoldInference

/// Reliable completion result for one runtime generation turn.
///
/// Unlike ``ConversationRuntime/events``, this value is delivered through the
/// per-turn ``ConversationTurnHandle`` and is not affected by event-stream
/// buffering, dropped events under backpressure, or competing event consumers.
public struct ConversationTurnOutcome: Sendable {
    /// Session whose turn reached a terminal outcome.
    public let sessionID: UUID

    /// Cancellation identity for the completed generation stream.
    public let streamHandle: ConversationStreamHandle

    /// Assistant message identity allocated for this turn, when generation started.
    public let assistantMessageID: UUID?

    /// Persisted assistant message, or `nil` when the turn produced no visible
    /// assistant record (for example empty or cancelled responses).
    public let assistantMessage: ChatMessage?

    /// High-level reason the generation stream finished.
    public let reason: FinishReason

    /// Asynchronous turn failure captured after stream launch, when any.
    public let error: ConversationError?

    /// Final visible assistant text accumulated before the terminal outcome.
    public let finalText: String

    /// Prompt-token count reported by the backend, when available.
    public let promptTokens: Int?

    /// Completion-token count reported by the backend, when available.
    public let completionTokens: Int?

    public init(
        sessionID: UUID,
        streamHandle: ConversationStreamHandle,
        assistantMessageID: UUID?,
        assistantMessage: ChatMessage?,
        reason: FinishReason,
        error: ConversationError?,
        finalText: String,
        promptTokens: Int?,
        completionTokens: Int?
    ) {
        self.sessionID = sessionID
        self.streamHandle = streamHandle
        self.assistantMessageID = assistantMessageID
        self.assistantMessage = assistantMessage
        self.reason = reason
        self.error = error
        self.finalText = finalText
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// Per-turn handle that pairs cancellation identity with reliable completion.
///
/// Use ``streamHandle`` with ``ConversationRuntime/cancel(_:)``. Await
/// ``outcome`` when command-style code needs to know that this exact turn
/// reached a terminal state; keep ``ConversationRuntime/events`` for
/// single-consumer observation and ordering-sensitive UI/tests.
public struct ConversationTurnHandle: Sendable {
    public let streamHandle: ConversationStreamHandle
    private let completion: ConversationTurnOutcomeCompletion

    package init(
        streamHandle: ConversationStreamHandle,
        completion: ConversationTurnOutcomeCompletion
    ) {
        self.streamHandle = streamHandle
        self.completion = completion
    }

    /// Waits for the runtime turn to reach a terminal outcome exactly once.
    public var outcome: ConversationTurnOutcome {
        get async {
            await completion.value()
        }
    }
}

package actor ConversationTurnOutcomeCompletion {
    private var stored: ConversationTurnOutcome?
    private var waiters: [CheckedContinuation<ConversationTurnOutcome, Never>] = []

    func complete(_ outcome: ConversationTurnOutcome) {
        guard stored == nil else {
            Log.inference.warning("ConversationTurnOutcomeCompletion completed more than once for handle \(outcome.streamHandle.id, privacy: .private)")
            return
        }
        stored = outcome
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: outcome)
        }
    }

    func value() async -> ConversationTurnOutcome {
        if let stored { return stored }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
