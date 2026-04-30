import Foundation
import BaseChatCore
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

        // Runtime path — delegate to ConversationRuntime when configured.
        if let runtime = conversationRuntime {
            let input = SendInput(
                sessionID: activeSessionID,
                userText: text,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens
            )
            do {
                let handle = try await runtime.send(input)
                activeConversationStreamHandle = handle
            } catch {
                Log.persistence.error("ConversationRuntime.send failed: \(error)")
                surfaceError(error, kind: .persistence)
            }
            return
        }

        // GenerationCoordinator path (existing).

        // Create and persist the user message.
        let userParts = text.isEmpty ? attachments : [.text(text)] + attachments
        let userMessage = ChatMessageRecord(role: .user, contentParts: userParts, sessionID: activeSessionID)
        messages.append(userMessage)
        do {
            try await saveMessage(userMessage)
        } catch {
            Log.persistence.error("Failed to save user message: \(error)")
            surfaceError(error, kind: .persistence)
            messages.removeAll(where: { $0.id == userMessage.id })
            return
        }

        // Update session timestamp.
        do {
            try await sessionController.touchActiveSessionUpdatedAt()
        } catch {
            Log.persistence.error("Failed to persist session timestamp: \(error)")
            surfaceError(error, kind: .persistence)
        }

        // Trigger auto-title on the first user message in this session.
        if let session = activeSession, !text.isEmpty, messages.filter({ $0.role == .user }).count == 1 {
            await onFirstMessage?(session, text)
        }

        // Create an empty assistant message that will be streamed into.
        let assistantMessage = ChatMessageRecord(role: .assistant, content: "", sessionID: activeSessionID)
        messages.append(assistantMessage)

        await generateIntoMessage(assistantMessage)
        updateContextEstimate()
    }

    /// Regenerates the last assistant response.
    public func regenerateLastResponse() async {
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        // Runtime path — delegate to ConversationRuntime when configured.
        if let runtime = conversationRuntime {
            let input = RegenerateInput(
                sessionID: activeSessionID,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens
            )
            do {
                let handle = try await runtime.regenerate(input)
                activeConversationStreamHandle = handle
            } catch {
                Log.ui.error("ConversationRuntime.regenerate failed: \(error)")
                surfaceError(error, kind: .generation)
            }
            return
        }

        // GenerationCoordinator path (existing).

        // Find and remove the last assistant message.
        guard let lastAssistantIndex = messages.lastIndex(where: { $0.role == .assistant }) else {
            return
        }

        let removed = messages.remove(at: lastAssistantIndex)
        do {
            try await deleteMessage(removed)
        } catch {
            Log.persistence.error("Failed to delete prior assistant message: \(error)")
            surfaceError(error, kind: .persistence)
            messages.insert(removed, at: lastAssistantIndex)
            return
        }

        // Create a fresh assistant message.
        let assistantMessage = ChatMessageRecord(role: .assistant, content: "", sessionID: activeSessionID)
        messages.append(assistantMessage)

        Log.ui.debug("Regenerating last response")
        await generateIntoMessage(assistantMessage)
    }

    /// Edits a message and regenerates everything after it.
    public func editMessage(_ messageID: UUID, newContent: String) async {
        guard messages.firstIndex(where: { $0.id == messageID }) != nil else { return }
        guard !isGenerating else { return }

        guard let activeSessionID else { return }

        // Runtime path — delegate to ConversationRuntime when configured.
        if let runtime = conversationRuntime {
            let input = EditInput(
                sessionID: activeSessionID,
                messageID: messageID,
                newContent: newContent,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens
            )
            // Invalidate the token cache for the edited message — content changed.
            tokenCountCache.removeValue(forKey: messageID)
            do {
                let handle = try await runtime.edit(input)
                activeConversationStreamHandle = handle
            } catch {
                Log.ui.error("ConversationRuntime.edit failed: \(error)")
                surfaceError(error, kind: .generation)
            }
            return
        }

        // GenerationCoordinator path (existing).
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }

        // Update the edited message.
        let originalMessage = messages[index]
        let preservedNonTextParts = originalMessage.contentParts.filter { part in
            if case .text = part { return false }
            return true
        }
        messages[index].contentParts = newContent.isEmpty
            ? preservedNonTextParts
            : [.text(newContent)] + preservedNonTextParts
        do {
            try await updateMessage(messages[index])
        } catch {
            messages[index] = originalMessage
            Log.persistence.error("Failed to update edited message: \(error)")
            surfaceError(error, kind: .persistence)
            return
        }

        // The edited message keeps the same UUID but now has different content,
        // so its stale cache entry would be returned by updateContextEstimate().
        tokenCountCache.removeValue(forKey: messageID)

        // Remove all messages after the edited one.
        let toRemove = Array(messages[(index + 1)...])
        messages.removeSubrange((index + 1)...)
        for msg in toRemove {
            do {
                try await deleteMessage(msg)
            } catch {
                Log.persistence.error("Failed to delete message during edit regeneration: \(error)")
                surfaceError(error, kind: .persistence)
                messages = Array(messages.prefix(index + 1)) + toRemove
                return
            }
        }

        // If the edited message was from the user, regenerate the assistant response.
        if messages[index].role == .user {
            let assistantMessage = ChatMessageRecord(role: .assistant, content: "", sessionID: activeSessionID)
            messages.append(assistantMessage)
            Log.ui.debug("Edited user message, regenerating")
            await generateIntoMessage(assistantMessage)
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
        // Runtime path — cancel the in-flight ConversationRuntime stream.
        // The runtime emits `.streamFinished(reason: .cancelled)` which drives
        // `transitionPhase(.idle)` through the drain task — no extra phase
        // transition needed here.
        if let runtime = conversationRuntime, let handle = activeConversationStreamHandle {
            activeConversationStreamHandle = nil
            Task {
                await runtime.cancel(handle)
            }
            Log.ui.debug("Generation stopped by user (runtime path)")
            return
        }

        // GenerationCoordinator path (existing).
        generationTask?.cancel()
        generationTask = nil
        activeGenerationToken = nil
        inferenceService.stopGeneration()
        transitionPhase(to: .idle)

        // Persist whatever has been generated so far.
        if let lastAssistant = messages.last(where: { $0.role == .assistant }),
           !lastAssistant.content.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.saveMessage(lastAssistant)
                } catch {
                    Log.persistence.error("Failed to persist partial assistant message: \(error)")
                    self.surfaceError(error, kind: .persistence)
                }
            }
        }
        Log.ui.debug("Generation stopped by user")
    }

    /// Clears all messages in the current session.
    ///
    /// Cancels any in-flight generation before clearing to avoid inconsistent UI state.
    public func clearChat() async {
        if isGenerating {
            stopGeneration()
        }

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

    func stageDraftAttachment(_ part: MessagePart) {
        draftAttachments.append(part)
    }

    func removeDraftAttachment(id index: Int) {
        guard draftAttachments.indices.contains(index) else { return }
        draftAttachments.remove(at: index)
    }

    func clearDraftAttachments() {
        draftAttachments.removeAll()
    }
}
