import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - SendMessageError

/// Typed failure modes for ``ChatViewModel/sendMessage(_:)``.
///
/// Replaces the old `NoResponseError` opaque struct so callers can
/// pattern-match the actual upstream failure rather than guess from the
/// localizedDescription. Each case maps to one observable precondition or
/// outcome of a single-turn drive:
///
/// - ``noActiveSession`` — `activeSessionID` was `nil` at call time.
/// - ``noModelLoaded`` — `isModelLoaded` was `false` at call time.
/// - ``empty`` — the turn ended (`lastTurnState == .idle`) with no assistant
///   record produced and no error surfaced.
/// - ``runtime(_:)`` — the underlying `ConversationRuntime` produced an
///   error (persistence / inference / context assembly / cancellation).
public enum SendMessageError: Error, Sendable {
    /// `activeSessionID` was `nil`. Create or select a session first.
    case noActiveSession
    /// No model is loaded. Select a model from the sidebar first.
    case noModelLoaded
    /// The turn ended without producing tokens and without an error.
    /// Maps to a runtime ``FinishReason/empty`` or a precondition that
    /// was satisfied at call time but produced no output downstream.
    case empty
    /// The runtime surfaced an error. The wrapped value is whatever the
    /// runtime reported (typically `ConversationError` or `ChatError`).
    case runtime(any Error)
}

extension SendMessageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active session. Create or select a session first."
        case .noModelLoaded:
            return "No model loaded. Select a model from the sidebar first."
        case .empty:
            return "Turn ended without producing a response."
        case let .runtime(error):
            return error.localizedDescription
        }
    }
}

// MARK: - ChatErrorBridge

/// Adapts a ``ChatError`` value type into something that conforms to
/// `Error`. ``ChatError`` deliberately does not conform to `Error` (it's a
/// presentation-layer struct with `kind`/`recovery`/`message`); when
/// ``ChatViewModel/sendMessage(_:)`` needs to surface a precondition error
/// that lives only on `activeError`, this bridge lifts it into the typed
/// `Error` channel without forcing `ChatError` itself to conform.
struct ChatErrorBridge: LocalizedError, Sendable {
    let chatError: ChatError
    var errorDescription: String? { chatError.message }
}

// MARK: - ChatViewModel + Messages

extension ChatViewModel {

    /// Sends `text` as a user message and returns the completed assistant response.
    ///
    /// Convenience for scripted drivers and integration tests that want to drive
    /// one turn without setting `inputText` and polling observation surfaces.
    ///
    /// - Throws: ``SendMessageError`` — `.noActiveSession` / `.noModelLoaded` for
    ///   precondition failures, `.empty` when the turn produces no assistant
    ///   record, or `.runtime(error)` when the underlying runtime surfaces an
    ///   error.
    @discardableResult
    public func sendMessage(_ text: String) async throws -> ChatMessage {
        // Check preconditions BEFORE invoking the runtime so callers that
        // pattern-match on SendMessageError see the precondition case rather
        // than an opaque runtime error. The inner sendMessage() also performs
        // these checks (and surfaces them via activeError / errorMessage),
        // but routing them here gives the typed-error caller a clean shape.
        guard activeSessionID != nil else {
            throw SendMessageError.noActiveSession
        }
        guard isModelLoaded else {
            throw SendMessageError.noModelLoaded
        }

        inputText = text
        await sendMessage()
        switch lastTurnState {
        case .completed(let record):
            return record
        case .failed(let error):
            throw SendMessageError.runtime(error)
        case .idle, .generating:
            // The inner sendMessage() may have surfaced the failure on
            // `activeError` (e.g. precondition that flipped between our
            // check above and the inner check, or a runtime fault that
            // couldn't be reported through `lastTurnState`). Propagate as
            // `.runtime(activeError)` so the caller still sees the typed
            // shape; fall back to `.empty` when no error was recorded.
            if let active = activeError {
                // ChatError is a value type without `Error` conformance —
                // the API freeze pins its shape so we can't retroactively
                // conform it. Use the wrapped underlying error if it's
                // available; otherwise wrap the message in an ad-hoc
                // bridge so the typed shape is preserved.
                if let underlying = active.underlyingError {
                    throw SendMessageError.runtime(underlying)
                }
                throw SendMessageError.runtime(ChatErrorBridge(chatError: active))
            }
            throw SendMessageError.empty
        }
    }

