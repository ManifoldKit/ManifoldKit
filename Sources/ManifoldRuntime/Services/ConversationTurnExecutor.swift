import Foundation
import ManifoldInference

struct ConversationTurnExecutor: Sendable {
    private let persistence: ConversationPersistencePort
    private let inferenceService: InferenceService
    private let pipeline: PromptContextPipeline?
    private let ragService: RAGService?
    private let registry: InFlightStreamRegistry
    private let eventSink: @Sendable (ConversationEvent) -> Void
    private let emptyResponseObserver: (@Sendable (ConversationRuntime.EmptyResponseDiagnostic) -> Void)?

    init(
        persistence: ConversationPersistencePort,
        inferenceService: InferenceService,
        pipeline: PromptContextPipeline?,
        ragService: RAGService?,
        registry: InFlightStreamRegistry,
        emit: @escaping @Sendable (ConversationEvent) -> Void,
        emptyResponseObserver: (@Sendable (ConversationRuntime.EmptyResponseDiagnostic) -> Void)?
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.pipeline = pipeline
        self.ragService = ragService
        self.registry = registry
        self.eventSink = emit
        self.emptyResponseObserver = emptyResponseObserver
    }

    // MARK: Send flow

    func runSendFlow(
        sessionID: UUID,
        text: String,
        attachments rawAttachments: [MessagePart],
        config: TurnConfig
    ) async throws -> ConversationStreamHandle {
        let handle = ConversationStreamHandle()

        // Persist the user message synchronously so the caller observes
        // ordering (`messageInserted(user)` before `processTurn` returns) —
        // the stream task fires off after this point. Persistence failures
        // throw out so the caller can surface them; matching ChatViewModel's
        // current shape where a user-message persistence failure aborts the
        // turn before any assistant work runs.
        // Build user contentParts: when attachments are present, splice the
        // text part (if any) before the attachments so the persisted record
        // and the structured-history snapshot the runtime hands the backend
        // both carry `[.text, <attachments>...]`. Empty text + attachments
        // yields an attachment-only record (e.g. a "describe this image"
        // turn with no caption).
        let attachments = rawAttachments.map { $0.generatingImagePlaceholderIfNeeded() }
        let userContentParts: [MessagePart]
        if attachments.isEmpty {
            userContentParts = [.text(text)]
        } else if text.isEmpty {
            userContentParts = attachments
        } else {
            userContentParts = [.text(text)] + attachments
        }
        let userMessage = ChatMessageRecord(
            role: .user,
            contentParts: userContentParts,
            sessionID: sessionID
        )
        do {
            try await persistence.insertMessage(userMessage)
        } catch {
            throw ConversationError.persistence(error)
        }
        emit(.messageInserted(userMessage))

        // Touch session updatedAt — best-effort. Persistence errors here
        // are logged and continue; the runtime should not lose a turn over
        // a sidebar-ordering failure.
        if await persistence.touchSession(sessionID: sessionID) == false {
            emit(.sessionTouchFailed(sessionID: sessionID))
        }

        // Detach the streaming work onto an unstructured task so the
        // command returns the handle promptly. The task captures `self`
        // strongly for the duration of the turn — releases via the
        // registry when the turn ends.
        Task.detached { [self] in
            // Fetch history first — one store fetch covers both the
            // message count for context assembly and the structured
            // messages for enqueueAsync. By the time we get here, the
            // user message we just inserted is in the store
            // (insertMessage awaited above).
            let history: [ChatMessageRecord]
            do {
                history = try await persistence.fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            await runGenerationTurn(
                sessionID: sessionID,
                userPrompt: text,
                history: history,
                config: config,
                handle: handle
            )
        }

        return handle
    }

    // MARK: Regenerate flow

    func runRegenerateFlow(
        sessionID: UUID,
        config: TurnConfig
    ) async throws -> ConversationStreamHandle {
        let handle = ConversationStreamHandle()

        // Fetch history synchronously so we can locate and delete the last
        // assistant message before returning the handle. Callers observe
        // ordering: `.messageRemoved` fires before `processTurn` returns.
        let history: [ChatMessageRecord]
        do {
            history = try await persistence.fetchMessages(sessionID: sessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        guard let lastAssistant = history.last(where: { $0.role == .assistant }) else {
            throw ConversationError.noAssistantMessageToRegenerate
        }

        do {
            try await persistence.deleteMessage(lastAssistant.id)
        } catch {
            throw ConversationError.persistence(error)
        }
        emit(.messageRemoved(messageID: lastAssistant.id))

        Task.detached { [self] in
            // Fetch history after deletion — the removed assistant message
            // is gone, so context assembly starts from the last user turn.
            let postHistory: [ChatMessageRecord]
            do {
                postHistory = try await persistence.fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            await runGenerationTurn(
                sessionID: sessionID,
                userPrompt: nil,
                history: postHistory,
                config: config,
                handle: handle
            )
        }

        return handle
    }

    // MARK: Edit flow

    func runEditFlow(
        sessionID: UUID,
        messageID: UUID,
        text: String,
        config: TurnConfig
    ) async throws -> ConversationStreamHandle? {
        // Fetch history synchronously so we can locate the target message
        // and delete trailing messages before returning. Callers observe
        // ordering: `.messageUpdated` and `.messageRemoved` events fire
        // before `processTurn` returns so adapters can update their view-
        // state before the stream starts.
        let history: [ChatMessageRecord]
        do {
            history = try await persistence.fetchMessages(sessionID: sessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        guard let index = history.firstIndex(where: { $0.id == messageID }) else {
            throw ConversationError.messageNotFound(messageID)
        }

        // Update the edited message's content in the store.
        var updatedMessage = history[index]
        updatedMessage.content = text
        do {
            try await persistence.updateMessage(updatedMessage)
        } catch {
            throw ConversationError.persistence(error)
        }
        emit(.messageUpdated(updatedMessage))

        // Delete all messages after the edited one. On first failure stop
        // deleting and throw — callers reload from the store on failure;
        // the partial deletion is acknowledged, matching ChatViewModel's
        // behaviour.
        let trailing = Array(history[(index + 1)...])
        for msg in trailing {
            do {
                try await persistence.deleteMessage(msg.id)
            } catch {
                throw ConversationError.persistence(error)
            }
            emit(.messageRemoved(messageID: msg.id))
        }

        // If the edited message was from the user, regenerate. Assistant
        // edits persist the change but do not re-run generation.
        guard updatedMessage.role == .user else {
            return nil
        }

        let handle = ConversationStreamHandle()
        Task.detached { [self] in
            // Fetch history fresh after the synchronous edit + deletion —
            // the updated message and removed trailing messages are
            // already committed to the store before the detached task
            // runs.
            let postHistory: [ChatMessageRecord]
            do {
                postHistory = try await persistence.fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            await runGenerationTurn(
                sessionID: sessionID,
                userPrompt: nil,
                history: postHistory,
                config: config,
                handle: handle
            )
        }
        return handle
    }

    // MARK: Branch flow

    func runBranchFlow(
        sourceSessionID: UUID,
        branchMessageID: UUID,
        newSessionID: UUID,
        newSessionTitle: String?,
        generateAfter: Bool,
        config: TurnConfig
    ) async throws -> ConversationStreamHandle? {
        // Fetch source history synchronously so callers observe ordering:
        // `.sessionBranched` fires before `processTurn` returns.
        let sourceHistory: [ChatMessageRecord]
        do {
            sourceHistory = try await persistence.fetchMessages(sessionID: sourceSessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        // Find the branch point and slice history up to and including it.
        guard let branchIndex = sourceHistory.firstIndex(where: { $0.id == branchMessageID }) else {
            throw ConversationError.messageNotFound(branchMessageID)
        }
        let slice = Array(sourceHistory[...branchIndex])

        // Derive the new session's title from the source session when the
        // caller didn't supply one. A title-fetch failure must not abort
        // the branch — the session insert below still runs with the
        // fallback — but the failure is logged so it isn't silently lost.
        let resolvedTitle: String
        if let supplied = newSessionTitle {
            resolvedTitle = supplied
        } else {
            resolvedTitle = await persistence.sessionTitle(sessionID: sourceSessionID, fallback: "New Chat")
        }

        let newSession = ChatSessionRecord(id: newSessionID, title: resolvedTitle)
        do {
            try await persistence.insertSession(newSession)
        } catch {
            throw ConversationError.persistence(error)
        }

        // Copy messages into the new session with fresh IDs and updated
        // sessionID.
        for original in slice {
            let copy = ChatMessageRecord(
                role: original.role,
                contentParts: original.contentParts,
                timestamp: original.timestamp,
                sessionID: newSessionID
            )
            do {
                try await persistence.insertMessage(copy)
            } catch {
                throw ConversationError.persistence(error)
            }
        }

        emit(.sessionBranched(newSessionID: newSessionID, copiedCount: slice.count))

        // Optionally trigger generation on the new session.
        guard generateAfter, slice.last?.role == .user else {
            return nil
        }

        let handle = ConversationStreamHandle()
        // BranchInput historically pinned the streaming/loop knobs to
        // hard-coded defaults regardless of caller config (see legacy
        // BranchInput, which only carried sampling knobs). Preserve that
        // by overriding those four fields when running the branch flow,
        // even though TurnConfig now carries them. If callers want
        // configurable streaming for branched generation, that's a
        // follow-up tuning knob.
        let branchConfig = TurnConfig(
            systemPrompt: config.systemPrompt,
            temperature: config.temperature,
            topP: config.topP,
            repeatPenalty: config.repeatPenalty,
            maxOutputTokens: config.maxOutputTokens,
            maxThinkingTokens: config.maxThinkingTokens,
            streamingUpdateInterval: .milliseconds(33),
            streamingBatchCharacterLimit: 128,
            thinkingStreamingUpdateInterval: .milliseconds(33),
            thinkingStreamingBatchCharacterLimit: 128,
            loopDetectionEnabled: true
        )
        Task.detached { [self] in
            // Re-fetch from the new session so the history reflects the
            // persisted copies with their new IDs and sessionID.
            let history: [ChatMessageRecord]
            do {
                history = try await persistence.fetchMessages(sessionID: newSessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            await runGenerationTurn(
                sessionID: newSessionID,
                userPrompt: nil,
                history: history,
                config: branchConfig,
                handle: handle
            )
        }
        return handle
    }

    // MARK: Shared generation inner loop
    //
    // All four turn flows (send, regenerate, edit, branch) converge here
    // after their respective setup steps. The caller is responsible for
    // fetching a clean `history` slice; this method owns context assembly →
    // enqueue → drain → finalise.

    private func runGenerationTurn(
        sessionID: UUID,
        userPrompt: String?,
        history: [ChatMessageRecord],
        config: TurnConfig,
        handle: ConversationStreamHandle
    ) async {
        let messageCount = history.count

        // Context assembly hook. Always emit `.beforeContextAssembly` and
        // `.contextAssembled` so adapters that pin against these events
        // see them on every turn — even when no providers are registered
        // (slots = []). Stable event ordering matters more than skipping
        // a no-op emission.
        let request = PromptContextRequest(
            sessionID: sessionID,
            messageCount: messageCount,
            userInput: userPrompt
        )
        emit(.beforeContextAssembly(prompt: userPrompt, request: request))

        var slots: [PromptSlot]
        if let pipeline {
            do {
                slots = try await pipeline.assemble(messageCount: messageCount)
            } catch {
                emit(.errorRaised(.contextAssembly(error)))
                return
            }
        } else {
            slots = []
        }

        if let ragService, let userPrompt {
            do {
                let ragSlots = try await ragService.retrieveSlots(query: userPrompt)
                slots.append(contentsOf: ragSlots)
            } catch {
                Log.inference.warning("ConversationRuntime: RAG retrieval failed, continuing without retrieved context: \(error.localizedDescription)")
            }
        }

        emit(.contextAssembled(slots: slots))

        // Build the assistant message slot up front so token deltas can
        // reference its id from the first emitted token.
        var assistantMessage = ChatMessageRecord(
            role: .assistant,
            content: "",
            sessionID: sessionID
        )
        let assistantID = assistantMessage.id

        let composedSystemPrompt = composeSystemPrompt(config.systemPrompt, slots: slots)

        let structuredHistory: [StructuredMessage] = history.map { record in
            StructuredMessage(role: record.role.rawValue, parts: record.contentParts)
        }

        // Forward the registered tool surface so the backend's GenerationConfig
        // gets `tools = registry.advertisedDefinitions` (legacy parity with
        // GenerationQueue.enqueueGeneration). `advertisedDefinitions`
        // already honours `advertisedToolNames` filtering — registering a
        // tool but limiting which names go on the wire works without
        // unregistering the executor. Fetched on the main actor because the
        // registry and InferenceService accessors are both MainActor-isolated.
        let advertisedTools: [ToolDefinition] = await readAdvertisedToolDefinitions()

        let token: InferenceService.GenerationRequestToken
        let stream: GenerationStream
        do {
            (token, stream) = try await inferenceService.enqueueAsync(
                structuredMessages: structuredHistory,
                systemPrompt: composedSystemPrompt,
                temperature: config.temperature,
                topP: config.topP,
                repeatPenalty: config.repeatPenalty,
                maxOutputTokens: config.maxOutputTokens,
                maxThinkingTokens: config.maxThinkingTokens,
                tools: advertisedTools,
                priority: .userInitiated,
                sessionID: sessionID
            )
        } catch {
            emit(.errorRaised(.inference(error)))
            return
        }

        await registry.register(handle: handle, token: token)

        // If cancel(_:) raced ahead of register — i.e., the caller cancelled
        // between the command returning and this point — the markCancelled
        // call returned nil (nothing to cancel at that time). Issue
        // cancelAsync now so backend work doesn't continue running while
        // the runtime has stopped consuming the stream.
        if await registry.isCancelled(handle) {
            await inferenceService.cancelAsync(token)
        }

        emit(.streamStarted(messageID: assistantID))

        // Drain the stream, mirroring GenerationQueue's four features:
        //   (a) token batcher — coalesce per-token events into UI-cadenced batches
        //   (b) thinking-block disclosure — track/batch reasoning tokens and emit
        //       thinkingStarted / thinkingUpdated / thinkingFinalized events
        //   (c) tool dispatch — persist toolCall + toolResult content parts and
        //       emit toolCallRequested / toolCallCompleted events
        //   (d) loop detection — stop the stream when RepetitionDetector fires
        var accumulated = ""
        var emptyResponse = true
        var streamFailed: ConversationError?
        var tokenUsage: (promptTokens: Int, completionTokens: Int)?

        var consumer = GenerationStreamConsumer(loopDetectionEnabled: config.loopDetectionEnabled)
        var batcher = StreamingTokenBatcher(
            interval: config.streamingUpdateInterval,
            maxBufferedCharacters: config.streamingBatchCharacterLimit
        )
        var thinkingBatcher = StreamingTokenBatcher(
            interval: config.thinkingStreamingUpdateInterval,
            maxBufferedCharacters: config.thinkingStreamingBatchCharacterLimit
        )
        var thinkingAccumulator = ""
        var thinkingDisplayed = ""
        var pendingThinkingSignature: String?

        do {
            eventLoop: for try await event in stream.events {
                let cancelled = await isCancelled(handle: handle)
                if cancelled { break }

                switch consumer.handle(event) {
                case .appendText(let text):
                    emptyResponse = false
                    if let batch = batcher.append(text, now: ContinuousClock.now) {
                        accumulated += batch
                        emit(.tokenEmitted(messageID: assistantID, delta: batch))
                        if consumer.shouldStopForLoop(content: accumulated) {
                            await inferenceService.cancelAsync(token)
                            emit(.loopDetected(messageID: assistantID))
                            break eventLoop
                        }
                    }

                case .appendThinkingText(let text):
                    let isFirst = thinkingAccumulator.isEmpty
                    thinkingAccumulator += text
                    if isFirst {
                        emit(.thinkingStarted(messageID: assistantID))
                    }
                    if let batch = thinkingBatcher.append(text, now: ContinuousClock.now) {
                        thinkingDisplayed += batch
                        emit(.thinkingUpdated(messageID: assistantID, partialText: thinkingDisplayed))
                        if consumer.shouldStopForLoop(content: thinkingAccumulator) {
                            await inferenceService.cancelAsync(token)
                            emit(.loopDetected(messageID: assistantID))
                            break eventLoop
                        }
                    }

                case .recordThinkingSignature(let signature):
                    pendingThinkingSignature = signature

                case .finalizeThinking:
                    if let batch = thinkingBatcher.flush(now: ContinuousClock.now) {
                        thinkingDisplayed += batch
                    }
                    let block = thinkingAccumulator
                    let signature = pendingThinkingSignature
                    thinkingAccumulator = ""
                    thinkingDisplayed = ""
                    pendingThinkingSignature = nil
                    guard !block.isEmpty else { break }
                    emit(.thinkingFinalized(messageID: assistantID, text: block, signature: signature))

                case .dispatchToolCall(let call):
                    emit(.toolCallRequested(call))

                case .appendToolResult(let result):
                    emit(.toolCallCompleted(result.callId, result))

                case .toolLoopLimitReached(let iterations):
                    emit(.errorRaised(.inference(
                        InferenceError.inferenceFailure("Tool-call loop stopped after \(iterations) iterations.")
                    )))

                case .recordUsage(let prompt, let completion):
                    tokenUsage = (prompt, completion)

                case .ignore:
                    break
                }
            }
        } catch {
            // Map CancellationError to `.cancelled` even when the registry has
            // not yet observed `markCancelled` for this handle. `stopGeneration`
            // schedules `runtime.cancel(_:)` on a separate Task, which can race
            // the backend's CancellationError back here ahead of the registry
            // flip; without this guard the adapter surfaces an error UI for a
            // user-initiated cancel.
            let cancelled = await isCancelled(handle: handle) || error is CancellationError
            if cancelled {
                streamFailed = .cancelled
            } else {
                streamFailed = .inference(error)
            }
        }

        // Flush remaining buffered tokens (normal end, error, or cancellation).
        if let batch = batcher.flush(now: ContinuousClock.now) {
            accumulated += batch
            emit(.tokenEmitted(messageID: assistantID, delta: batch))
        }

        // Finalize an unclosed thinking block — the model may not emit a closing
        // event if generation is cut short.
        if !thinkingAccumulator.isEmpty {
            _ = thinkingBatcher.flush(now: ContinuousClock.now)
            let block = thinkingAccumulator
            let signature = pendingThinkingSignature
            thinkingAccumulator = ""
            pendingThinkingSignature = nil
            emit(.thinkingFinalized(messageID: assistantID, text: block, signature: signature))
        }

        // Finalise the assistant message. If the stream produced no visible
        // content and was not cancelled, drop it — matches the
        // `ChatViewModel`/`GenerationQueue` rule that keeps the
        // transcript clean of empty turns.
        //
        // Unregister before emitting terminal events so that any cancel(_:)
        // called after this point is a documented no-op rather than a
        // late-cancel that could still mark the handle cancelled and confuse
        // observers.
        let cancelled = await isCancelled(handle: handle)
        await registry.unregister(handle: handle)

        // Capture token usage off the active backend before any subsequent
        // turn can overwrite it. The legacy `GenerationQueue` set this
        // on the assistant `ChatMessage` immediately after the stream ended;
        // the runtime path needs the same per-turn pinning so back-to-back
        // sends do not cross-contaminate prompt/completion counts. Read on
        // the main actor — `InferenceService.lastTokenUsage` is MainActor-
        // isolated.
        let usage: (promptTokens: Int, completionTokens: Int)?
        if let tokenUsage {
            usage = tokenUsage
        } else {
            usage = await readLastTokenUsage()
        }
        if let usage {
            assistantMessage.promptTokens = usage.promptTokens
            assistantMessage.completionTokens = usage.completionTokens
            emit(.tokenUsageRecorded(
                messageID: assistantID,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens
            ))
        }

        let reason: FinishReason
        if cancelled {
            reason = .cancelled
        } else if let streamFailed {
            // An inference error during streaming. Persist whatever we have
            // (parity with ChatViewModel.stopGeneration's partial-save
            // behaviour) and emit error. We do not collapse this into
            // `.streamFinished(reason: .empty)` because consumers need to
            // know the run failed.
            assistantMessage.content = accumulated
            if !accumulated.isEmpty {
                do {
                    try await persistence.insertMessage(assistantMessage)
                    emit(.messageInserted(assistantMessage))
                } catch {
                    emit(.errorRaised(.persistence(error)))
                    emit(.errorRaised(streamFailed))
                    emit(.streamFinished(messageID: assistantID, reason: .stop))
                    return
                }
            }
            emit(.errorRaised(streamFailed))
            emit(.streamFinished(messageID: assistantID, reason: .stop))
            return
        } else if emptyResponse {
            reason = .empty
        } else {
            reason = .stop
        }

        if cancelled {
            // On cancel, persist whatever streamed in so far if non-empty —
            // matches ChatViewModel.stopGeneration's behaviour.
            if !accumulated.isEmpty {
                assistantMessage.content = accumulated
                do {
                    try await persistence.insertMessage(assistantMessage)
                    emit(.messageInserted(assistantMessage))
                } catch {
                    emit(.errorRaised(.persistence(error)))
                    // Fall through and still emit streamFinished — the
                    // cancellation outcome is the load-bearing signal here.
                }
            }
            emit(.streamFinished(messageID: assistantID, reason: reason))
            return
        }

        if reason == .empty {
            // Drop the empty assistant message. No persistence happens; we
            // emit the terminal events and return.
            //
            // Issue #965: a switch-cancel-resend race used to silently drop
            // the resent turn here. The fix lives in
            // `GenerationQueue.discardRequests(notMatching:)`, but a stream
            // may still legitimately reach this branch (e.g. backend yields
            // zero tokens for a malformed prompt). Log a warning with backend
            // + sessionID so a future regression is observable instead of
            // silent. Semantics are unchanged — this branch still drops.
            let backendName = await readActiveBackendName()
            Log.inference.warning(
                "ConversationRuntime: dropping empty assistant turn (sessionID=\(sessionID, privacy: .private), backend=\(backendName ?? "nil", privacy: .public))"
            )
            emptyResponseObserver?(ConversationRuntime.EmptyResponseDiagnostic(sessionID: sessionID, backendName: backendName))
            emit(.streamFinished(messageID: assistantID, reason: reason))
            emit(.afterGeneration(messageID: assistantID, finalText: ""))
            return
        }

        // Happy path: persist the assistant message.
        assistantMessage.content = accumulated
        do {
            try await persistence.insertMessage(assistantMessage)
            emit(.messageInserted(assistantMessage))
        } catch {
            emit(.errorRaised(.persistence(error)))
            emit(.streamFinished(messageID: assistantID, reason: reason))
            return
        }

        emit(.streamFinished(messageID: assistantID, reason: reason))
        emit(.afterGeneration(messageID: assistantID, finalText: accumulated))

        // Touch session timestamp so the sidebar reflects the assistant
        // turn's recency (parity with ChatViewModel's behaviour).
        if await persistence.touchSession(sessionID: sessionID) == false {
            emit(.sessionTouchFailed(sessionID: sessionID))
        }
    }


    // MARK: Helpers

    private func emit(_ event: ConversationEvent) {
        eventSink(event)
    }

    private func isCancelled(handle: ConversationStreamHandle) async -> Bool {
        if Task.isCancelled { return true }
        return await registry.isCancelled(handle)
    }

    @MainActor
    private func readAdvertisedToolDefinitions() async -> [ToolDefinition] {
        guard let registry = inferenceService.toolRegistry else { return [] }
        return registry.advertisedDefinitions
    }

    @MainActor
    private func readLastTokenUsage() async -> (promptTokens: Int, completionTokens: Int)? {
        inferenceService.lastTokenUsage
    }

    @MainActor
    private func readActiveBackendName() async -> String? {
        inferenceService.activeBackendName
    }

    private func composeSystemPrompt(_ base: String?, slots: [PromptSlot]) -> String? {
        let slotText = slots
            .filter { $0.isEnabled }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        switch (base, slotText.isEmpty) {
        case (nil, true): return nil
        case (nil, false): return slotText
        case (let base?, true): return base.isEmpty ? nil : base
        case (let base?, false):
            return base.isEmpty ? slotText : "\(base)\n\n\(slotText)"
        }
    }
}
