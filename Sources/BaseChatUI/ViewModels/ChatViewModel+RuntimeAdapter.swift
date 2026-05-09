import Foundation
import BaseChatRuntime
import BaseChatInference

// MARK: - LoopDetectedError

private struct LoopDetectedError: LocalizedError {
    var errorDescription: String? {
        "Generation stopped: the model appeared to repeat itself."
    }
}

// MARK: - ChatViewModel + RuntimeAdapter
//
// Maps ConversationEvent values from the optional ConversationRuntime drain
// task back to @Observable state mutations. This file owns the event-to-state
// bridge; ChatViewModel+Messages.swift owns the send/regenerate/edit/stop
// delegation through the runtime.

extension ChatViewModel {

    /// Maps an incoming ``ConversationEvent`` to `@Observable` state mutations.
    ///
    /// Called exclusively from the long-lived drain task started in
    /// ``configure(conversationRuntime:)``. All mutations land on `@MainActor`
    /// so SwiftUI observation picks them up synchronously.
    @MainActor
    func handle(runtimeEvent event: ConversationEvent) async {
        switch event {

        // MARK: Message lifecycle

        case .messageInserted(let record):
            // The runtime persists user and assistant messages and re-emits
            // them via `.messageInserted`. Two cases:
            //
            //  - User message: the adapter has not pre-inserted anything, so
            //    append unconditionally.
            //
            //  - Assistant message: the adapter pre-inserted a placeholder on
            //    `.streamStarted` and grew it via `.tokenEmitted`/`.thinking*`
            //    events. The runtime's persisted record carries only the
            //    visible text (it sets `assistantMessage.content = accumulated`
            //    before insert), which would clobber any thinking parts in the
            //    in-memory placeholder. Keep our richer in-memory parts but
            //    refresh the timestamps and token counts the runtime captured.
            //
            // Drop events whose `sessionID` does not match the active session.
            // After a `switchToSession` mid-generation the prior turn may
            // still emit late `messageInserted` events that, without this
            // gate, would leak the cancelled session's content into the
            // newly-active transcript.
            guard record.sessionID == activeSessionID else { break }
            if let idx = messages.firstIndex(where: { $0.id == record.id }) {
                messages[idx].timestamp = record.timestamp
                messages[idx].promptTokens = record.promptTokens
                messages[idx].completionTokens = record.completionTokens
            } else {
                messages.append(record)
            }

        case .messageRemoved(let id):
            messages.removeAll(where: { $0.id == id })

        case .messageUpdated(let record):
            if let idx = messages.firstIndex(where: { $0.id == record.id }) {
                messages[idx] = record
            }

        // MARK: Stream lifecycle

        case .streamStarted(let messageID):
            // Pre-insert a placeholder assistant slot so subsequent
            // `tokenEmitted` events have a message to mutate. The runtime
            // only persists (and re-emits via `.messageInserted`) the
            // assistant record after the stream ends, so without this the
            // first tokens would be dropped on the floor.
            lastTurnState = .generating
            transitionPhase(to: .waitingForFirstToken)
            activeConversationMessageID = messageID
            if let activeSessionID, !messages.contains(where: { $0.id == messageID }) {
                let placeholder = ChatMessageRecord(
                    id: messageID,
                    role: .assistant,
                    content: "",
                    sessionID: activeSessionID
                )
                messages.append(placeholder)
            }

        case .tokenEmitted(let messageID, let delta):
            transitionPhase(to: .streaming)
            // `ChatMessageRecord.content`'s setter replaces the entire
            // `contentParts` array with a single `.text` part. That clobbers
            // any sibling `.thinking` / `.toolCall` / `.toolResult` parts, so
            // mutate the trailing `.text` part in place (or append a new one
            // when none exists).
            mutateMessage(id: messageID) { Self.appendVisibleText(delta, into: &$0) }

        case .tokenUsageRecorded(let messageID, let promptTokens, let completionTokens):
            mutateMessage(id: messageID) {
                $0.promptTokens = promptTokens
                $0.completionTokens = completionTokens
            }

        case .streamFinished(let messageID, let reason):
            // Drop terminal events that belong to a previous turn —
            // `switchToSession` cancels the current turn but a NEW turn may
            // have started by the time the old turn's `streamFinished`
            // drains. Match against the most-recent `streamStarted`
            // messageID so cancelled-then-replaced turns don't zap the new
            // handle. `clearChat` also cancels the current turn but does
            // not start a new one, so the IDs match and we proceed.
            guard messageID == activeConversationMessageID else { break }
            activeConversationMessageID = nil

            activeConversationStreamHandle = nil
            transitionPhase(to: .idle)
            updateContextEstimate()

            // Drop the empty assistant placeholder if the model produced no
            // visible content. The runtime returns `.empty` for this case
            // and never persists the assistant record itself; mirror that on
            // the in-memory transcript.
            if reason == .empty {
                messages.removeAll(where: { $0.id == messageID })
            }

            // Fire post-generation tasks for successful turns. Cancelled and
            // empty turns are skipped — the legacy `GenerationQueue`
            // gated on `hasVisibleContent`, so partial-cancel persistence
            // does not retroactively run summarisation hooks.
            if reason == .stop,
               let completed = messages.first(where: { $0.id == messageID }),
               completed.hasVisibleContent,
               let session = activeSession {
                lastTurnState = .completed(completed)
                runPostGenerationTasks(message: completed, session: session)
            } else {
                lastTurnState = .idle
            }

            // After the first assistant response on Foundation, nudge the
            // user to consider downloading a local model for longer
            // context. Mirrors the legacy `GenerationQueue` rule:
            // gated on the feature flag, only on the Apple backend, only
            // once per session.
            if reason == .stop,
               BaseChatConfiguration.shared.features.showUpgradeHint,
               !showUpgradeHint,
               let completed = messages.first(where: { $0.id == messageID }),
               completed.hasVisibleContent,
               activeBackendName == BackendName.foundation.rawValue,
               messages.filter({ $0.role == .assistant }).count == 1 {
                showUpgradeHint = true
                onUpgradeHintTriggered?()
            }

        // MARK: Errors

        case .errorRaised(let error):
            switch error {
            case .persistence(let underlying):
                surfaceError(underlying, kind: .persistence)
            case .inference(let underlying):
                surfaceError(underlying, kind: .generation)
            case .cancelled:
                // User-initiated cancel — suppress error UI.
                break
            case .contextAssembly(let underlying):
                surfaceError(underlying, kind: .generation)
            case .messageNotFound, .noAssistantMessageToRegenerate, .providerNotConfigured:
                errorMessage = error.localizedDescription
            }
            if case .cancelled = error {
                lastTurnState = .idle
            } else {
                lastTurnState = .failed(error)
            }
            activeConversationStreamHandle = nil
            activeConversationMessageID = nil
            transitionPhase(to: .idle)

        // MARK: Thinking-block disclosure

        case .thinkingStarted(let messageID):
            // Insert a `.thinking("")` placeholder so the UI can show a
            // "Thinking…" label during the reasoning phase. Mark this
            // message ID as actively streaming thinking content so views
            // can switch between the live-preview affordance and the
            // finalized disclosure group.
            messageIDsWithStreamingThinking.insert(messageID)
            mutateMessage(id: messageID) { msg in
                let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? msg.contentParts.endIndex
                msg.contentParts.insert(.thinking(""), at: insertAt)
            }

        case .thinkingUpdated(let messageID, let partialText):
            // Write `partialText` into the last in-flight `.thinking` part
            // for live preview. Mirrors GenerationQueue.writeThinkingPartialText.
            mutateMessage(id: messageID) { msg in
                guard let idx = msg.contentParts.lastIndex(where: { $0.thinkingContent != nil }) else {
                    return
                }
                let signature = msg.contentParts[idx].thinkingSignature
                msg.contentParts[idx] = .thinking(partialText, signature: signature)
            }

        case .thinkingFinalized(let messageID, let text, let signature):
            // Convert the placeholder to the final text + signature, then
            // clear the streaming indicator so the disclosure UI appears.
            messageIDsWithStreamingThinking.remove(messageID)
            mutateMessage(id: messageID) { msg in
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
            // Wording mirrors the legacy `GenerationQueue` ("appears
            // to be repeating itself") so existing UI tests that probe for
            // the substring "repeating" continue to pin the user-visible
            // message.
            errorMessage = "Generation stopped: the model appears to be repeating itself."
            lastTurnState = .failed(LoopDetectedError())
            transitionPhase(to: .idle)

        // MARK: Session branching

        case .sessionBranched(let newSessionID, _):
            // Forward to the host so its session-manager can refresh the
            // sidebar and select the new session. The runtime has already
            // persisted the new session and copied messages; the callback is
            // pure notification.
            if let onSessionBranched {
                await onSessionBranched(newSessionID)
            }

        // MARK: Observational / future cases

        case .beforeContextAssembly, .contextAssembled, .afterGeneration,
             .sessionTouchFailed,
             .compressionTriggered, .toolCallRequested, .toolCallApproved,
             .toolCallCompleted:
            // These are observational or reserved for future sub-flows.
            // No ChatViewModel state mutation is needed here yet.
            break
        }
    }

    // MARK: - Content-part-preserving mutation helpers
    //
    // `ChatMessageRecord.content`'s setter replaces the entire `contentParts`
    // array with a single `.text` part — convenient for the legacy text-only
    // path, fatal for messages that hold a `.thinking` part placed ahead of
    // the text. These helpers preserve sibling parts by mutating only the
    // trailing `.text` (or appending one when none exists).

    /// Appends streamed visible-token text to a message without clobbering
    /// any existing non-text parts (thinking, tool calls, tool results).
    static func appendVisibleText(_ batch: String, into msg: inout ChatMessageRecord) {
        if let lastIdx = msg.contentParts.indices.reversed().first(where: {
            if case .text = msg.contentParts[$0] { return true } else { return false }
        }), case .text(let existing) = msg.contentParts[lastIdx] {
            msg.contentParts[lastIdx] = .text(existing + batch)
        } else {
            msg.contentParts.append(.text(batch))
        }
    }

    /// Launches `postGenerationTasks` sequentially in a `Task` that inherits
    /// `@MainActor` isolation. A throwing task records its error via
    /// ``backgroundTaskError`` and execution continues with the next task.
    /// Cancellation via ``backgroundTask`` exits the loop.
    func runPostGenerationTasks(message: ChatMessageRecord, session: ChatSessionRecord) {
        let tasks = postGenerationTasks
        guard !tasks.isEmpty else { return }
        backgroundTaskError = nil
        let bgTask = Task { [weak self, tasks, message, session] in
            for task in tasks {
                guard !Task.isCancelled else { break }
                do {
                    try await task.run(message: message, session: session)
                } catch is CancellationError {
                    break
                } catch {
                    self?.backgroundTaskError = error
                }
            }
        }
        backgroundTask = bgTask
    }

    /// Writes `partial` into the message's last `.thinking` part for live preview.
    ///
    /// Mirrors the legacy `GenerationQueue.writeThinkingPartialText` —
    /// retained because tests assert the preserve-placeholder behaviour
    /// directly.
    static func writeThinkingPartialText(_ partial: String, into msg: inout ChatMessageRecord) {
        guard let idx = msg.contentParts.lastIndex(where: { $0.thinkingContent != nil }) else {
            let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? 0
            msg.contentParts.insert(.thinking(partial), at: insertAt)
            return
        }
        // Preserve any signature already attached — partial flushes only
        // update the text. Signatures arrive separately.
        let signature = msg.contentParts[idx].thinkingSignature
        msg.contentParts[idx] = .thinking(partial, signature: signature)
    }
}
