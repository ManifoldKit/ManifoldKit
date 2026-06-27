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
    var onTransitionPhase: @MainActor (BackendActivityPhase) -> Bool = { _ in false }

    /// Writes `ChatViewModel.lastTurnState`.
    var onSetLastTurnState: @MainActor (ChatViewModel.TurnState) -> Void = { _ in }

    /// Writes `ChatViewModel.backgroundTaskError`.
    var onSetBackgroundTaskError: @MainActor (Error?) -> Void = { _ in }

    /// Writes `ChatViewModel.messageIDsWithStreamingThinking`.
    var onSetMessageIDsWithStreamingThinking: @MainActor (Set<UUID>) -> Void = { _ in }

    // MARK: - Read-back closures

    /// Returns `ChatViewModel.activeSessionID`.
    var currentActiveSessionID: @MainActor () -> UUID? = { nil }

    /// Returns `ChatViewModel.activeSession`.
    var currentActiveSession: @MainActor () -> ChatSession? = { nil }

    /// Returns `ChatViewModel.messages`.
    var currentMessages: @MainActor () -> [ChatMessage] = { [] }

    /// Returns `ChatViewModel.postGenerationTasks`.
    var currentPostGenerationTasks: @MainActor () -> [any PostGenerationTask] = { [] }

    // MARK: - Message mutation closures

    /// Forwards to `ChatViewModel.mutateMessage(id:_:)`.
    var mutateMessage: @MainActor (UUID, (inout ChatMessage) -> Void) -> Bool = { _, _ in false }

    /// Appends a message to `ChatViewModel.messages`.
    var appendMessage: @MainActor (ChatMessage) -> Void = { _ in }

    /// Removes messages matching the predicate from `ChatViewModel.messages`.
    var removeMessages: @MainActor ((ChatMessage) -> Bool) -> Void = { _ in }

    // MARK: - Side-effect closures

    /// Forwards to `ChatViewModel.updateContextEstimate()`.
    var updateContextEstimate: @MainActor () -> Void = { }

    /// Forwards to `ChatViewModel.surfaceError(_:kind:)`.
    var surfaceError: @MainActor (any Error, ChatError.Kind) -> Void = { _, _ in }

    /// Writes `ChatViewModel.errorMessage`.
    var setErrorMessage: @MainActor (String?) -> Void = { _ in }

    /// Writes `ChatViewModel.showUpgradeHint` and triggers the callback.
    var setShowUpgradeHint: @MainActor (Bool) -> Void = { _ in }

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

    /// Continuations parked by ``awaitStreamCompletion()`` while a stream is
    /// in flight. why: replaces a 1ms busy-poll with an event-driven seam —
    /// each terminal handler resumes these once the handle clears. Because the
    /// coordinator is `@MainActor`, every append/drain runs on the same actor,
    /// so the array needs no lock to be race-free.
    @ObservationIgnored
    private var streamCompletionWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Accumulator for the in-flight assistant message's trailing visible-text
    /// run. why: appending each token delta straight into the message's last
    /// `.text` part did `existing + batch` — an O(N) string copy per batch and
    /// O(N²) over the turn. Instead we `append` to this buffer (amortized O(1))
    /// and write the whole buffer into the message. `contentParts` stays
    /// authoritative — the buffer is purely a copy-avoidance cache.
    @ObservationIgnored
    private var streamingTailBuffer: String = ""

    /// The assistant message id the ``streamingTailBuffer`` is keyed to. Cleared
    /// on every terminal path so a stale buffer can never leak into a later turn.
    @ObservationIgnored
    private var streamingTailMessageID: UUID?

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
            // why: teardown clears the handle outside the event drain, so wake
            // any caller parked in awaitStreamCompletion() here too.
            resumeStreamCompletionWaiters()
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

    /// Suspends until the supplied runtime turn reaches its terminal outcome.
    ///
    /// This is the completion path for UI turn drivers. The global event drain
    /// remains responsible for live token, thinking, and message mutation
    /// reduction; this method gives that drain a short bounded window to consume
    /// already-emitted final deltas, then reconciles terminal state from the
    /// per-turn outcome if the drain is delayed or unavailable.
    func awaitTurnCompletion(_ turnHandle: ConversationTurnHandle) async {
        activeConversationStreamHandle = turnHandle.streamHandle
        let outcome = await turnHandle.outcome

        let clock = ContinuousClock()
        let fallbackAt = clock.now + .milliseconds(250)
        while activeConversationStreamHandle?.id == outcome.streamHandle.id,
              clock.now < fallbackAt {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                break
            }
        }

        // If the drain task already consumed the terminal event, it has also
        // cleared the handle and updated observable state. If another turn has
        // started, do not let this stale outcome clobber it.
        guard activeConversationStreamHandle?.id == outcome.streamHandle.id else {
            return
        }

        applyTerminalOutcome(outcome)
    }

    /// Suspends until `activeConversationStreamHandle` becomes `nil`.
    func awaitStreamCompletion() async {
        // Yield once so the runtime event drain task gets an immediate
        // scheduling opportunity on the same actor before we park.
        await Task.yield()
        // why: park on a continuation instead of polling. The terminal handlers
        // clear the handle and call `resumeStreamCompletionWaiters()`, which
        // wakes every parked caller. @MainActor serialization guarantees the
        // nil check and the append cannot interleave with a resume.
        guard activeConversationStreamHandle != nil else { return }
        await withCheckedContinuation { streamCompletionWaiters.append($0) }
    }

    /// Wakes every caller parked in ``awaitStreamCompletion()`` once the active
    /// stream handle has been cleared. No-op while a stream is still in flight.
    private func resumeStreamCompletionWaiters() {
        guard activeConversationStreamHandle == nil else { return }
        let waiters = streamCompletionWaiters
        streamCompletionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Post-Generation Tasks

    /// Runs `postGenerationTasks` sequentially. Errors are surfaced via
    /// `onSetBackgroundTaskError` and do not cancel subsequent tasks.
    func runPostGenerationTasks(message: ChatMessage, session: ChatSession) {
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
    ///
    /// Pure, buffer-free helper retained for tests and non-hot-path callers
    /// (`ChatViewModel.appendVisibleText` forwards here). The streaming hot path
    /// goes through ``appendStreamingDelta(_:to:)`` instead, which avoids the
    /// O(N) `existing + batch` copy this helper performs.
    static func appendVisibleText(_ batch: String, into msg: inout ChatMessage) {
        if let lastIdx = msg.contentParts.indices.reversed().first(where: {
            if case .text = msg.contentParts[$0] { return true } else { return false }
        }), case .text(let existing) = msg.contentParts[lastIdx] {
            msg.contentParts[lastIdx] = .text(existing + batch)
        } else {
            msg.contentParts.append(.text(batch))
        }
    }

    /// Streaming-path text append. Accumulates into ``streamingTailBuffer``
    /// (amortized O(1)) and writes the whole buffer into the message's trailing
    /// `.text` run, killing the O(N²) per-batch string concat.
    ///
    /// The buffer is keyed to a single trailing text run. If a non-text part
    /// (tool result, thinking) has started a NEW trailing text run since the
    /// last delta, the buffer is reset so we never append the second run's
    /// tokens onto the first run's text.
    private func appendStreamingDelta(_ delta: String, to messageID: UUID) {
        // Detect a fresh trailing text run: either we switched messages, or the
        // current message's last text part no longer matches our buffer (a
        // sibling part was appended, opening a new run).
        let trailingText = currentTrailingTextRun(of: messageID)
        if streamingTailMessageID != messageID || trailingText != streamingTailBuffer {
            streamingTailMessageID = messageID
            streamingTailBuffer = trailingText ?? ""
        }

        streamingTailBuffer.append(delta)
        let whole = streamingTailBuffer
        _ = mutateMessage(messageID) { msg in
            Self.writeTrailingText(whole, into: &msg)
        }
    }

    /// Returns the text of the current trailing `.text` run of the message, or
    /// `nil` when the message has no parts / does not end in a text run.
    private func currentTrailingTextRun(of messageID: UUID) -> String? {
        guard let msg = currentMessages().first(where: { $0.id == messageID }) else { return nil }
        guard case .text(let existing)? = msg.contentParts.last else { return nil }
        return existing
    }

    /// Replaces the message's trailing `.text` run with `whole`, or appends a
    /// new `.text` part when the trailing part is not text.
    private static func writeTrailingText(_ whole: String, into msg: inout ChatMessage) {
        if case .text? = msg.contentParts.last {
            msg.contentParts[msg.contentParts.count - 1] = .text(whole)
        } else {
            msg.contentParts.append(.text(whole))
        }
    }

    /// Clears the streaming text accumulator. Called on every terminal path
    /// (finish / cancel / error / empty) so a stale buffer cannot bleed into a
    /// later turn.
    private func clearStreamingTailBuffer() {
        streamingTailBuffer = ""
        streamingTailMessageID = nil
    }

    /// Writes `partial` into the last in-flight `.thinking` part for live preview.
    static func writeThinkingPartialText(_ partial: String, into msg: inout ChatMessage) {
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
            if messages.contains(where: { $0.id == record.id }) {
                _ = mutateMessage(record.id) { msg in
                    msg.timestamp = record.timestamp
                    msg.promptTokens = record.promptTokens
                    msg.completionTokens = record.completionTokens
                    msg.status = record.status
                }
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
            // Fresh turn — drop any leftover accumulator and re-key on demand.
            clearStreamingTailBuffer()
            if let activeSessionID = currentActiveSessionID(),
               !currentMessages().contains(where: { $0.id == messageID }) {
                let placeholder = ChatMessage(
                    id: messageID,
                    role: .assistant,
                    content: "",
                    sessionID: activeSessionID
                )
                appendMessage(placeholder)
            }

        case .tokenEmitted(let messageID, let delta):
            transitionPhase(to: .streaming)
            appendStreamingDelta(delta, to: messageID)

        case .tokenUsageRecorded(let messageID, let promptTokens, let completionTokens):
            _ = mutateMessage(messageID) {
                $0.promptTokens = promptTokens
                $0.completionTokens = completionTokens
            }

        case .streamFinished(let messageID, let reason):
            guard messageID == activeConversationMessageID else { break }
            activeConversationMessageID = nil
            clearStreamingTailBuffer()

            activeConversationStreamHandle = nil
            resumeStreamCompletionWaiters()
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

            if reason == .length,
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
            case .preTurnCompressionFailed(let underlying):
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
            clearStreamingTailBuffer()
            resumeStreamCompletionWaiters()
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
             .compressionTriggered, .toolCallApproved,
             .historyShaped:
            break

        case .historyCompressed:
            break

        case .agentHandoff:
            // Handoff chips are rendered as a pure function of the persisted
            // message sequence (see ChatView.handoffChip). The event itself
            // is observational — no UI mutation here.
            break

        case .skillInvoked(let name, let sessionID):
            // v1 has no skill UI; log so the dispatch is visible during
            // debugging. UI surfaces for skill invocation are deferred.
            Log.ui.info("Skill invoked: \(name, privacy: .public) (session: \(sessionID.uuidString, privacy: .public))")

        case .hookFired:
            // Hooks are diagnostic; no UI changes in v1.
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

    private func applyTerminalOutcome(_ outcome: ConversationTurnOutcome) {
        activeConversationStreamHandle = nil
        resumeStreamCompletionWaiters()
        activeConversationMessageID = nil
        clearStreamingTailBuffer()
        transitionPhase(to: .idle)

        if let error = outcome.error {
            surface(conversationError: error)
            if case .cancelled = error {
                onSetLastTurnState(.idle)
            } else {
                markMostRecentUserMessageFailed()
                onSetLastTurnState(.failed(error))
            }
            return
        }

        if outcome.reason == .empty, let assistantMessageID = outcome.assistantMessageID {
            removeMessages { $0.id == assistantMessageID }
        } else if let assistantMessage = outcome.assistantMessage,
                  assistantMessage.sessionID == currentActiveSessionID() {
            if currentMessages().contains(where: { $0.id == assistantMessage.id }) {
                _ = mutateMessage(assistantMessage.id) {
                    Self.mergeTerminalAssistant(assistantMessage, into: &$0)
                }
            } else {
                appendMessage(assistantMessage)
            }
        }

        updateContextEstimate()

        if outcome.reason == .stop,
           let completed = outcome.assistantMessageID.flatMap({ id in
               currentMessages().first(where: { $0.id == id })
           }) ?? outcome.assistantMessage,
           completed.hasVisibleContent,
           let session = currentActiveSession() {
            onSetLastTurnState(.completed(completed))
            runPostGenerationTasks(message: completed, session: session)
        } else {
            onSetLastTurnState(.idle)
        }

        if outcome.reason == .length,
           ManifoldConfiguration.shared.features.showUpgradeHint,
           let completed = outcome.assistantMessageID.flatMap({ id in
               currentMessages().first(where: { $0.id == id })
           }) ?? outcome.assistantMessage,
           completed.hasVisibleContent {
            setShowUpgradeHint(true)
        }
    }

    private func surface(conversationError error: ConversationError) {
        switch error {
        case .persistence(let underlying):
            surfaceError(underlying, .persistence)
        case .inference(let underlying):
            surfaceError(underlying, .generation)
        case .cancelled:
            break
        case .contextAssembly(let underlying):
            surfaceError(underlying, .generation)
        case .preTurnCompressionFailed(let underlying):
            surfaceError(underlying, .generation)
        case .messageNotFound, .noAssistantMessageToRegenerate, .providerNotConfigured, .messageTooLarge:
            setErrorMessage(error.localizedDescription)
        }
    }

    private static func mergeTerminalAssistant(
        _ terminal: ChatMessage,
        into current: inout ChatMessage
    ) {
        let liveNonTextParts = current.contentParts.filter { part in
            if case .text = part { return false }
            return true
        }
        current = terminal
        current.contentParts = liveNonTextParts
        if !terminal.content.isEmpty {
            current.contentParts.append(.text(terminal.content))
        }
    }
}
