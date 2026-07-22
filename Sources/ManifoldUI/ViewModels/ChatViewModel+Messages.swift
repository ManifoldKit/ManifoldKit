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
/// - ``noModelLoaded`` — `isModelLoaded` was `false` at call time and no load
///   was in flight.
/// - ``modelLoading`` — `isModelLoaded` was `false` because a load was still
///   in flight — distinguishable from ``noModelLoaded`` so a caller isn't left
///   guessing whether the missing model is "still loading" or "silently
///   failed" (#2222). Check ``ChatViewModel/modelLoadState`` or `await` the
///   original `loadSelectedEndpoint()` / `loadSelectedModel()` call instead of
///   racing this precondition.
/// - ``empty`` — the turn ended (`lastTurnState == .idle`) with no assistant
///   record produced and no error surfaced.
/// - ``runtime(_:)`` — the underlying `ConversationRuntime` produced an
///   error (persistence / inference / context assembly / cancellation).
public enum SendMessageError: Error, Sendable {
    /// `activeSessionID` was `nil`. Create or select a session first.
    case noActiveSession
    /// No model is loaded and none is loading. Select a model from the
    /// sidebar first.
    case noModelLoaded
    /// A model/endpoint load is in flight (``ChatViewModel/isLoading``).
    /// Wait for it — poll or observe ``ChatViewModel/modelLoadState`` — then
    /// retry, rather than treating this as a configuration failure.
    case modelLoading
    /// The `text` argument was empty (or whitespace-only) and no attachments
    /// were staged, so there is nothing to send. Distinct from ``empty`` —
    /// that case means a turn ran and produced no output; this case means no
    /// turn ran at all. Without this check, the no-arg ``ChatViewModel/sendMessage()``
    /// silently no-ops on empty input and this throwing overload would fall
    /// through to `lastTurnState`, returning the *previous* turn's completed
    /// record as if it were this call's reply (#A4).
    case emptyInput
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
        case .modelLoading:
            return "A model is still loading. Wait for it to finish before sending."
        case .emptyInput:
            return "Message text is empty and no attachments are staged. Nothing to send."
        case .empty:
            return "Turn ended without producing a response."
        case let .runtime(error):
            return error.localizedDescription
        }
    }
}

