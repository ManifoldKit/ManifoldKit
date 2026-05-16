import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - LoopDetectedError

private struct LoopDetectedError: LocalizedError {
    var errorDescription: String? {
        "Generation stopped: the model appeared to repeat itself."
    }
}

// MARK: - ChatGenerationCoordinator
//
// Owns the streaming/generation lifecycle extracted from `ChatViewModel` in
// phase 2 of #1221. Not `@Observable` — views observe `ChatViewModel`; this
// type writes back through closure seams.

/// Coordinates the generation and streaming lifecycle on behalf of `ChatViewModel`.
///
/// Extracted from `ChatViewModel` (phase 2 of #1221) following the same
/// closure-injection pattern as `ModelLoadCoordinator` and `ChatSessionManager`.
/// All state mutations that need to reach `@Observable` `ChatViewModel` properties
/// go through the injected closure seams; the coordinator never holds a strong
/// reference to the view model.
@MainActor
final class ChatGenerationCoordinator {

    // MARK: - State write-back closures

    /// Forwards to `ChatViewModel.transitionPhase(to:)`.
    var onTransitionPhase: (BackendActivityPhase) -> Bool = { _ in false }

    /// Writes `ChatViewModel.lastTurnState`.
    var onSetLastTurnState: (ChatViewModel.TurnState) -> Void = { _ in }

    /// Writes `ChatViewModel.backgroundTaskError`.
    var onSetBackgroundTaskError: ((Error)?) -> Void = { _ in }

    /// Writes `ChatViewModel.messageIDsWithStreamingThinking`.
    var onSetMessageIDsWithStreamingThinking: (Set<UUID>) -> Void = { _ in }

    // MARK: - Read-back closures

    /// Returns `ChatViewModel.activeSessionID`.
    var currentActiveSessionID: () -> UUID? = { nil }

    /// Returns `ChatViewModel.activeSession`.
    var currentActiveSession: () -> ChatSessionRecord? = { nil }

    /// Returns `ChatViewModel.messages`.
    var currentMessages: () -> [ChatMessageRecord] = { [] }

    /// Returns `ChatViewModel.postGenerationTasks`.
    var currentPostGenerationTasks: () -> [any PostGenerationTask] = { [] }

    // MARK: - Message mutation closures

    /// Forwards to `ChatViewModel.mutateMessage(id:_:)`.
    var mutateMessage: (UUID, (inout ChatMessageRecord) -> Void) -> Bool = { _, _ in false }

    /// Appends a message to `ChatViewModel.messages`.
    var appendMessage: (ChatMessageRecord) -> Void = { _ in }

    /// Removes messages matching the predicate from `ChatViewModel.messages`.
    var removeMessages: ((ChatMessageRecord) -> Bool) -> Void = { _ in }

    // MARK: - Side-effect closures

    /// Forwards to `ChatViewModel.updateContextEstimate()`.
    var updateContextEstimate: () -> Void = { }

    /// Forwards to `ChatViewModel.surfaceError(_:kind:)`.
    var surfaceError: (any Error, ChatError.Kind) -> Void = { _, _ in }

    /// Writes `ChatViewModel.errorMessage`.
    var setErrorMessage: (String?) -> Void = { _ in }

    /// Writes `ChatViewModel.showUpgradeHint` and triggers the callback.
    var setShowUpgradeHint: (Bool) -> Void = { _ in }

    /// Forwarded from `ChatViewModel.onSessionBranched`.
    var onSessionBranched: (@MainActor (UUID) async -> Void)?

    // MARK: - Owned State

    /// Single source of truth for legal phase transitions.
    @ObservationIgnored
    var phaseMachine = ActivityPhaseStateMachine(phase: .idle)

    /// Drain task for the runtime event stream.
    @ObservationIgnored
    private var runtimeEventDrainTask: Task<Void, Never>?

    /// `true` while the view model still owns the default in-memory runtime
    /// (i.e. the host did not inject one at construction). `replaceRuntime(_:)`
    /// uses this to decide whether subsequent `configure(persistence:)` calls
    /// should rebuild the runtime.
    @ObservationIgnored
    private(set) var ownsDefaultRuntime: Bool

