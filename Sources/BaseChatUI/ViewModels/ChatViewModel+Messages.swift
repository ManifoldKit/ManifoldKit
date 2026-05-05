import Foundation
import BaseChatRuntime
import BaseChatInference

// MARK: - ChatViewModel + Messages

extension ChatViewModel {

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

        let resolvedSystemPrompt = effectiveSystemPrompt()
        let input = SendInput(
            sessionID: activeSessionID,
            userText: text,
            attachments: attachments,
            systemPrompt: resolvedSystemPrompt,
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
        do {
            let handle = try await conversationRuntime.send(input)
            activeConversationStreamHandle = handle
            await awaitStreamCompletion()
        } catch {
            Log.persistence.error("ConversationRuntime.send failed: \(error)")
            surfaceError(error, kind: .persistence)
        }
    }

    /// Regenerates the last assistant response.
    public func regenerateLastResponse() async {
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        let input = RegenerateInput(
            sessionID: activeSessionID,
            systemPrompt: effectiveSystemPrompt(),
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
        do {
            let handle = try await conversationRuntime.regenerate(input)
            activeConversationStreamHandle = handle
            await awaitStreamCompletion()
        } catch {
            Log.ui.error("ConversationRuntime.regenerate failed: \(error)")
            surfaceError(error, kind: .generation)
        }
    }

    /// Edits a message and regenerates everything after it.
    public func editMessage(_ messageID: UUID, newContent: String) async {
        guard messages.firstIndex(where: { $0.id == messageID }) != nil else { return }
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        let input = EditInput(
            sessionID: activeSessionID,
            messageID: messageID,
            newContent: newContent,
            systemPrompt: effectiveSystemPrompt(),
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
        // Invalidate the token cache for the edited message — content changed.
        tokenCountCache.removeValue(forKey: messageID)
        do {
            let handle = try await conversationRuntime.edit(input)
            activeConversationStreamHandle = handle
            await awaitStreamCompletion()
        } catch {
            Log.ui.error("ConversationRuntime.edit failed: \(error)")
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
        // still load-bearing — it's how `awaitStreamCompletion()` resumes
        // (clearing `activeConversationStreamHandle`) and how persistence of
        // the partial reply happens. Do NOT clear the handle here; let the
        // drain task clear it when the cancellation has fully propagated.
        transitionPhase(to: .idle)
        // Always forward to the backend — call sites like memory-pressure
        // handlers and scenePhase teardown invoke this defensively even
        // when no generation is active. A no-op stop on an idle backend is
        // safe; conversely, dropping the call risks orphaning a
        // mid-flight inference if the runtime's handle bookkeeping raced.
        inferenceService.stopGeneration()
        guard let handle = activeConversationStreamHandle else {
            Log.ui.debug("stopGeneration called with no active runtime stream — backend stopped anyway")
            return
        }
        let runtime = conversationRuntime
        Task {
            await runtime.cancel(handle)
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
        let input = BranchInput(
            sourceSessionID: activeSessionID,
            branchMessageID: messageID
        )
        do {
            _ = try await conversationRuntime.branch(input)
        } catch {
            Log.ui.error("ConversationRuntime.branch failed: \(error)")
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
        backgroundTask?.cancel()
        backgroundTask = nil

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
        id messageID: ChatMessageRecord.ID,
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
}