// MARK: - SendMessageError + BackendError
//
// `SendMessageError` is the type ``ChatViewModel/sendMessage(_:)`` /
// ``ChatViewModel/respond(to:)`` / ``QuickStartResult/respond(_:)`` /
// ``QuickStartResult/respond(to:)`` actually throw — every one of those
// convenience entry points bottoms out in ``ChatViewModel/sendMessage(_:)``.
// `BackendError` is declared in `ManifoldContract` and visible here through
// `ManifoldInference`'s `@_exported import` of it.
extension SendMessageError: BackendError {
    /// Whether retrying the same call, unchanged, has a reasonable chance of
    /// succeeding.
    ///
    /// Reasoning per case:
    /// - ``noActiveSession``, ``noModelLoaded`` — preconditions the caller
    ///   can observe and fix (select a session, load a model) before calling
    ///   again; retrying the identical call reproduces the same failure.
    /// - ``modelLoading`` — the missing precondition resolves itself once the
    ///   in-flight load finishes; unlike ``noModelLoaded`` the caller doesn't
    ///   need to change anything before retrying, just wait.
    /// - ``empty`` — the turn ran and produced no visible content but raised
    ///   no error. Sampling is stochastic, so re-sending the identical turn
    ///   can legitimately produce output next time; this is the one case
    ///   where "just try again" is a reasonable UI affordance (e.g. a
    ///   regenerate action) rather than a fix-something prompt.
    /// - ``runtime(_:)`` — defers to the wrapped error's own
    ///   ``BackendError/isRetryable`` when it conforms (true today for every
    ///   ``ConversationError``/``InferenceError``/``CloudBackendError`` the
    ///   runtime can surface); falls back to `false` for an unrecognised
    ///   underlying type (e.g. ``ChatErrorBridge``) rather than guessing.
    public var isRetryable: Bool {
        switch self {
        case .noActiveSession, .noModelLoaded, .emptyInput:
            return false
        case .modelLoading, .empty:
            return true
        case .runtime(let error):
            return (error as? any BackendError)?.isRetryable ?? false
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
    /// - Throws: ``SendMessageError`` — `.noActiveSession` / `.noModelLoaded` /
    ///   `.modelLoading` for precondition failures, `.emptyInput` when `text`
    ///   is empty (or whitespace-only) with no staged attachments, `.empty`
    ///   when the turn produces no assistant record, or `.runtime(error)`
    ///   when the underlying runtime surfaces an error.
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
            // A load in flight is not the same failure as nothing selected:
            // the old bare `.noModelLoaded` here was indistinguishable from a
            // silent failure to a caller with no visibility into `activeError`
            // (#2222) — surface the distinct, self-resolving case instead.
            if isLoading {
                throw SendMessageError.modelLoading
            }
            throw SendMessageError.noModelLoaded
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty else {
            // The no-arg sendMessage() silently no-ops on empty-after-trim
            // input with no attachments. Without this guard, falling through
            // to it here would leave lastTurnState untouched and this method
            // would return the PREVIOUS turn's completed record as if it were
            // this call's reply (#A4).
            throw SendMessageError.emptyInput
        }
        guard !Self.containsUndeliverableAudioAttachment(draftAttachments, backendCapabilities: backendCapabilities) else {
            // Same #A4 stale-record hazard as the emptyInput guard above, and
            // it is NOT a hypothetical: a prior successful call leaves
            // lastTurnState == .completed(record1); without this precheck,
            // the inner sendMessage() call below hits its own audio guard
            // (which returns early WITHOUT touching lastTurnState) and this
            // method's `switch lastTurnState` then matches the stale
            // .completed(record1) — returning the PREVIOUS turn's record as
            // this call's reply instead of throwing. Caught in review of
            // #2356; see ChatViewModelSendMessageErrorTests.
            throw SendMessageError.runtime(Self.undeliverableAudioAttachmentError())
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
            // Distinguish "still loading" from "nothing selected" from "selected
            // but never loaded" (#2222). The middle case is the silent-inert-surface
            // trap: setting `selectedModel` / `selectedEndpoint` only *records* a
            // choice — a host must still call `dispatchSelectedLoad()` (or
            // `loadSelectedModel()` / `loadSelectedEndpoint()`) to bring the backend
            // up. A send that lands here with a live selection means that dispatch
            // was missed, so make it loud (a warning + a distinct, actionable
            // message) rather than the generic "select a model" text that misleads
            // a host who already did.
            if isLoading {
                activeError = ChatError(kind: .configuration, message: "A model is still loading. Wait for it to finish before sending.", recovery: .dismissOnly)
            } else if selectedModel != nil || selectedEndpoint != nil {
                Log.ui.warning("sendMessage with a selected but unloaded model/endpoint — selection records intent only; call dispatchSelectedLoad() (or loadSelectedModel()/loadSelectedEndpoint()) before sending.")
                activeError = ChatError(kind: .configuration, message: "A model is selected but not loaded yet. Load it before sending.", recovery: .selectModel)
            } else {
                activeError = ChatError(kind: .configuration, message: "No model loaded. Select a model from the sidebar first.", recovery: .selectModel)
            }
            return
        }

        // Gated on BackendCapabilities.supportsAudioInput (#2353): no backend
        // in this package claims it yet, so this still fails closed for every
        // backend today. `MessagePart.textContent` returns nil for `.audio`
        // (ManifoldContract), `PromptRenderer.warnIfMultimodalPartsDropped`
        // drops it with only a log, and `CloudMessageEncoder` has no `.audio`
        // case — a backend that hasn't claimed the capability truly cannot
        // hear it. Sending it silently would show the user their voice note
        // "sent" while the model never receives it. Fail loudly instead of
        // dropping it on the floor; real encoding for capable backends is
        // tracked separately in #2353.
        //
        // This guard protects the no-arg entry point (ChatInputBar's actual
        // call path). It deliberately does NOT touch `lastTurnState` — the
        // throwing `sendMessage(_:)` overload above has its OWN precheck for
        // this same condition specifically so it never falls through to this
        // early return and reads a stale `lastTurnState` (#A4 hazard fixed
        // in review of #2356). Do not remove either guard.
        guard !Self.containsUndeliverableAudioAttachment(attachments, backendCapabilities: backendCapabilities) else {
            surfaceError(
                Self.undeliverableAudioAttachmentError(),
                kind: .configuration,
                context: "sending audio attachment"
            )
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

    /// Re-attempts delivery of a user message whose send previously failed.
    ///
    /// When a send turn faults, the runtime marks the most recent user message
    /// with ``MessageStatus/failed`` but leaves its content intact so the user
    /// does not have to retype. This re-runs that message through the same
    /// `.edit` turn flow the runtime uses for user-message edits — re-running
    /// the content unchanged truncates any trailing artifacts and regenerates
    /// the assistant reply, which is exactly the resend semantic.
    ///
    /// No-op when the message is missing, is not a user message, did not fail,
    /// while a generation is in flight, or when no session is active.
    public func retrySend(_ messageID: UUID) async {
        guard let message = messages.first(where: { $0.id == messageID }) else { return }
        guard message.role == .user, message.status == .failed else { return }
        guard !isGenerating else { return }
        // Bail before the optimistic status flip if there's no session to run
        // the turn on — otherwise `editMessage` returns early and leaves the
        // bubble stuck on "Sending…" with no terminal outcome to clear it.
        guard activeSessionID != nil else { return }

        // Optimistically flip the bubble back to "Sending…" so the retry is
        // visible immediately; the runtime's terminal outcome re-marks it
        // `.failed` (markMostRecentUserMessageFailed) if the resend faults too.
        mutateMessage(id: messageID) { $0.status = .sending }
        await editMessage(messageID, newContent: message.content)
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
            generation: GenerationConfig(
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty
            ),
            maxOutputTokens: maxOutputTokens,
            maxThinkingTokens: maxThinkingTokens,
            streamingUpdateInterval: streamingUpdateInterval,
            streamingBatchCharacterLimit: streamingBatchCharacterLimit,
            thinkingStreamingUpdateInterval: thinkingStreamingUpdateInterval,
            thinkingStreamingBatchCharacterLimit: thinkingStreamingBatchCharacterLimit,
            loopDetectionEnabled: loopDetectionEnabled
        )
    }

    // MARK: - Undeliverable audio attachment (shared by both sendMessage entry points)

    /// `true` when `parts` contains a `.audio` `MessagePart` AND the active
    /// backend hasn't claimed ``BackendCapabilities/supportsAudioInput`` (#2353).
    /// Capability-gated rather than an unconditional ban so a future
    /// audio-capable backend can flip this open — mirrors the vision guard's
    /// shape (`GenerationQueue`'s `containsImages`/`supportsVision` check).
    /// Today no backend in this package sets `supportsAudioInput: true`, so
    /// behavior is unchanged: every `.audio` attachment still fails closed.
    /// Shared by ``sendMessage(_:)``'s precheck and the no-arg
    /// ``sendMessage()``'s inner guard so both throw/surface the identical
    /// message instead of two copies drifting apart.
    static func containsUndeliverableAudioAttachment(
        _ parts: [MessagePart],
        backendCapabilities: BackendCapabilities?
    ) -> Bool {
        guard backendCapabilities?.supportsAudioInput != true else { return false }
        return parts.contains(where: { if case .audio = $0 { return true } else { return false } })
    }

    /// The error both `.audio`-attachment guards surface. A single source of
    /// truth for the copy — see ``containsUndeliverableAudioAttachment(_:backendCapabilities:)``.
    static func undeliverableAudioAttachmentError() -> InferenceError {
        .inferenceFailure(
            "Voice messages can't be sent yet — no backend in this build can hear audio attachments. Remove the recording and send text instead."
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

    /// Stages a raw image for the next user turn (#1298).
    ///
    /// Convenience over ``stageAttachment(_:)`` for the common multimodal case:
    /// hosts pass image bytes + MIME type and MK builds the
    /// ``MessagePart/image(data:mimeType:placeholderHash:)`` part, routing it
    /// through the same internal path the bundled `ChatInputBar` uses — so
    /// placeholder-hash generation (and any future side effects on that path)
    /// fire identically for host-supplied composers. Callers that already hold a
    /// constructed ``MessagePart`` should use ``stageAttachment(_:)`` directly.
    ///
    /// - Parameters:
    ///   - data: The raw image bytes the model is asked to look at.
    ///   - mimeType: The image MIME type, e.g. `"image/png"` or `"image/jpeg"`.
    public func attachImage(_ data: Data, mimeType: String) {
        stageDraftAttachment(.image(data: data, mimeType: mimeType))
    }
}
