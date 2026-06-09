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
    /// Typed per-turn event seam. Wraps the host's `@Sendable` sink; the private
    /// `emit` helper forwards through it. See ``TurnEventEmitter``.
    private let events: TurnEventEmitter
    private let emptyResponseObserver: (@Sendable (ConversationRuntime.EmptyResponseDiagnostic) -> Void)?
    private let generationHooks: [any GenerationHook]
    private let compressionPolicy: (any CompressionPolicy)?
    private let preTurnCompressionPolicy: (any PreTurnCompressionPolicy)?
    private let hookTimeout: Duration
    private let historyShaper: (any HistoryShaper)?
    private let historyAssembler: HistoryAssembler
    /// Optional richer provider that attaches host-app data to each turn from a
    /// full metadata snapshot. When absent, ``legacyTurnContextProvider`` keeps
    /// the old session-ID-only seam source-compatible.
    private let hostTurnContextProvider: (any HostTurnContextProvider)?
    /// Legacy session-ID-only host appData seam. Kept for source compatibility
    /// and used only when ``hostTurnContextProvider`` is `nil`.
    private let legacyTurnContextProvider: (@Sendable (UUID) -> (any Sendable)?)?
    /// Mutable holder for `sessionToolSources` + `hookRegistry`. The executor
    /// reads a snapshot once per turn (top of the send loop) so a host call
    /// to ``ConversationRuntime/updateSessionToolSources(_:)`` /
    /// ``ConversationRuntime/updateHookRegistry(_:)`` made between turns
    /// takes effect on the next turn without rebuilding the runtime. See
    /// ``RuntimeBindingsBox`` for the rationale (host-app demo swaps per
    /// scenario card; full runtime rebuild would be overkill).
    private let bindings: RuntimeBindingsBox
    /// Per-turn session-tool advertise/register/unregister seam. See
    /// ``SessionToolDispatchBinder`` and #1606 (register-before-enqueue).
    private let toolDispatch: SessionToolDispatchBinder

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
        self.pipeline = pipeline
        self.budgetPlanner = budgetPlanner
        self.ragService = ragService
        self.usageStore = usageStore
        self.registry = registry
        self.events = TurnEventEmitter(emit)
        self.emptyResponseObserver = emptyResponseObserver
        self.generationHooks = generationHooks
        self.compressionPolicy = compressionPolicy
        self.preTurnCompressionPolicy = preTurnCompressionPolicy
        self.hookTimeout = hookTimeout
        self.historyShaper = historyShaper
        self.historyAssembler = HistoryAssembler(providers: historyProviders)
        self.hostTurnContextProvider = hostTurnContextProvider
        self.legacyTurnContextProvider = turnContextProvider
        self.bindings = bindings
        self.toolDispatch = SessionToolDispatchBinder(inferenceService: inferenceService)
    }

    // MARK: Send flow

    func runSendFlow(
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
        // Failures throw to the caller — unlike post-turn compression which
        // logs and continues, pre-turn failure aborts the turn because the
        // host's ordering invariant depends on compression completing first.
        //
        // userMessage is created AFTER this block so its timestamp naturally
        // follows the compression summary records in store sort order.
        if let preTurnPolicy = preTurnCompressionPolicy {
            let existingHistory: [ChatMessage]
            do {
                existingHistory = try await persistence.fetchMessages(sessionID: sessionID)
            } catch {
                throw ConversationError.persistence(error)
            }
            let lastPromptTokens = existingHistory.last(where: { $0.role == .assistant })?.promptTokens
            if preTurnPolicy.shouldCompressBeforeTurn(
                messageCount: existingHistory.count,
                lastPromptTokens: lastPromptTokens
            ) {
                let generate = makeCompressionGenerateClosure()
                let compressed: [ChatMessage]
                do {
                    compressed = try await preTurnPolicy.compressBeforeTurn(
                        history: existingHistory,
                        sessionID: sessionID,
                        generate: generate
                    )
                } catch {
                    throw ConversationError.preTurnCompressionFailed(error)
                }
                guard !compressed.isEmpty else {
                    throw ConversationError.preTurnCompressionFailed(
                        PreTurnCompressionEmptyResultError()
                    )
                }
                // "Before" bracket for the `.historyCompressed` "after" signal.
                // The removed set is computed from the policy's replacement
                // output (records present before but absent from `compressed`)
                // so the IDs are accurate rather than a placeholder — emitting
                // it here, after `compressBeforeTurn` resolves but before the
                // store mutation, keeps it ordered ahead of `.historyCompressed`
                // without fabricating which records will actually be dropped.
                let retainedIDs = Set(compressed.map(\.id))
                let removedIDs = existingHistory.compactMap {
                    retainedIDs.contains($0.id) ? nil : $0.id
                }
                emit(.compressionTriggered(removed: removedIDs, reason: .contextWindowExceeded))
                do {
                    try await persistence.deleteMessages(for: sessionID)
                    for message in compressed {
                        try await persistence.insertMessage(message)
                    }
                } catch {
                    throw ConversationError.persistence(error)
                }
                emit(.historyCompressed(sessionID: sessionID, insertedRecords: compressed))
                await preTurnPolicy.postCompressBeforeTurn(
                    sessionID: sessionID,
                    insertedRecords: compressed
                )
            }
        }

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
        await taskRegistry.launch(handle: handle) { [self] in
            // Fire pre-turn hooks so consumers can cancel in-flight work from prior turns.
            for hook in generationHooks {
                await hook.willBeginTurn(sessionID: sessionID)
            }
            let preparedHistory: PreparedTurnHistory
            do {
                preparedHistory = try await fetchAndPrepareTurnHistory(
                    sessionID: sessionID,
                    turnKind: .send(text: text, attachments: attachments),
                    userPrompt: text
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
                userPrompt: text,
                preparedHistory: preparedHistory,
                config: config,
                handle: handle,
                outcomeCompletion: outcomeCompletion
            )
        }

        return handle
    }

    // MARK: Regenerate flow

    func runRegenerateFlow(
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

        await taskRegistry.launch(handle: handle) { [self] in
            // Fire pre-turn hooks so consumers can cancel in-flight work from prior turns.
            for hook in generationHooks {
                await hook.willBeginTurn(sessionID: sessionID)
            }
            let preparedHistory: PreparedTurnHistory
            do {
                preparedHistory = try await fetchAndPrepareTurnHistory(
                    sessionID: sessionID,
                    turnKind: .regenerate,
                    userPrompt: nil
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
                userPrompt: nil,
                preparedHistory: preparedHistory,
                config: config,
                handle: handle,
                outcomeCompletion: outcomeCompletion
            )
        }

        return handle
    }

    // MARK: Edit flow

    func runEditFlow(
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
        updatedMessage.content = text
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
        await taskRegistry.launch(handle: handle) { [self] in
            // Fire pre-turn hooks so consumers can cancel in-flight work from prior turns.
            for hook in generationHooks {
                await hook.willBeginTurn(sessionID: sessionID)
            }
            let preparedHistory: PreparedTurnHistory
            do {
                preparedHistory = try await fetchAndPrepareTurnHistory(
                    sessionID: sessionID,
                    turnKind: .edit(messageID: messageID, text: text),
                    userPrompt: nil
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
                userPrompt: nil,
                preparedHistory: preparedHistory,
                config: config,
                handle: handle,
                outcomeCompletion: outcomeCompletion
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
        config: TurnConfig,
        taskRegistry: ConversationTurnTaskRegistry,
        outcomeCompletion: ConversationTurnOutcomeCompletion? = nil
    ) async throws -> ConversationStreamHandle? {
        // Fetch source history synchronously so callers observe ordering:
        // `.sessionBranched` fires before `processTurn` returns.
        let sourceHistory: [ChatMessage]
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

        let newSession = ChatSession(id: newSessionID, title: resolvedTitle)
        do {
            try await persistence.insertSession(newSession)
        } catch {
            throw ConversationError.persistence(error)
        }

        // Copy messages into the new session with fresh IDs and updated
        // sessionID.
        for original in slice {
            let copy = ChatMessage(
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
        await taskRegistry.launch(handle: handle) { [self] in
            let preparedHistory: PreparedTurnHistory
            do {
                preparedHistory = try await fetchAndPrepareTurnHistory(
                    sessionID: newSessionID,
                    turnKind: .branch(
                        messageID: branchMessageID,
                        newSessionID: newSessionID,
                        newSessionTitle: newSessionTitle,
                        generateAfter: generateAfter
                    ),
                    userPrompt: nil
                )
            } catch {
                await failPreparedTurn(
                    error,
                    sessionID: newSessionID,
                    handle: handle,
                    outcomeCompletion: outcomeCompletion
                )
                return
            }
            await runGenerationTurn(
                sessionID: newSessionID,
                userPrompt: nil,
                preparedHistory: preparedHistory,
                config: branchConfig,
                handle: handle,
                outcomeCompletion: outcomeCompletion
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
        preparedHistory: PreparedTurnHistory,
        config: TurnConfig,
        handle: ConversationStreamHandle,
        outcomeCompletion: ConversationTurnOutcomeCompletion? = nil
    ) async {
        let history = preparedHistory.history
        let turnContext = preparedHistory.turnContext
        let messageCount = turnContext.messageCount

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
                let conversationError = ConversationError.contextAssembly(error)
                emit(.errorRaised(conversationError))
                await completeOutcome(
                    outcomeCompletion,
                    sessionID: sessionID,
                    handle: handle,
                    error: conversationError
                )
                return
            }
        } else if let pipeline {
            do {
                slots = try await pipeline.assemble(
                    totalBudget: Int.max,
                    contextSize: 0,
                    context: turnContext
                )
            } catch {
                let conversationError = ConversationError.contextAssembly(error)
                emit(.errorRaised(conversationError))
                await completeOutcome(
                    outcomeCompletion,
                    sessionID: sessionID,
                    handle: handle,
                    error: conversationError
                )
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

        // Multi-agent session snapshot. Read once per turn so the active
        // agent's system prompt, handoff detector, and message tagging all
        // use the same state — a mid-turn write from another flow can't
        // partially update us. `sessionRecord` is `nil` for sessionless
        // flows or hosts without a SessionStore wired in; both paths are
        // identical to the legacy single-agent surface.
        var sessionRecord: ChatSession? = await persistence.fetchSession(sessionID: sessionID)

        // Snapshot the host-mutable bindings once per turn. A
        // `ConversationRuntime.updateSessionToolSources(_:)` /
        // `updateHookRegistry(_:)` call concurrent with this turn takes
        // effect on the *next* turn — deliberately, so a long in-flight
        // generation isn't reconfigured mid-stream.
        let (turnSessionToolSources, turnHookRegistry) = await bindings.snapshot()

        let activeAgent: Agent? = {
            guard let sessionRecord, let activeID = sessionRecord.activeAgentID else { return nil }
            return sessionRecord.agents.first(where: { $0.id == activeID })
        }()
        let agentSiblings: [Agent] = {
            guard let sessionRecord, let activeID = sessionRecord.activeAgentID else { return [] }
            return sessionRecord.agents.filter { $0.id != activeID }
        }()

        // Configure the handoff detector for this turn. The closure is
        // captured by the GenerationQueue's loop construction; we always
        // (re)set it so a host that mutates session.agents between turns
        // sees the new registry on the next call without a clear/reset
        // dance.
        if let sessionRecord {
            await inferenceService.setHandoffDetector { @Sendable callSessionID, call in
                guard callSessionID == sessionRecord.id else {
                    // Detector closures live on the queue but loop captures
                    // a per-request sessionID; mismatches are defensive —
                    // route through the regular dispatch path.
                    return .regular(call)
                }
                return HandoffDetector.classify(call, in: sessionRecord)
            }
        } else {
            await inferenceService.setHandoffDetector(nil)
        }

        // Pre-tool-use hook plumbing. The runtime owns the HookRegistry
        // (Runtime can import Inference, not the other way round) so we
        // adapt the registry into the closure shape the dispatch loop
        // accepts. The adapter enforces the sanitize-only invariant and
        // emits `.hookFired(event: "preToolUse", ...)` on every call.
        if let turnHookRegistry {
            // Pass the bare `@Sendable` sink (not a main-actor-capturing
            // wrapper) so the adapter closure stays free of `@MainActor` state
            // — invariant 5.
            let sink = events.sink
            let adapter = PreToolUseHookAdapter.make(
                registry: turnHookRegistry,
                eventEmitter: { event in sink(event) }
            )
            await inferenceService.setPreToolUseHook(adapter)
        } else {
            await inferenceService.setPreToolUseHook(nil)
        }

        // Build the assistant message slot up front so token deltas can
        // reference its id from the first emitted token.
        //
        // Citations carry the provenance of any retrieved passages so the UI
        // can render a "Sources" disclosure beneath the assistant bubble.
        // `nil` when RAG didn't run for this turn (no service, no user
        // prompt, or retrieval threw).
        var assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            sessionID: sessionID,
            citations: ragCitations.isEmpty ? nil : ragCitations,
            agentID: activeAgent?.id
        )
        let assistantID = assistantMessage.id
        func writeFinalContent(_ text: String, into message: inout ChatMessage) {
            message.contentParts.removeAll {
                if case .text = $0 { return true }
                return false
            }
            if !text.isEmpty {
                message.contentParts.append(.text(text))
            }
        }

        // Multi-agent: re-derive the active system prompt from the
        // session's `activeAgentID` per turn (plan §Handoff semantics
        // option (a)). Prior assistant messages keep their `agentID`
        // attribution — no history rewrite. The handoff-instructions block
        // is prepended so weak local models actually trigger transfers
        // when they're appropriate (plan AI-review fix #2).
        let basePrompt: String?
        if let activeAgent {
            let instructions = HandoffDetector.handoffInstructions(for: activeAgent, siblings: agentSiblings)
            if instructions.isEmpty {
                basePrompt = activeAgent.systemPrompt
            } else {
                basePrompt = "\(instructions)\n\n\(activeAgent.systemPrompt)"
            }
        } else {
            basePrompt = config.systemPrompt
        }
        let composedSystemPrompt = composeSystemPrompt(basePrompt, slots: slots)

        // kind.backendRole == nil means use record.role directly (.chat case);
        // non-chat kinds supply a fixed role. Records with isWireVisible == false
        // are filtered out before this map runs.
        var structuredHistory: [StructuredMessage] = history
            .filter { $0.kind.isWireVisible }
            .map { record in
                let role = record.kind.backendRole ?? record.role
                return StructuredMessage(role: role.rawValue, parts: record.contentParts)
            }

        // Multi-agent boundary message (plan AI-review fix #3). When the
        // last assistant turn in history was authored by a different agent
        // than the one about to author this turn, prepend a synthetic
        // system-role marker so the receiving agent sees an explicit
        // context-handover boundary instead of "what is this conversation."
        // Not persisted as a `ChatMessage` — transient per turn.
        if let activeAgent,
           let lastAssistant = history.last(where: { $0.role == .assistant }),
           let previousAgentID = lastAssistant.agentID,
           previousAgentID != activeAgent.id,
           let previousAgent = sessionRecord?.agents.first(where: { $0.id == previousAgentID }) {
            let boundary = HandoffDetector.boundaryMessage(
                from: previousAgent,
                to: activeAgent,
                payload: nil
            )
            structuredHistory.append(StructuredMessage(role: "system", parts: [.text(boundary)]))
        }

        // Forward the registered tool surface so the backend's GenerationConfig
        // gets `tools = registry.advertisedDefinitions` (legacy parity with
        // GenerationQueue.enqueueGeneration). `advertisedDefinitions`
        // already honours `advertisedToolNames` filtering — registering a
        // tool but limiting which names go on the wire works without
        // unregistering the executor. Fetched on the main actor because the
        // registry and InferenceService accessors are both MainActor-isolated.
        let advertisedTools: [ToolDefinition] = await toolDispatch.advertisedToolDefinitions(
            sessionToolSources: turnSessionToolSources,
            sessionRecord: sessionRecord
        )

        // Wire dispatch for the session tools we just advertised. Without this
        // the model can *call* `generate_image` / `web_search` / etc. but the
        // dispatch loop finds no registry executor and returns `unknownTool`
        // (#1606). Registered after `advertisedTools` is computed so advertising
        // is unaffected; unregistered once the stream fully drains below.
        let registeredSessionToolNames = await toolDispatch.registerSessionToolExecutors(
            sources: turnSessionToolSources,
            sessionRecord: sessionRecord
        )

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
                requestGroupID: sessionID
            )
        } catch {
            await toolDispatch.unregisterSessionToolExecutors(registeredSessionToolNames)
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

        // Drain the stream, mirroring GenerationQueue's four features:
        //   (a) token batcher — coalesce per-token events into UI-cadenced batches
        //   (b) thinking-block disclosure — track/batch reasoning tokens and emit
        //       thinkingStarted / thinkingUpdated / thinkingFinalized events
        //   (c) tool dispatch — persist toolCall + toolResult content parts and
        //       emit toolCallRequested / toolCallCompleted events
        //   (d) loop detection — stop the stream when RepetitionDetector fires
        var accumulator = GenerationStreamAccumulator()
        var streamFailed: ConversationError?

        var consumer = GenerationStreamConsumer(loopDetectionEnabled: config.loopDetectionEnabled)
        var batcher = StreamingTokenBatcher(
            interval: config.streamingUpdateInterval,
            maxBufferedCharacters: config.streamingBatchCharacterLimit
        )
        var thinkingBatcher = StreamingTokenBatcher(
            interval: config.thinkingStreamingUpdateInterval,
            maxBufferedCharacters: config.thinkingStreamingBatchCharacterLimit
        )
        var thinkingDisplayed = ""

        do {
            eventLoop: for try await event in stream.events {
                let cancelled = await isCancelled(handle: handle)
                if cancelled { break }

                switch consumer.handle(event) {
                case .appendText(let text):
                    accumulator.recordTextToken()
                    if let batch = batcher.append(text, now: ContinuousClock.now) {
                        accumulator.appendVisibleText(batch)
                        emit(.tokenEmitted(messageID: assistantID, delta: batch))
                        if consumer.shouldStopForLoop(content: accumulator.visibleText) {
                            await inferenceService.cancelAsync(token)
                            emit(.loopDetected(messageID: assistantID))
                            break eventLoop
                        }
                    }

                case .appendThinkingText(let text):
                    if accumulator.appendThinkingText(text) {
                        emit(.thinkingStarted(messageID: assistantID))
                    }
                    if let batch = thinkingBatcher.append(text, now: ContinuousClock.now) {
                        thinkingDisplayed += batch
                        emit(.thinkingUpdated(messageID: assistantID, partialText: thinkingDisplayed))
                        if consumer.shouldStopForLoop(content: accumulator.currentThinkingText) {
                            await inferenceService.cancelAsync(token)
                            emit(.loopDetected(messageID: assistantID))
                            break eventLoop
                        }
                    }

                case .recordThinkingSignature(let signature):
                    accumulator.recordThinkingSignature(signature)

                case .finalizeThinking:
                    if let batch = thinkingBatcher.flush(now: ContinuousClock.now) {
                        thinkingDisplayed += batch
                    }
                    thinkingDisplayed = ""
                    if let block = accumulator.finalizeThinking() {
                        emit(.thinkingFinalized(messageID: assistantID, text: block.text, signature: block.signature))
                    }

                case .dispatchToolCall(let call):
                    assistantMessage.contentParts.append(.toolCall(call))
                    emit(.toolCallRequested(call))

                case .recordToolApproval(let callId):
                    emit(.toolCallApproved(callId))

                case .appendToolResult(let result):
                    assistantMessage.contentParts.append(.toolResult(result))
                    emit(.toolCallCompleted(result.callId, result))

                case .toolIterationLimitExceeded(let iterations):
                    emit(.errorRaised(.inference(
                        InferenceError.inferenceFailure("Tool-call loop stopped after \(iterations) iterations.")
                    )))

                case .recordUsage(let prompt, let completion):
                    accumulator.recordUsage(prompt: prompt, completion: completion)

                case .recordHandoff(let handoff):
                    // Persist the active-agent swap and emit the typed
                    // ConversationEvent so adapters can render a handoff
                    // chip. The next turn re-derives the system prompt
                    // from the new activeAgentID and prepends the boundary
                    // message into structuredHistory.
                    if var current = sessionRecord {
                        let previousID = current.activeAgentID
                        current.activeAgentID = handoff.targetAgentID
                        _ = await persistence.updateSession(current)
                        sessionRecord = current
                        emit(.agentHandoff(from: previousID, to: handoff.targetAgentID))
                    } else {
                        Log.inference.warning(
                            "ConversationTurnExecutor: received handoff event but session record was unavailable; agent swap dropped"
                        )
                    }

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

        // Tool dispatch is complete once the stream has drained — the dispatch
        // loop runs on the producer side as we consume events. Unregister the
        // session-scoped executors now so the shared registry doesn't carry a
        // stale ``ChatSession`` binding into the next turn (#1606). All
        // remaining exit paths below are post-stream, so this is the single
        // cleanup point alongside the enqueue-failure path above.
        await toolDispatch.unregisterSessionToolExecutors(registeredSessionToolNames)

        // Flush remaining buffered tokens (normal end, error, or cancellation).
        if let batch = batcher.flush(now: ContinuousClock.now) {
            accumulator.appendVisibleText(batch)
            emit(.tokenEmitted(messageID: assistantID, delta: batch))
        }

        // Finalize an unclosed thinking block — the model may not emit a closing
        // event if generation is cut short.
        if accumulator.hasOpenThinkingBlock {
            _ = thinkingBatcher.flush(now: ContinuousClock.now)
            if let block = accumulator.finalizeThinking() {
                emit(.thinkingFinalized(messageID: assistantID, text: block.text, signature: block.signature))
            }
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
        if cancelled {
            await inferenceService.cancelAsync(token)
        }
        await registry.unregister(handle: handle)

        // Capture token usage off the active backend before any subsequent
        // turn can overwrite it. The legacy `GenerationQueue` set this
        // on the assistant `ChatMessage` immediately after the stream ended;
        // the runtime path needs the same per-turn pinning so back-to-back
        // sends do not cross-contaminate prompt/completion counts. Read on
        // the main actor — `InferenceService.lastTokenUsage` is MainActor-
        // isolated.
        let usage: (promptTokens: Int, completionTokens: Int)?
        if let recordedUsage = accumulator.tokenUsage {
            usage = recordedUsage
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
            writeFinalContent(accumulator.visibleText, into: &assistantMessage)
            if !accumulator.visibleText.isEmpty || hasToolContent {
                do {
                    try await persistence.insertMessage(assistantMessage)
                    emit(.messageInserted(assistantMessage))
                } catch {
                    let persistenceError = ConversationError.persistence(error)
                    emit(.errorRaised(persistenceError))
                    emit(.errorRaised(streamFailed))
                    emit(.streamFinished(messageID: assistantID, reason: .stop))
                    await completeOutcome(
                        outcomeCompletion,
                        sessionID: sessionID,
                        handle: handle,
                        assistantMessageID: assistantID,
                        reason: .stop,
                        error: persistenceError,
                        finalText: accumulator.visibleText,
                        promptTokens: usage?.promptTokens,
                        completionTokens: usage?.completionTokens
                    )
                    return
                }
            }
            emit(.errorRaised(streamFailed))
            emit(.streamFinished(messageID: assistantID, reason: .stop))
            await completeOutcome(
                outcomeCompletion,
                sessionID: sessionID,
                handle: handle,
                assistantMessageID: assistantID,
                assistantMessage: (!accumulator.visibleText.isEmpty || hasToolContent) ? assistantMessage : nil,
                reason: .stop,
                error: streamFailed,
                finalText: accumulator.visibleText,
                promptTokens: usage?.promptTokens,
                completionTokens: usage?.completionTokens
            )
            return
        } else if accumulator.isEmptyResponse && !hasToolContent {
            reason = .empty
        } else {
            reason = .stop
        }

        if cancelled {
            // On cancel, persist whatever streamed in so far if non-empty —
            // matches ChatViewModel.stopGeneration's behaviour.
            if !accumulator.visibleText.isEmpty || hasToolContent {
                writeFinalContent(accumulator.visibleText, into: &assistantMessage)
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
            await completeOutcome(
                outcomeCompletion,
                sessionID: sessionID,
                handle: handle,
                assistantMessageID: assistantID,
                assistantMessage: (!accumulator.visibleText.isEmpty || hasToolContent) ? assistantMessage : nil,
                reason: reason,
                error: nil,
                finalText: accumulator.visibleText,
                promptTokens: usage?.promptTokens,
                completionTokens: usage?.completionTokens
            )
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
            await completeOutcome(
                outcomeCompletion,
                sessionID: sessionID,
                handle: handle,
                assistantMessageID: assistantID,
                reason: reason,
                finalText: "",
                promptTokens: usage?.promptTokens,
                completionTokens: usage?.completionTokens
            )
            return
        }

        // Happy path: persist the assistant message.
        writeFinalContent(accumulator.visibleText, into: &assistantMessage)
        do {
            try await persistence.insertMessage(assistantMessage)
            emit(.messageInserted(assistantMessage))
        } catch {
            let conversationError = ConversationError.persistence(error)
            emit(.errorRaised(conversationError))
            emit(.streamFinished(messageID: assistantID, reason: reason))
            await completeOutcome(
                outcomeCompletion,
                sessionID: sessionID,
                handle: handle,
                assistantMessageID: assistantID,
                reason: reason,
                error: conversationError,
                finalText: accumulator.visibleText,
                promptTokens: usage?.promptTokens,
                completionTokens: usage?.completionTokens
            )
            return
        }

        emit(.streamFinished(messageID: assistantID, reason: reason))
        emit(.afterGeneration(messageID: assistantID, finalText: accumulator.visibleText))
        await completeOutcome(
            outcomeCompletion,
            sessionID: sessionID,
            handle: handle,
            assistantMessageID: assistantID,
            assistantMessage: assistantMessage,
            reason: reason,
            finalText: accumulator.visibleText,
            promptTokens: usage?.promptTokens,
            completionTokens: usage?.completionTokens
        )

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
            // enqueueAsync. The endpoint identity is now threaded from the
            // lifecycle coordinator (#1207) so endpoint-backed turns attribute
            // usage to the serving ``APIEndpointRecord``.
            let backendName = await readActiveBackendName()
            let endpointID = await readActiveEndpointID()
            let record = TurnUsage(
                sessionID: sessionID,
                endpointID: endpointID,
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
                appData: turnContext.appData
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
                let history: [ChatMessage]
                do {
                    history = try await persistence.fetchMessages(sessionID: sessionID)
                } catch {
                    Log.inference.warning("CompressionPolicy: fetchMessages failed, skipping compression: \(error.localizedDescription, privacy: .public)")
                    return
                }

                let generate = makeCompressionGenerateClosure()

                // preCompact hook: v1 is observational. The plan's hook
                // contract documents that preCompact CANNOT block compression
                // (there's no mutation channel for the history shape); a
                // hook that returns block:true logs a warning but compression
                // still runs. Emit `.hookFired(event: "preCompact", ...)`
                // regardless so observability stays consistent.
                if let turnHookRegistry {
                    let input = HookInput(
                        event: .preCompact,
                        sessionID: sessionID,
                        toolName: nil,
                        toolArguments: nil
                    )
                    let output = await turnHookRegistry.run(input)
                    emit(.hookFired(event: "preCompact", sessionID: sessionID))
                    if output.block {
                        Log.inference.warning(
                            "preCompact hook returned block:true — block is not honoured for compaction in v1; ignoring and proceeding with compression."
                        )
                    }
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
                    // "Before" bracket for `.historyCompressed`. Removed IDs are
                    // derived from the policy's replacement set (records present
                    // in `history` but absent from `compressed`) so the event
                    // carries the real dropped records, emitted ahead of the
                    // store mutation and the "after" `.historyCompressed`.
                    let retainedIDs = Set(compressed.map(\.id))
                    let removedIDs = history.compactMap {
                        retainedIDs.contains($0.id) ? nil : $0.id
                    }
                    emit(.compressionTriggered(removed: removedIDs, reason: .contextWindowExceeded))
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

    private enum TurnPreparationFailure: Error {
        case persistence(any Error)
        case contextAssembly(any Error)
    }

    private struct PreTurnCompressionEmptyResultError: LocalizedError, Sendable {
        var errorDescription: String? {
            "Pre-turn compression returned an empty history."
        }
    }

    private enum HistoryShaperValidationError: LocalizedError, Sendable {
        case duplicateMessageIDs
        case nonCanonicalMessageIDs
        case orderViolation

        var errorDescription: String? {
            switch self {
            case .duplicateMessageIDs:
                return "HistoryShaper returned duplicate prompt-visible message IDs."
            case .nonCanonicalMessageIDs:
                return "HistoryShaper may only return canonical message IDs."
            case .orderViolation:
                return "HistoryShaper must preserve canonical record order for visible messages."
            }
        }
    }

    private func fetchAndPrepareTurnHistory(
        sessionID: UUID,
        turnKind: TurnKind,
        userPrompt: String?
    ) async throws -> PreparedTurnHistory {
        let canonicalHistory: [ChatMessage]
        do {
            canonicalHistory = try await persistence.fetchMessages(sessionID: sessionID)
        } catch {
            throw TurnPreparationFailure.persistence(error)
        }

        let request = TurnContextBuildRequest(
            sessionID: sessionID,
            turnKind: turnKind,
            messageCount: canonicalHistory.count,
            userInput: userPrompt,
            conversationText: conversationText(for: canonicalHistory),
            tokenizer: await readTokenizer()
        )

        let appData: (any Sendable)?
        do {
            appData = try await resolveTurnAppData(for: request)
        } catch {
            throw TurnPreparationFailure.contextAssembly(error)
        }

        let shapedHistory: [ChatMessage]
        do {
            shapedHistory = try await shapeHistory(
                canonicalHistory,
                sessionID: sessionID,
                request: HistoryShapingRequest(
                    turnContextRequest: request,
                    appData: appData
                )
            )
        } catch {
            throw TurnPreparationFailure.contextAssembly(error)
        }

        let historyProviderContext = makeTurnContext(
            sessionID: sessionID,
            history: shapedHistory,
            tokenizer: request.tokenizer,
            appData: appData
        )

        let assembledHistory: [ChatMessage]
        do {
            assembledHistory = try await historyAssembler.assemble(
                history: shapedHistory,
                context: historyProviderContext
            )
        } catch {
            throw TurnPreparationFailure.persistence(error)
        }

        return PreparedTurnHistory(
            history: assembledHistory,
            turnContext: makeTurnContext(
                sessionID: sessionID,
                history: assembledHistory,
                tokenizer: request.tokenizer,
                appData: appData
            )
        )
    }

    private func failPreparedTurn(
        _ error: Error,
        sessionID: UUID,
        handle: ConversationStreamHandle,
        outcomeCompletion: ConversationTurnOutcomeCompletion?
    ) async {
        let conversationError: ConversationError
        if let failure = error as? TurnPreparationFailure {
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

    private func resolveTurnAppData(
        for request: TurnContextBuildRequest
    ) async throws -> (any Sendable)? {
        if let hostTurnContextProvider {
            return try await hostTurnContextProvider.appData(for: request)
        }
        return legacyTurnContextProvider?(request.sessionID)
    }

    private func shapeHistory(
        _ canonicalHistory: [ChatMessage],
        sessionID: UUID,
        request: HistoryShapingRequest
    ) async throws -> [ChatMessage] {
        guard let historyShaper else { return canonicalHistory }

        let result = try await historyShaper.shape(history: canonicalHistory, request: request)
        try validateShapedHistory(result.promptHistory, against: canonicalHistory)
        emit(.historyShaped(sessionID: sessionID, diagnostics: result.diagnostics))
        return result.promptHistory
    }

    private func validateShapedHistory(
        _ promptHistory: [ChatMessage],
        against canonicalHistory: [ChatMessage]
    ) throws {
        let canonicalIDs = canonicalHistory.map(\.id)
        let canonicalIDSet = Set(canonicalIDs)
        let promptIDs = promptHistory.map(\.id)

        guard Set(promptIDs).count == promptIDs.count else {
            throw HistoryShaperValidationError.duplicateMessageIDs
        }

        guard promptIDs.allSatisfy(canonicalIDSet.contains) else {
            throw HistoryShaperValidationError.nonCanonicalMessageIDs
        }

        let canonicalVisibleIDs = canonicalIDs.filter { promptIDs.contains($0) }
        guard canonicalVisibleIDs == promptIDs else {
            throw HistoryShaperValidationError.orderViolation
        }
    }

    /// Returns a `@Sendable` closure that drives a background inference call
    /// for summarisation. Used by both pre-turn and post-turn compression paths.
    private func makeCompressionGenerateClosure() -> @Sendable ([ChatMessage]) async throws -> String {
        let inferenceService = self.inferenceService
        return { messages in
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
                    try Task.checkCancellation()
                    if case .appendText(let chunk) = consumer.handle(event) {
                        result += chunk
                    }
                }
            } catch {
                await inferenceService.cancelAsync(token)
                throw error
            }
            return result
        }
    }

    private func makeTurnContext(
        sessionID: UUID,
        history: [ChatMessage],
        tokenizer: (any TokenizerProvider)?,
        appData: (any Sendable)?
    ) -> TurnContext {
        TurnContext(
            sessionID: sessionID,
            messageCount: history.count,
            conversationText: conversationText(for: history),
            tokenizer: tokenizer,
            appData: appData
        )
    }

    private func conversationText(for history: [ChatMessage]) -> String? {
        guard !history.isEmpty else { return nil }
        let joined = history
            .compactMap { record -> String? in
                let text = record.contentParts.compactMap(\.textContent).joined(separator: " ")
                return text.isEmpty ? nil : text
            }
            .joined(separator: " ")
            .lowercased()
        return joined.isEmpty ? nil : joined
    }

    /// Reads the backend's context window size from the main actor.
    /// Returns 0 when unavailable — callers treat 0 as "skip compression".
    @MainActor
    private func readContextWindowSize() async -> Int {
        inferenceService.capabilities?.contextWindowSize ?? 0
    }

    @MainActor
    private func readTokenizer() async -> (any TokenizerProvider)? {
        inferenceService.tokenizer
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
    private func readLastTokenUsage() async -> (promptTokens: Int, completionTokens: Int)? {
        inferenceService.lastTokenUsage
    }

    @MainActor
    private func readActiveBackendName() async -> String? {
        inferenceService.activeBackendName
    }

    @MainActor
    private func readActiveEndpointID() async -> UUID? {
        inferenceService.activeEndpointID
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
