import Foundation
import ManifoldInference

struct ConversationTurnExecutor: Sendable {
    private let persistence: ConversationPersistencePort
    private let inferenceService: InferenceService
    private let pipeline: PromptContextPipeline?
    private let budgetPlanner: ContextBudgetPlanner?
    private let ragService: RAGService?
    /// Best-effort usage persistence. `nil` when the host did not wire a store.
    private let usageStore: (any UsageStore)?
    private let registry: InFlightStreamRegistry
    private let eventSink: @Sendable (ConversationEvent) -> Void
    private let emptyResponseObserver: (@Sendable (ConversationRuntime.EmptyResponseDiagnostic) -> Void)?
    private let generationHooks: [any GenerationHook]
    private let compressionPolicy: (any CompressionPolicy)?
    private let hookTimeout: Duration
    private let historyAssembler: HistoryAssembler
    /// Optional provider that attaches host-app data to each turn. Called with
    /// the session UUID before context assembly; the returned value is stored on
    /// ``TurnContext/appData`` and forwarded to ``CompletedTurn/appData`` so
    /// ``GenerationHook`` implementations receive it without a side-channel.
    private let turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)?

    init(
        persistence: ConversationPersistencePort,
        inferenceService: InferenceService,
        pipeline: PromptContextPipeline?,
        budgetPlanner: ContextBudgetPlanner?,
        ragService: RAGService?,
        usageStore: (any UsageStore)?,
        registry: InFlightStreamRegistry,
        emit: @escaping @Sendable (ConversationEvent) -> Void,
        emptyResponseObserver: (@Sendable (ConversationRuntime.EmptyResponseDiagnostic) -> Void)?,
        generationHooks: [any GenerationHook] = [],
        compressionPolicy: (any CompressionPolicy)? = nil,
        hookTimeout: Duration = .seconds(30),
        historyProviders: [any HistoryProvider] = [],
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.pipeline = pipeline
        self.budgetPlanner = budgetPlanner
        self.ragService = ragService
        self.usageStore = usageStore
        self.registry = registry
        self.eventSink = emit
        self.emptyResponseObserver = emptyResponseObserver
        self.generationHooks = generationHooks
        self.compressionPolicy = compressionPolicy
        self.hookTimeout = hookTimeout
        self.historyAssembler = HistoryAssembler(providers: historyProviders)
        self.turnContextProvider = turnContextProvider
    }

    // MARK: Send flow

    func runSendFlow(
        sessionID: UUID,
        text: String,
        attachments rawAttachments: [MessagePart],
        config: TurnConfig
    ) async throws -> ConversationStreamHandle {
        let handle = ConversationStreamHandle()

        // Reject messages that exceed the configured byte limit before any
        // SwiftData work happens. A very large payload can OOM constrained
        // iOS devices during UTF-8 encoding and SwiftData serialisation;
        // rejecting here is cheaper and surfaces a typed error the caller
        // can present to the user.
        let sizeLimit = ManifoldConfiguration.shared.maxUserMessageBytes
        guard text.utf8.count <= sizeLimit else {
            throw ConversationError.messageTooLarge(limit: sizeLimit)
        }

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
            // Fire pre-turn hooks so consumers can cancel in-flight work from prior turns.
            for hook in generationHooks {
                await hook.willBeginTurn(sessionID: sessionID)
            }
            // Fetch history first — one store fetch covers both the
            // message count for context assembly and the structured
            // messages for enqueueAsync. By the time we get here, the
            // user message we just inserted is in the store
            // (insertMessage awaited above).
            var history: [ChatMessageRecord]
            do {
                history = try await persistence.fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            do {
                history = try await historyAssembler.assemble(
                    history: history,
                    context: makeTurnContext(sessionID: sessionID, history: history)
                )
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
            // Fire pre-turn hooks so consumers can cancel in-flight work from prior turns.
            for hook in generationHooks {
                await hook.willBeginTurn(sessionID: sessionID)
            }
            // Fetch history after deletion — the removed assistant message
            // is gone, so context assembly starts from the last user turn.
            var postHistory: [ChatMessageRecord]
            do {
                postHistory = try await persistence.fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            do {
                postHistory = try await historyAssembler.assemble(
                    history: postHistory,
                    context: makeTurnContext(sessionID: sessionID, history: postHistory)
                )
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
            // Fire pre-turn hooks so consumers can cancel in-flight work from prior turns.
            for hook in generationHooks {
                await hook.willBeginTurn(sessionID: sessionID)
            }
            // Fetch history fresh after the synchronous edit + deletion —
            // the updated message and removed trailing messages are
            // already committed to the store before the detached task
            // runs.
            var postHistory: [ChatMessageRecord]
            do {
                postHistory = try await persistence.fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            do {
                postHistory = try await historyAssembler.assemble(
                    history: postHistory,
                    context: makeTurnContext(sessionID: sessionID, history: postHistory)
                )
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
            var history: [ChatMessageRecord]
            do {
                history = try await persistence.fetchMessages(sessionID: newSessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            do {
                history = try await historyAssembler.assemble(
                    history: history,
                    context: makeTurnContext(sessionID: newSessionID, history: history)
                )
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

        // Build a TurnContext so budget-aware and content-matching providers
        // can inspect the conversation without each needing a separate fetch.
        // conversationText is nil on the first turn (empty history) — providers
        // must treat nil as "no text available" rather than "empty conversation".
        let conversationText: String? = history.isEmpty ? nil : {
            let joined = history
                .compactMap { record -> String? in
                    let text = record.contentParts.compactMap(\.textContent).joined(separator: " ")
                    return text.isEmpty ? nil : text
                }
                .joined(separator: " ")
                .lowercased()
            return joined.isEmpty ? nil : joined
        }()

        let turnContext = TurnContext(
            sessionID: sessionID,
            messageCount: messageCount,
            conversationText: conversationText,
            tokenizer: nil  // backends own their tokenizer; providers use HeuristicTokenizer fallback
        )

        var slots: [PromptSlot]
        if let budgetPlanner {
            // Weight-split path: ContextBudgetPlanner handles proportional
            // allocation across providers with spillover. TurnConfig has no
            // contextWindowSize today, so we pass 0 (unknown) as contextSize.
            do {
                slots = try await budgetPlanner.assemble(
                    totalBudget: Int.max,
                    contextSize: 0,
                    context: turnContext
                )
            } catch {
                emit(.errorRaised(.contextAssembly(error)))
                return
            }
        } else if let pipeline {
            do {
                slots = try await pipeline.assemble(messageCount: messageCount)
            } catch {
                emit(.errorRaised(.contextAssembly(error)))
                return
            }
        } else {
            slots = []
        }

        var ragCitations: [Citation] = []
        if let ragService, let userPrompt {
            do {
                let result = try await ragService.retrieve(query: userPrompt)
                slots.append(contentsOf: result.slots)
                ragCitations = result.citations
            } catch {
                Log.inference.warning("ConversationRuntime: RAG retrieval failed, continuing without retrieved context: \(error.localizedDescription)")
            }
        }

        emit(.contextAssembled(slots: slots))

        // Build the assistant message slot up front so token deltas can
        // reference its id from the first emitted token.
        //
        // Citations carry the provenance of any retrieved passages so the UI
        // can render a "Sources" disclosure beneath the assistant bubble.
        // `nil` when RAG didn't run for this turn (no service, no user
        // prompt, or retrieval threw).
        var assistantMessage = ChatMessageRecord(
            role: .assistant,
            content: "",
            sessionID: sessionID,
            citations: ragCitations.isEmpty ? nil : ragCitations
        )
        let assistantID = assistantMessage.id
        func writeFinalContent(_ text: String, into message: inout ChatMessageRecord) {
            message.contentParts.removeAll {
                if case .text = $0 { return true }
                return false
            }
            if !text.isEmpty {
                message.contentParts.append(.text(text))
            }
        }

        let composedSystemPrompt = composeSystemPrompt(config.systemPrompt, slots: slots)

        // kind.backendRole == nil means use record.role directly (.chat case);
        // non-chat kinds supply a fixed role. Records with isWireVisible == false
        // are filtered out before this map runs.
        let structuredHistory: [StructuredMessage] = history
            .filter { $0.kind.isWireVisible }
            .map { record in
                let role = record.kind.backendRole ?? record.role
                return StructuredMessage(role: role.rawValue, parts: record.contentParts)
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
                    assistantMessage.contentParts.append(.toolCall(call))
                    emit(.toolCallRequested(call))

                case .appendToolResult(let result):
                    assistantMessage.contentParts.append(.toolResult(result))
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

        // True when the assistant message already carries tool-related content
        // parts, even if no visible text tokens arrived. Used below so all
        // three terminal paths (error, cancellation, normal) persist tool-only
        // turns rather than silently dropping them.
        let hasToolContent = assistantMessage.contentParts.contains { part in
            if case .toolCall = part { return true }
            if case .toolResult = part { return true }
            return false
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
            writeFinalContent(accumulated, into: &assistantMessage)
            if !accumulated.isEmpty || hasToolContent {
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
        } else if emptyResponse && !hasToolContent {
            reason = .empty
        } else {
            reason = .stop
        }

        if cancelled {
            // On cancel, persist whatever streamed in so far if non-empty —
            // matches ChatViewModel.stopGeneration's behaviour.
            if !accumulated.isEmpty || hasToolContent {
                writeFinalContent(accumulated, into: &assistantMessage)
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
        writeFinalContent(accumulated, into: &assistantMessage)
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

        // Best-effort usage recording. A persistence failure here must not
        // abort the turn loop or surface an error to the user — the
        // generation has already succeeded. Log the failure so it's
        // observable in crash reporters and development builds.
        if let usageStore, let usage {
            // `activeBackendName` is the closest proxy for the model
            // identifier available without threading extra state through
            // enqueueAsync. A dedicated model-identifier accessor can be
            // added in a follow-up (#1207 TODO).
            let backendName = await readActiveBackendName()
            let record = TurnUsageRecord(
                sessionID: sessionID,
                endpointID: nil, // TODO: thread endpoint ID from InferenceService (#1207 follow-up)
                modelIdentifier: backendName ?? "unknown",
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens
            )
            do {
                try await usageStore.record(record)
            } catch {
                Log.persistence.warning(
                    "UsageStore.record failed (sessionID=\(sessionID, privacy: .private)): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Post-generation hooks: fire and await with a per-hook timeout.
        // Not called on cancel, error, or empty-response paths (those all
        // return before reaching this point).
        if !generationHooks.isEmpty {
            let completedTurn = CompletedTurn(
                sessionID: sessionID,
                assistantMessage: assistantMessage,
                promptTokens: usage?.promptTokens,
                completionTokens: usage?.completionTokens,
                appData: turnContextProvider?(sessionID)
            )
            for hook in generationHooks {
                let hookLabel = "\(type(of: hook))"
                let timeout = hookTimeout
                await withHookTimeout(timeout, label: hookLabel) {
                    await hook.postGeneration(completedTurn)
                }
            }
        }

        // Compression check: ask the policy whether the context is full enough
        // to warrant compression. Skipped when no token usage is available
        // (policy can't make a meaningful decision without promptTokens) or
        // when the backend doesn't report a context size (contextSize == 0).
        if let compressionPolicy, let promptTokens = usage?.promptTokens {
            let contextSize = await readContextWindowSize()
            let contextUtilization = contextSize > 0 ? Double(promptTokens) / Double(contextSize) : 0
            if contextSize > 0 && compressionPolicy.shouldCompress(promptTokens: promptTokens, contextSize: contextSize, contextUtilization: contextUtilization) {
                let history: [ChatMessageRecord]
                do {
                    history = try await persistence.fetchMessages(sessionID: sessionID)
                } catch {
                    Log.inference.warning("CompressionPolicy: fetchMessages failed, skipping compression: \(error.localizedDescription, privacy: .public)")
                    return
                }

                // Wrap inferenceService in a Sendable closure so the policy
                // can call the backend for summarisation without holding a
                // reference to the executor itself. Uses background priority
                // so compression doesn't compete with the user's next turn.
                let generate: @Sendable ([ChatMessageRecord]) async throws -> String = { [inferenceService] messages in
                    let structured = messages
                        .filter { $0.kind.isWireVisible }
                        .map { record -> StructuredMessage in
                            let role = record.kind.backendRole ?? record.role
                            return StructuredMessage(role: role.rawValue, parts: record.contentParts)
                        }
                    let (token, compressStream) = try await inferenceService.enqueueAsync(
                        structuredMessages: structured,
                        priority: .background
                    )
                    var result = ""
                    var consumer = GenerationStreamConsumer(loopDetectionEnabled: false)
                    do {
                        for try await event in compressStream.events {
                            // Propagate parent-task cancellation into the
                            // backend stream so we don't keep draining after
                            // the runtime has moved on.
                            try Task.checkCancellation()
                            if case .appendText(let chunk) = consumer.handle(event) {
                                result += chunk
                            }
                        }
                    } catch {
                        // Cancel the backend token on any exit (cancellation or
                        // inference error) so the backend doesn't keep running.
                        await inferenceService.cancelAsync(token)
                        throw error
                    }
                    return result
                }

                do {
                    let compressed = try await compressionPolicy.compress(
                        history: history,
                        sessionID: sessionID,
                        generate: generate
                    )
                    // Guard against an empty result — deleting all messages
                    // without re-inserting anything would silently wipe the
                    // conversation. Treat this as a policy error; preserve the
                    // existing history rather than destroying it.
                    guard !compressed.isEmpty else {
                        Log.inference.warning(
                            "CompressionPolicy.compress returned empty history (sessionID=\(sessionID, privacy: .private)); skipping replacement to preserve existing messages"
                        )
                        return
                    }
                    try await persistence.deleteMessages(for: sessionID)
                    for message in compressed {
                        try await persistence.insertMessage(message)
                    }
                    emit(.historyCompressed(sessionID: sessionID, insertedRecords: compressed))
                    await compressionPolicy.postCompress(sessionID: sessionID, insertedRecords: compressed)
                } catch {
                    Log.inference.warning("CompressionPolicy.compress failed (sessionID=\(sessionID, privacy: .private)): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }


    // MARK: Helpers

    private func emit(_ event: ConversationEvent) {
        eventSink(event)
    }

    private func makeTurnContext(sessionID: UUID, history: [ChatMessageRecord]) -> TurnContext {
        let conversationText: String? = history.isEmpty ? nil : {
            let joined = history
                .compactMap { record -> String? in
                    let text = record.contentParts.compactMap(\.textContent).joined(separator: " ")
                    return text.isEmpty ? nil : text
                }
                .joined(separator: " ")
                .lowercased()
            return joined.isEmpty ? nil : joined
        }()
        var context = TurnContext(
            sessionID: sessionID,
            messageCount: history.count,
            conversationText: conversationText,
            tokenizer: nil
        )
        context.appData = turnContextProvider?(sessionID)
        return context
    }

    /// Reads the backend's context window size from the main actor.
    /// Returns 0 when unavailable — callers treat 0 as "skip compression".
    @MainActor
    private func readContextWindowSize() async -> Int {
        inferenceService.capabilities?.contextWindowSize ?? 0
    }

    /// Runs `operation` with a timeout. If the operation doesn't finish within
    /// `duration`, the operation task is cancelled and a warning is logged.
    /// The hook receives a Task cancellation signal; it is not forcibly killed.
    private func withHookTimeout(
        _ duration: Duration,
        label: String,
        operation: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: duration)
                    Log.inference.warning(
                        "GenerationHook '\(label, privacy: .public)' timed out after \(duration, privacy: .public) and was cancelled"
                    )
                } catch {
                    // Timer was cancelled because operation finished first — no action needed.
                }
            }
            // Wait for whichever finishes first, then cancel the other.
            await group.next()
            group.cancelAll()
        }
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