    /// The runtime whose event stream this coordinator drains.
    @ObservationIgnored
    private(set) var conversationRuntime: ConversationRuntime

    /// Handle to the in-flight ConversationRuntime stream.
    var activeConversationStreamHandle: ConversationStreamHandle?

    /// The assistant `messageID` from the most-recent `streamStarted` event.
    /// Terminal events for prior turns (post-switch) carry a different ID and
    /// must not clobber the new turn's handle.
    var activeConversationMessageID: UUID?

    /// Token for the currently active generation request.
    var activeGenerationToken: InferenceService.GenerationRequestToken?

    /// Task backing the current generation turn.
    var generationTask: Task<Void, Never>?

    /// Task running post-generation tasks in the background.
    var backgroundTask: Task<Void, Never>?

    /// Snapshot of `messageIDsWithStreamingThinking` — maintained locally so
    /// mutations can do set operations before writing back through the closure.
    @ObservationIgnored
    private var streamingThinkingIDs: Set<UUID> = []

    // MARK: - Init

    init(conversationRuntime: ConversationRuntime, ownsDefaultRuntime: Bool) {
        self.conversationRuntime = conversationRuntime
        self.ownsDefaultRuntime = ownsDefaultRuntime
    }

    // MARK: - Runtime Management

    /// Starts (or restarts) the event drain for `conversationRuntime`.
    func startRuntimeEventDrain() {
        runtimeEventDrainTask?.cancel()
        let runtime = conversationRuntime
        runtimeEventDrainTask = Task { [weak self] in
            for await event in runtime.events {
                guard let self else { return }
                await self.handle(runtimeEvent: event)
            }
        }
    }

    /// Replaces the owned runtime and restarts the event drain. Only called
    /// from `configure(persistence:)` when the coordinator owns the default
    /// in-memory runtime.
    func replaceRuntime(_ newRuntime: ConversationRuntime) {
        conversationRuntime = newRuntime
        ownsDefaultRuntime = false
        startRuntimeEventDrain()
    }

    /// Cancels the active stream handle. Called during session teardown.
    func cancelActiveStreamHandle() async {
        if let handle = activeConversationStreamHandle {
            await conversationRuntime.cancel(handle)
            activeConversationStreamHandle = nil
        }
    }

    /// Cancels any in-flight background task and clears the error surface.
    func cancelBackgroundTask() {
        backgroundTask?.cancel()
        backgroundTask = nil
        onSetBackgroundTaskError(nil)
    }

    // MARK: - Phase forwarding

    /// Attempts to move to `newPhase`. Logs and returns `false` on illegal
    /// transitions — mirrors `ChatViewModel.transitionPhase(to:)`.
    @discardableResult
    func transitionPhase(to newPhase: BackendActivityPhase) -> Bool {
        let result = phaseMachine.transition(to: newPhase)
        switch result {
        case .applied:
            return onTransitionPhase(phaseMachine.phase)
        case .unchanged:
            return false
        case .rejected(let from, let to):
            Log.ui.warning(
                "ActivityPhaseStateMachine rejected transition: \(String(describing: from)) → \(String(describing: to))"
            )
            return false
        }
    }

    // MARK: - Stream Completion