    /// Sends the current text and any staged attachments as a user message and generates an assistant response.
    public func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draftAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }

        guard let activeSessionID else {
            errorMessage = "No active session. Create or select a session first."
            return
        }

        guard isModelLoaded else {
            activeError = ChatError(kind: .configuration, message: "No model loaded. Select a model from the sidebar first.", recovery: .selectModel)
            return
        }

        errorMessage = nil
        inputText = ""
        draftAttachments = []
        Log.ui.debug("User sent message")

        // Trigger auto-title on the first user message in this session.
        // Done before runtime.send() so the host can rename in parallel with
        // the streaming response — the runtime owns persistence of the user
        // message and the assistant reply.
        let willBeFirstUserMessage = messages.filter { $0.role == .user }.isEmpty
        if let session = activeSession, !text.isEmpty, willBeFirstUserMessage {
            await onFirstMessage?(session, text)
        }

        let input = TurnInput(
            sessionID: activeSessionID,
            kind: .send(text: text, attachments: attachments),
            config: makeTurnConfig(systemPrompt: effectiveSystemPrompt())
        )
        do {
            if let handle = try await conversationRuntime.processTurnWithOutcome(input) {
                await awaitTurnCompletion(handle)
            } else {
                await Task.yield()
            }
        } catch {
            Log.persistence.error("ConversationRuntime.processTurnWithOutcome(.send) failed: \(error)")
            surfaceError(error, kind: .persistence)
        }
    }

    /// Regenerates the last assistant response.
    public func regenerateLastResponse() async {
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        let input = TurnInput(
            sessionID: activeSessionID,
            kind: .regenerate,
            config: makeTurnConfig(systemPrompt: effectiveSystemPrompt())
        )
        do {
            if let handle = try await conversationRuntime.processTurnWithOutcome(input) {
                await awaitTurnCompletion(handle)
            } else {
                await Task.yield()
            }
        } catch {
            Log.ui.error("ConversationRuntime.processTurnWithOutcome(.regenerate) failed: \(error)")
            surfaceError(error, kind: .generation)
        }
    }

    /// Edits a message and regenerates everything after it.
    public func editMessage(_ messageID: UUID, newContent: String) async {
        guard messages.firstIndex(where: { $0.id == messageID }) != nil else { return }
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        let input = TurnInput(
            sessionID: activeSessionID,
            kind: .edit(messageID: messageID, text: newContent),
            config: makeTurnConfig(systemPrompt: effectiveSystemPrompt())
        )
        // Invalidate the token cache for the edited message — content changed.
        tokenCountCache.removeValue(forKey: messageID)
        do {
            if let handle = try await conversationRuntime.processTurnWithOutcome(input) {
                await awaitTurnCompletion(handle)
            } else {
                await Task.yield()
            }
        } catch {
            Log.ui.error("ConversationRuntime.processTurnWithOutcome(.edit) failed: \(error)")
            surfaceError(error, kind: .generation)
        }
    }

    /// Stops an in-progress generation.
    ///
    /// **Stays sync intentionally.** Cancellation itself is synchronous — the
    /// task tear-down and inference-side stop happen immediately. The trailing
    /// persistence save (capturing whatever streamed into the last assistant
    /// message before cancel) is dispatched on a fire-and-forget `Task` so
    /// the sync surface is preserved for the many sync call sites:
    /// toolbar buttons, session-switch teardown, `scenePhase` handlers, and
    /// `handleMemoryPressure()`. Converting this to `async throws` would
    /// require every one of those sites to wrap in `Task { ... }` without
    /// changing observable semantics. Keep sync; do not "fix" the
    /// inconsistency in a future refactor.
    public func stopGeneration() {
        // Drive UI back to idle synchronously so call sites like the toolbar
        // stop-button get immediate feedback. The runtime's subsequent
        // `.streamFinished(reason: .cancelled)` event is a no-op for phase
        // (the state machine treats `idle → idle` as `.unchanged`) but it's
        // still load-bearing — it's how live event reduction observes the
        // terminal state and how persistence of the partial reply happens. Do
        // NOT clear the handle here; let the runtime outcome or drain task
        // clear it when the cancellation has fully propagated.
        //
        // Always forward to the backend — call sites like memory-pressure
        // handlers and scenePhase teardown invoke this defensively even
        // when no generation is active. A no-op stop on an idle backend is
        // safe; conversely, dropping the call risks orphaning a
        // mid-flight inference if the runtime's handle bookkeeping raced.
        transitionPhase(to: .idle)
        inferenceService.stopGeneration()
        guard let handle = generationCoordinator.activeConversationStreamHandle else {
            Log.ui.debug("stopGeneration called with no active runtime stream — backend stopped anyway")
            return
        }
        let rt = conversationRuntime
        Task {
            await rt.cancel(handle)
        }
        Log.ui.debug("Generation stopped by user")
    }

    /// Removes a single message from the active session.
    ///
    /// Deletes the message from persistence and the in-memory transcript.
    /// No-op when the message is not present in the active session, or when
    /// no session is active. Errors propagate via ``surfaceError(_:kind:)``.
    public func deleteMessage(id messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = messages[index]
        // Remove from in-memory transcript first so the UI reflects the
        // deletion immediately. If persistence fails we surface the error
        // and reload to reconcile — matches `clearChat`'s pattern.
        messages.remove(at: index)
        tokenCountCache.removeValue(forKey: messageID)
        pinnedMessageIDs.remove(messageID)
        do {
            try await deleteMessage(message)
            updateContextEstimate()
        } catch {
            Log.persistence.error("Failed to delete message: \(error)")
            await loadMessages()
            updateContextEstimate()
            surfaceError(error, kind: .persistence)
        }
    }

    /// Forks the current session at `messageID`, creating a new session that
    /// contains the messages up to and including the branch point.
    ///
    /// The runtime persists the new session and copied messages; the
    /// ``onSessionBranched`` callback (when set) is invoked with the new
    /// session ID so the host can refresh its sidebar and select the new
    /// session. No-op when no session is active.
    public func branch(from messageID: UUID) async {
        guard let activeSessionID else { return }
        let input = TurnInput(
            sessionID: activeSessionID,
            kind: .branch(messageID: messageID)
        )
        do {
            _ = try await conversationRuntime.processTurn(input)
        } catch {
            Log.ui.error("ConversationRuntime.processTurn(.branch) failed: \(error)")
            surfaceError(error, kind: .persistence)
        }
    }

    /// Clears all messages in the current session.
    ///
    /// Cancels any in-flight generation before clearing to avoid inconsistent UI state.
    public func clearChat() async {
        if isGenerating {
            stopGeneration()
        }

        // Reset the inference context and wipe any KV-cache residue so
        // prior-session key/value tensors do not linger in process memory.
        inferenceService.resetConversation()
        inferenceService.secureWipe()

        // Cancel any in-flight post-generation background tasks.
        generationCoordinator.cancelBackgroundTask()

        guard let activeSessionID else {
            messages.removeAll()
            tokenCountCache.removeAll()
            hasOlderMessages = false
            updateContextEstimate()
            Log.ui.info("Chat cleared")
            return
        }

        do {
            try await deleteMessages(for: activeSessionID)
            messages.removeAll()
            tokenCountCache.removeAll()
            hasOlderMessages = false
            updateContextEstimate()
            Log.ui.info("Chat cleared")
        } catch {
            Log.persistence.error("Failed to delete messages while clearing chat: \(error)")
            await loadMessages()
            tokenCountCache.removeAll()
            updateContextEstimate()
            surfaceError(error, kind: .persistence)
            return
        }
    }

    // MARK: - Export

    /// Exports the current chat in the specified format.
    public func exportChat(format: ExportFormat) -> String {
        ChatExportService.export(
            messages: messages,
            sessionTitle: activeSession?.title ?? "Chat",
            format: format
        )
    }

    // MARK: - Message Pinning

    /// Marks a message as pinned, preserving it when history is trimmed to fit the context window.
    public func pinMessage(id messageID: UUID) async {
        pinnedMessageIDs.insert(messageID)
        do {
            try await saveSettingsToSession()
        } catch {
            Log.persistence.error("Failed to save pinned message settings: \(error)")
            surfaceError(error, kind: .persistence)
        }
    }

    /// Removes the pin from a message.
    public func unpinMessage(id messageID: UUID) async {
        pinnedMessageIDs.remove(messageID)
        do {
            try await saveSettingsToSession()
        } catch {
            Log.persistence.error("Failed to save unpinned message settings: \(error)")
            surfaceError(error, kind: .persistence)
        }
    }

    /// Returns whether the given message is currently pinned.
    public func isMessagePinned(id messageID: UUID) -> Bool {
        pinnedMessageIDs.contains(messageID)
    }

    // MARK: - Scroll Requests

    /// Requests that the bound ``ChatView`` scroll the message into view.
    ///
    /// Calling this repeatedly for the same message creates distinct requests
    /// so observers can deterministically consume each command.
    public func requestScrollToMessage(
        id messageID: ChatMessage.ID,
        anchor: ChatMessageScrollAnchor? = nil
    ) {
        scrollToMessageRequest = ChatScrollToMessageRequest(messageID: messageID, anchor: anchor)
    }

    /// Clears a pending scroll request once the view has attempted it.
    ///
    /// The request identity check prevents a stale consumer from clearing a
    /// newer request issued for the same or a different message.
    public func consumeScrollToMessageRequest(_ request: ChatScrollToMessageRequest) {
        guard scrollToMessageRequest?.requestID == request.requestID else { return }
        scrollToMessageRequest = nil
    }

    /// Builds a ``TurnConfig`` from the view model's current sampling/streaming
    /// state. Centralised so each turn-flow call site reads the same pinned
    /// snapshot — adding a knob is a one-touch change here, not five edits
    /// across the call sites that used to construct one of `SendInput`,
    /// `RegenerateInput`, `EditInput`, or `BranchInput`.
    func makeTurnConfig(systemPrompt: String?) -> TurnConfig {
        TurnConfig(
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
    }

    func stageDraftAttachment(_ part: MessagePart) {
        draftAttachments.append(part.generatingImagePlaceholderIfNeeded())
    }

    func removeDraftAttachment(id index: Int) {
        guard draftAttachments.indices.contains(index) else { return }
        draftAttachments.remove(at: index)
    }

    func clearDraftAttachments() {
        draftAttachments.removeAll()
    }

    // MARK: - Public staged-attachment surface (issue #1302)

    /// Image / vision parts currently staged for the next user turn.
    ///
    /// Mirrors the array the bundled ``ChatInputBar`` mutates internally so
    /// hosts building custom composers can read the same source of truth.
    public var stagedAttachments: [MessagePart] { draftAttachments }

    /// Appends an attachment to the next user turn.
    ///
    /// Routes through the same internal path the bundled ``ChatInputBar``
    /// uses (``stageDraftAttachment(_:)``) so image-placeholder generation
    /// — and any other side effects added to that path in the future —
    /// fire identically for host-supplied composers.
    public func stageAttachment(_ part: MessagePart) {
        stageDraftAttachment(part)
    }

    /// Removes a previously staged attachment by index. No-op when the
    /// index is out of range so callers driving from indeterminate UI
    /// state (drag sources, async pickers) do not have to pre-validate.
    public func removeStagedAttachment(at index: Int) {
        removeDraftAttachment(id: index)
    }

    /// Clears all staged attachments without sending the turn.
    public func clearStagedAttachments() {
        clearDraftAttachments()
    }
}
