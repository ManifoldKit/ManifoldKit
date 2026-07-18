import Foundation
import ManifoldInference

package struct ConversationTurnExecutor: Sendable {
    private let persistence: ConversationPersistencePort
    /// Narrow view of `persistence` used by the shared generation inner loop.
    /// See ``TurnPersistencePort`` — flow-specific setup (send/regenerate/edit/
    /// branch) keeps reading `persistence` directly since it needs the
    /// broader surface (message-batch mutations, session create/copy).
    private var turnPersistence: any TurnPersistencePort { persistence }
    private let inferenceService: InferenceService
    /// Typed per-turn event seam. Wraps the host's `@Sendable` sink; the private
    /// `emit` helper forwards through it. See ``TurnEventEmitter``.
    private let events: TurnEventEmitter
    /// Pre-turn / post-turn compress-and-replace seam. Owns both compression
    /// policies and the shared summarisation generate closure. See
    /// ``TurnCompressionCoordinator`` for the ordering contract the
    /// characterization goldens pin.
    private let compression: TurnCompressionCoordinator
    /// Per-turn session-tool advertise/register/unregister seam. See
    /// ``SessionToolDispatchBinder`` and #1606 (register-before-enqueue).
    private let toolDispatch: SessionToolDispatchBinder
    /// Session-branching persistence mechanics (new-session creation,
    /// transactional message copy, orphaned-session rollback). See
    /// ``SessionBranchCoordinator`` — ``runBranchFlow`` keeps event emission
    /// and the generate-after decision, the turn-loop-shared concerns.
    private let sessionBranching: SessionBranchCoordinator
    /// History + context assembly + RAG + system prompt + tool wiring.
    /// See ``TurnPreparation`` (#1957 Priority 3).
    private let preparation: TurnPreparation
    /// Stream drain + single parameterized finalization path.
    /// See ``TurnStreamFinalizer`` (#1957 Priority 3).
    private let finalizer: TurnStreamFinalizer
    private let registry: InFlightStreamRegistry
    private let generationHooks: [any GenerationHook]

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
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil,
        hookTimeout: Duration = .seconds(30),
        historyShaper: (any HistoryShaper)? = nil,
        historyProviders: [any HistoryProvider] = [],
        hostTurnContextProvider: (any HostTurnContextProvider)? = nil,
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil,
        bindings: RuntimeBindingsBox
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.registry = registry
        let events = TurnEventEmitter(emit)
        self.events = events
        self.generationHooks = generationHooks
        self.compression = TurnCompressionCoordinator(
            persistence: persistence,
            inferenceService: inferenceService,
            events: events,
            preTurnPolicy: preTurnCompressionPolicy,
            postTurnPolicy: compressionPolicy
        )
        let toolDispatch = SessionToolDispatchBinder(inferenceService: inferenceService)
        self.toolDispatch = toolDispatch
        self.sessionBranching = SessionBranchCoordinator(persistence: persistence)
        let historyAssembler = HistoryAssembler(providers: historyProviders)
        self.preparation = TurnPreparation(
            persistence: persistence,
            inferenceService: inferenceService,
            pipeline: pipeline,
            budgetPlanner: budgetPlanner,
            ragService: ragService,
            events: events,
            historyShaper: historyShaper,
            historyAssembler: historyAssembler,
            hostTurnContextProvider: hostTurnContextProvider,
            legacyTurnContextProvider: turnContextProvider,
            bindings: bindings,
            toolDispatch: toolDispatch
        )
        self.finalizer = TurnStreamFinalizer(
            persistence: persistence,
            inferenceService: inferenceService,
            registry: registry,
            events: events,
            emptyResponseObserver: emptyResponseObserver,
            generationHooks: generationHooks,
            compression: self.compression,
            usageStore: usageStore,
            hookTimeout: hookTimeout,
            toolDispatch: toolDispatch
        )
    }

    // MARK: Send flow

    package func runSendFlow(
        sessionID: UUID,
        text: String,
        attachments rawAttachments: [MessagePart],
        config: TurnConfig,
        taskRegistry: ConversationTurnTaskRegistry,
        outcomeCompletion: ConversationTurnOutcomeCompletion? = nil
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

        // Pre-turn compression: runs before the user message is appended so
        // the just-submitted action always falls outside the compressed
        // segment. Only runs for `.send` turns (not regenerate / edit / branch).
        // Failures throw to the caller — see ``TurnCompressionCoordinator``.
        //
        // Budget against the base wire prompt the turn will use (TurnConfig /
        // active agent + handoff instructions). Prompt slots / RAG are not
        // assembled yet at this seam — post-turn compression gets the full
        // composed prompt. See ``TurnCompressionCoordinator`` + #1957.
        //
        // userMessage is created AFTER this call so its timestamp naturally
        // follows the compression summary records in store sort order.
        let sessionRecordForPreTurn = await turnPersistence.fetchSession(sessionID: sessionID)
        let preTurnWirePrompt = TurnPreparation.resolveBaseSystemPrompt(
            sessionRecord: sessionRecordForPreTurn,
            config: config
        )
        try await compression.compressBeforeTurnIfNeeded(
            sessionID: sessionID,
            wireSystemPrompt: .wire(preTurnWirePrompt)
        )

        let userMessage = ChatMessage(
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

        // Launch the streaming work through the runtime-owned task registry
        // so cancellation and completion bookkeeping have one owner.
        await launchGenerationTask(
            sessionID: sessionID,
            turnKind: .send(text: text, attachments: attachments),
            userPrompt: text,
            config: config,
            handle: handle,
            taskRegistry: taskRegistry,
            firesPreTurnHooks: true,
            outcomeCompletion: outcomeCompletion
        )

        return handle
    }

    // MARK: Regenerate flow

    package func runRegenerateFlow(
        sessionID: UUID,
        config: TurnConfig,
        taskRegistry: ConversationTurnTaskRegistry,
        outcomeCompletion: ConversationTurnOutcomeCompletion? = nil
    ) async throws -> ConversationStreamHandle {
        let handle = ConversationStreamHandle()

        // Fetch history synchronously so we can locate and delete the last
        // assistant message before returning the handle. Callers observe
        // ordering: `.messageRemoved` fires before `processTurn` returns.
        let history: [ChatMessage]
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

        await launchGenerationTask(
            sessionID: sessionID,
            turnKind: .regenerate,
            userPrompt: nil,
            config: config,
            handle: handle,
            taskRegistry: taskRegistry,
            firesPreTurnHooks: true,
            outcomeCompletion: outcomeCompletion
        )

        return handle
    }

    // MARK: Edit flow

    package func runEditFlow(
        sessionID: UUID,
        messageID: UUID,
        text: String,
        config: TurnConfig,
        taskRegistry: ConversationTurnTaskRegistry,
        outcomeCompletion: ConversationTurnOutcomeCompletion? = nil
    ) async throws -> ConversationStreamHandle? {
        // Fetch history synchronously so we can locate the target message
        // and delete trailing messages before returning. Callers observe
        // ordering: `.messageUpdated` and `.messageRemoved` events fire
        // before `processTurn` returns so adapters can update their view-
        // state before the stream starts.
        let history: [ChatMessage]
        do {
            history = try await persistence.fetchMessages(sessionID: sessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        guard let index = history.firstIndex(where: { $0.id == messageID }) else {
            throw ConversationError.messageNotFound(messageID)
        }

        // Apply the edit plus any trailing deletions as one logical batch.
        // Transactional stores commit atomically; non-transactional stores fall
        // back to sequential writes, but observers still must not see any
        // `.messageUpdated` / `.messageRemoved` events unless the whole batch
        // completes successfully.
        var updatedMessage = history[index]
        updatedMessage.replaceTextContent(text)
        let trailing = Array(history[(index + 1)...])

        var mutations: [MessageStoreMutation] = [.update(updatedMessage)]
        mutations.append(contentsOf: trailing.map { .delete($0.id) })
        do {
            try await persistence.performMessageMutations(mutations)
        } catch {
            throw ConversationError.persistence(error)
        }

        emit(.messageUpdated(updatedMessage))
        for msg in trailing {
            emit(.messageRemoved(messageID: msg.id))
        }

        // If the edited message was from the user, regenerate. Assistant
        // edits persist the change but do not re-run generation.
        guard updatedMessage.role == .user else {
            return nil
        }

        let handle = ConversationStreamHandle()
        await launchGenerationTask(
            sessionID: sessionID,
            turnKind: .edit(messageID: messageID, text: text),
            userPrompt: nil,
            config: config,
            handle: handle,
            taskRegistry: taskRegistry,
            firesPreTurnHooks: true,
            outcomeCompletion: outcomeCompletion
        )
        return handle
    }

    // MARK: Branch flow

    package func runBranchFlow(
        sourceSessionID: UUID,
        branchMessageID: UUID,
        newSessionID: UUID,
        newSessionTitle: String?,
        generateAfter: Bool,
        config: TurnConfig,
        taskRegistry: ConversationTurnTaskRegistry,
        outcomeCompletion: ConversationTurnOutcomeCompletion? = nil
    ) async throws -> ConversationStreamHandle? {
        // Delegate the branch-specific persistence mechanics (locate branch
        // point, create new session, transactional message copy with
        // orphan-session rollback on failure) to the dedicated coordinator —
        // see ``SessionBranchCoordinator``. `.sessionBranched` fires here,
        // before `processTurn` returns, matching the ordering callers observe.
        let result = try await sessionBranching.branch(
            sourceSessionID: sourceSessionID,
            branchMessageID: branchMessageID,
            newSessionID: newSessionID,
            newSessionTitle: newSessionTitle
        )

        emit(.sessionBranched(newSessionID: newSessionID, copiedCount: result.copiedCount))

        // Optionally trigger generation on the new session.
        guard generateAfter, result.lastMessageIsFromUser else {
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
            generation: config.generation,
            maxOutputTokens: config.maxOutputTokens,
            maxThinkingTokens: config.maxThinkingTokens,
            streamingUpdateInterval: .milliseconds(33),
            streamingBatchCharacterLimit: 128,
            thinkingStreamingUpdateInterval: .milliseconds(33),
            thinkingStreamingBatchCharacterLimit: 128,
            loopDetectionEnabled: true,
            // Carry the caller's stall-timeout and repetition tuning through
            // the branch flow — only the streaming cadence knobs are pinned to
            // legacy BranchInput defaults above; these two are turn-behaviour
            // policy the caller owns.
            progressStallTimeout: config.progressStallTimeout,
            repetitionGuard: config.repetitionGuard
        )
        // Branch historically does NOT fire `willBeginTurn` pre-turn hooks —
        // the legacy BranchInput path never did. Preserved as-is.
        await launchGenerationTask(
            sessionID: newSessionID,
            turnKind: .branch(
                messageID: branchMessageID,
                newSessionID: newSessionID,
                newSessionTitle: newSessionTitle,
                generateAfter: generateAfter
            ),
            userPrompt: nil,
            config: branchConfig,
            handle: handle,
            taskRegistry: taskRegistry,
            firesPreTurnHooks: false,
            outcomeCompletion: outcomeCompletion
        )
        return handle
    }

    /// Shared launch shape for all four turn flows: pre-turn hook fan-out,
    /// history fetch/shape/assemble, then the generation inner loop — all on
    /// the runtime-owned task registry so cancellation and completion
    /// bookkeeping have one owner. `firesPreTurnHooks` is `false` only for
    /// the branch flow (legacy parity: BranchInput never fired them).
    private func launchGenerationTask(
        sessionID: UUID,
        turnKind: TurnKind,
        userPrompt: String?,
        config: TurnConfig,
        handle: ConversationStreamHandle,
        taskRegistry: ConversationTurnTaskRegistry,
        firesPreTurnHooks: Bool,
        outcomeCompletion: ConversationTurnOutcomeCompletion?
    ) async {
        await taskRegistry.launch(handle: handle) { [self] in
            if firesPreTurnHooks {
                // Fire pre-turn hooks so consumers can cancel in-flight work from prior turns.
                for hook in generationHooks {
                    await hook.willBeginTurn(sessionID: sessionID)
                }
            }
            let preparedHistory: PreparedTurnHistory
            do {
                preparedHistory = try await preparation.prepareHistory(
                    sessionID: sessionID,
                    turnKind: turnKind,
                    userPrompt: userPrompt
                )
            } catch {
                await failPreparedTurn(
                    error,
                    sessionID: sessionID,
                    handle: handle,
                    outcomeCompletion: outcomeCompletion
                )
                return
            }
            await runGenerationTurn(
                sessionID: sessionID,
                userPrompt: userPrompt,
                preparedHistory: preparedHistory,
                config: config,
                handle: handle,
                outcomeCompletion: outcomeCompletion
            )
        }
    }

    // MARK: Shared generation inner loop
    //
    // All four turn flows (send, regenerate, edit, branch) converge here
    // after their respective setup steps. Glue only: prepare → enqueue →
    // finalize. See ``TurnPreparation`` and ``TurnStreamFinalizer``.

    private func runGenerationTurn(
        sessionID: UUID,
        userPrompt: String?,
        preparedHistory: PreparedTurnHistory,
        config: TurnConfig,
        handle: ConversationStreamHandle,
        outcomeCompletion: ConversationTurnOutcomeCompletion? = nil
    ) async {
        let prepared: TurnPreparation.PreparedTurn
        do {
            prepared = try await preparation.prepareGeneration(
                sessionID: sessionID,
                userPrompt: userPrompt,
                preparedHistory: preparedHistory,
                config: config
            )
        } catch {
            let conversationError: ConversationError
            if let failure = error as? TurnPreparation.GenerationFailure {
                switch failure {
                case .contextAssembly(let underlying):
                    conversationError = .contextAssembly(underlying)
                }
            } else {
                conversationError = .contextAssembly(error)
            }
            emit(.errorRaised(conversationError))
            await completeOutcome(
                outcomeCompletion,
                sessionID: sessionID,
                handle: handle,
                error: conversationError
            )
            return
        }

        let assistantID = prepared.assistantMessage.id
        let token: InferenceService.GenerationRequestToken
        let stream: GenerationStream
        do {
            // `enqueueAsync` takes its sampler knobs as individual parameters
            // rather than a `GenerationConfig`, so only temperature/topP/
            // repeatPenalty thread through here; the rest of
            // `config.generation` (topK, seed, grammar, …) is not yet wired
            // on this path — same limitation as before TurnConfig composed
            // GenerationConfig, just now sourced from one place instead of
            // three duplicated fields.
            //
            // Per-request handoffDetector / preToolUseHook close the
            // service-global race (#1494); preparation also installed them
            // on the service for any legacy queue-level reader.
            (token, stream) = try await inferenceService.enqueueAsync(
                structuredMessages: prepared.structuredHistory,
                systemPrompt: prepared.composedSystemPrompt,
                temperature: config.generation.temperature,
                topP: config.generation.topP,
                repeatPenalty: config.generation.repeatPenalty,
                maxOutputTokens: config.maxOutputTokens,
                maxThinkingTokens: config.maxThinkingTokens,
                tools: prepared.advertisedTools,
                priority: .userInitiated,
                requestGroupID: sessionID,
                handoffDetector: prepared.handoffDetector,
                preToolUseHook: prepared.preToolUseHook,
                documents: prepared.ragDocuments
            )
        } catch {
            await toolDispatch.unregisterSessionToolExecutors(prepared.registeredSessionToolNames)
            let conversationError = ConversationError.inference(error)
            emit(.errorRaised(conversationError))
            await completeOutcome(
                outcomeCompletion,
                sessionID: sessionID,
                handle: handle,
                assistantMessageID: assistantID,
                error: conversationError
            )
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

        await finalizer.run(
            sessionID: sessionID,
            prepared: prepared,
            token: token,
            stream: stream,
            config: config,
            handle: handle,
            outcomeCompletion: outcomeCompletion
        )
    }

    // MARK: Helpers

    private func emit(_ event: ConversationEvent) {
        events.emit(event)
    }

    private func completeOutcome(
        _ completion: ConversationTurnOutcomeCompletion?,
        sessionID: UUID,
        handle: ConversationStreamHandle,
        assistantMessageID: UUID? = nil,
        assistantMessage: ChatMessage? = nil,
        reason: FinishReason = .stop,
        error: ConversationError? = nil,
        finalText: String = "",
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) async {
        guard let completion else { return }
        await completion.complete(ConversationTurnOutcome(
            sessionID: sessionID,
            streamHandle: handle,
            assistantMessageID: assistantMessageID,
            assistantMessage: assistantMessage,
            reason: reason,
            error: error,
            finalText: finalText,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        ))
    }

    private func failPreparedTurn(
        _ error: Error,
        sessionID: UUID,
        handle: ConversationStreamHandle,
        outcomeCompletion: ConversationTurnOutcomeCompletion?
    ) async {
        let conversationError: ConversationError
        if let failure = error as? TurnPreparation.HistoryFailure {
            switch failure {
            case .persistence(let underlying):
                conversationError = .persistence(underlying)
            case .contextAssembly(let underlying):
                conversationError = .contextAssembly(underlying)
            }
        } else {
            conversationError = .contextAssembly(error)
        }
        emit(.errorRaised(conversationError))
        await completeOutcome(
            outcomeCompletion,
            sessionID: sessionID,
            handle: handle,
            error: conversationError
        )
    }
}