    /// Suspends until `activeConversationStreamHandle` becomes `nil`.
    func awaitStreamCompletion() async {
        await Task.yield()
        var ticks = 0
        while activeConversationStreamHandle != nil {
            await Task.yield()
            ticks += 1
            if ticks > 8 {
                // Allowlist: ChatGenerationCoordinator.swift:try? await Task.sleep(...)
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    // MARK: - Post-Generation Tasks

    /// Runs `postGenerationTasks` sequentially. Errors are surfaced via
    /// `onSetBackgroundTaskError` and do not cancel subsequent tasks.
    func runPostGenerationTasks(message: ChatMessageRecord, session: ChatSessionRecord) {
        let tasks = currentPostGenerationTasks()
        guard !tasks.isEmpty else { return }
        onSetBackgroundTaskError(nil)
        let bgTask = Task { [weak self, tasks, message, session] in
            for task in tasks {
                guard !Task.isCancelled else { break }
                do {
                    try await task.run(message: message, session: session)
                } catch is CancellationError {
                    break
                } catch {
                    self?.onSetBackgroundTaskError(error)
                }
            }
        }
        backgroundTask = bgTask
    }

    // MARK: - Content-part Mutation Helpers

    /// Appends streamed visible-token text without clobbering sibling parts.
    static func appendVisibleText(_ batch: String, into msg: inout ChatMessageRecord) {
        if let lastIdx = msg.contentParts.indices.reversed().first(where: {
            if case .text = msg.contentParts[$0] { return true } else { return false }
        }), case .text(let existing) = msg.contentParts[lastIdx] {
            msg.contentParts[lastIdx] = .text(existing + batch)
        } else {
            msg.contentParts.append(.text(batch))
        }
    }

    /// Writes `partial` into the last in-flight `.thinking` part for live preview.
    static func writeThinkingPartialText(_ partial: String, into msg: inout ChatMessageRecord) {
        guard let idx = msg.contentParts.lastIndex(where: { $0.thinkingContent != nil }) else {
            let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? 0
            msg.contentParts.insert(.thinking(partial), at: insertAt)
            return
        }
        let signature = msg.contentParts[idx].thinkingSignature
        msg.contentParts[idx] = .thinking(partial, signature: signature)
    }

    // MARK: - Runtime Event Handler

    /// Maps an incoming ``ConversationEvent`` to observable state mutations.
    /// All mutations happen on `@MainActor`; write-backs to `ChatViewModel`
    /// go through the injected closure seams.
    func handle(runtimeEvent event: ConversationEvent) async {
        switch event {

        // MARK: Message lifecycle

        case .messageInserted(let record):
            var record = record
            guard record.sessionID == currentActiveSessionID() else { break }
            if record.role == .user {
                record.status = .sent
            }
            let messages = currentMessages()
            if let idx = messages.firstIndex(where: { $0.id == record.id }) {
                _ = mutateMessage(record.id) { msg in
                    msg.timestamp = record.timestamp
                    msg.promptTokens = record.promptTokens
                    msg.completionTokens = record.completionTokens
                    msg.status = record.status
                }
                _ = idx // suppress unused-variable warning
            } else {
                appendMessage(record)
            }

        case .messageRemoved(let id):
            removeMessages { $0.id == id }

        case .messageUpdated(let record):
            _ = mutateMessage(record.id) { $0 = record }

        // MARK: Stream lifecycle

        case .streamStarted(let messageID):
            onSetLastTurnState(.generating)
            transitionPhase(to: .waitingForFirstToken)
            activeConversationMessageID = messageID
            if let activeSessionID = currentActiveSessionID(),
               !currentMessages().contains(where: { $0.id == messageID }) {
                let placeholder = ChatMessageRecord(
                    id: messageID,
                    role: .assistant,
                    content: "",
                    sessionID: activeSessionID
                )
                appendMessage(placeholder)
            }

        case .tokenEmitted(let messageID, let delta):
            transitionPhase(to: .streaming)
            _ = mutateMessage(messageID) { Self.appendVisibleText(delta, into: &$0) }

        case .tokenUsageRecorded(let messageID, let promptTokens, let completionTokens):
            _ = mutateMessage(messageID) {
                $0.promptTokens = promptTokens
                $0.completionTokens = completionTokens
            }

        case .streamFinished(let messageID, let reason):
            guard messageID == activeConversationMessageID else { break }
            activeConversationMessageID = nil

            activeConversationStreamHandle = nil
            transitionPhase(to: .idle)
            updateContextEstimate()

            if reason == .empty {
                removeMessages { $0.id == messageID }
            }

            if reason == .stop,
               let completed = currentMessages().first(where: { $0.id == messageID }),
               completed.hasVisibleContent,
               let session = currentActiveSession() {
                onSetLastTurnState(.completed(completed))
                runPostGenerationTasks(message: completed, session: session)
            } else {
                onSetLastTurnState(.idle)
            }

            if reason == .stop,
               ManifoldConfiguration.shared.features.showUpgradeHint,
               let completed = currentMessages().first(where: { $0.id == messageID }),
               completed.hasVisibleContent {
                setShowUpgradeHint(true)
            }

        // MARK: Errors

        case .errorRaised(let error):
            switch error {
            case .persistence(let underlying):
                surfaceError(underlying, .persistence)
            case .inference(let underlying):
                surfaceError(underlying, .generation)
            case .cancelled:
                break
            case .contextAssembly(let underlying):
                surfaceError(underlying, .generation)
            case .messageNotFound, .noAssistantMessageToRegenerate, .providerNotConfigured, .messageTooLarge:
                setErrorMessage(error.localizedDescription)
            }
            if case .cancelled = error {
                onSetLastTurnState(.idle)
            } else {
                markMostRecentUserMessageFailed()
                onSetLastTurnState(.failed(error))
            }
            activeConversationStreamHandle = nil
            activeConversationMessageID = nil
            transitionPhase(to: .idle)

        // MARK: Thinking-block disclosure

        case .thinkingStarted(let messageID):
            streamingThinkingIDs.insert(messageID)
            onSetMessageIDsWithStreamingThinking(streamingThinkingIDs)
            _ = mutateMessage(messageID) { msg in
                let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? msg.contentParts.endIndex
                msg.contentParts.insert(.thinking(""), at: insertAt)
            }

        case .thinkingUpdated(let messageID, let partialText):
            _ = mutateMessage(messageID) { msg in
                guard let idx = msg.contentParts.lastIndex(where: { $0.thinkingContent != nil }) else {
                    return
                }
                let signature = msg.contentParts[idx].thinkingSignature
                msg.contentParts[idx] = .thinking(partialText, signature: signature)
            }

        case .thinkingFinalized(let messageID, let text, let signature):
            streamingThinkingIDs.remove(messageID)
            onSetMessageIDsWithStreamingThinking(streamingThinkingIDs)
            _ = mutateMessage(messageID) { msg in
                if let idx = msg.contentParts.lastIndex(where: { $0.thinkingContent != nil }),
                   msg.contentParts[idx].thinkingSignature == nil {
                    msg.contentParts[idx] = .thinking(text, signature: signature)
                } else {
                    let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? msg.contentParts.endIndex
                    msg.contentParts.insert(.thinking(text, signature: signature), at: insertAt)
                }
            }

        // MARK: Loop detection

        case .loopDetected(_):
            setErrorMessage("Generation stopped: the model appears to be repeating itself.")
            onSetLastTurnState(.failed(LoopDetectedError()))
            transitionPhase(to: .idle)

        // MARK: Session branching

        case .sessionBranched(let newSessionID, _):
            if let onSessionBranched {
                await onSessionBranched(newSessionID)
            }

        // MARK: Tool calls

        case .toolCallRequested(let call):
            guard let messageID = activeConversationMessageID else { break }
            _ = mutateMessage(messageID) { message in
                guard !message.contentParts.contains(where: {
                    if case .toolCall(let existing) = $0 {
                        return existing.id == call.id
                    }
                    return false
                }) else { return }
                message.contentParts.append(.toolCall(call))
            }

        case .toolCallCompleted(_, let result):
            guard let messageID = activeConversationMessageID else { break }
            _ = mutateMessage(messageID) { message in
                guard !message.contentParts.contains(where: {
                    if case .toolResult(let existing) = $0 {
                        return existing.callId == result.callId
                    }
                    return false
                }) else { return }
                message.contentParts.append(.toolResult(result))
            }

        case .beforeContextAssembly, .contextAssembled, .afterGeneration,
             .sessionTouchFailed,
             .compressionTriggered, .toolCallApproved:
            break

        case .historyCompressed:
            break
        }
    }

    // MARK: - Private Helpers

    private func markMostRecentUserMessageFailed() {
        let messages = currentMessages()
        let sessionID = currentActiveSessionID()
        guard let idx = messages.lastIndex(where: { $0.role == .user && $0.sessionID == sessionID }) else {
            return
        }
        _ = mutateMessage(messages[idx].id) { $0.status = .failed }
    }
}
