import Foundation
import ManifoldInference

// MARK: - TurnPreparation
//
// Issue #1957 Tier 4 / architecture Priority 3: the pre-enqueue half of
// `ConversationTurnExecutor.runGenerationTurn` lived inline against a wall of
// local `var`s, so no phase was unit-testable without the full runtime +
// backend stack. This type owns history fetch/heal/shape → context assembly →
// RAG → system-prompt composition → tool advertise/register, and returns a
// small immutable ``PreparedTurn`` the executor can enqueue from.

/// Owns the pre-enqueue preparation phases of a generation turn.
///
/// `package`, not `public`, per docs/API-DESIGN.md's default — no companion
/// package, manifold-eval, or consumer app conforms to or consumes this type
/// directly today.
package struct TurnPreparation: Sendable {
    private let persistence: any TurnPersistencePort
    private let inferenceService: InferenceService
    private let pipeline: PromptContextPipeline?
    private let budgetPlanner: ContextBudgetPlanner?
    private let ragService: RAGService?
    private let events: TurnEventEmitter
    private let historyShaper: (any HistoryShaper)?
    private let historyAssembler: HistoryAssembler
    private let hostTurnContextProvider: (any HostTurnContextProvider)?
    private let legacyTurnContextProvider: (@Sendable (UUID) -> (any Sendable)?)?
    private let bindings: RuntimeBindingsBox
    private let toolDispatch: SessionToolDispatchBinder

    init(
        persistence: any TurnPersistencePort,
        inferenceService: InferenceService,
        pipeline: PromptContextPipeline?,
        budgetPlanner: ContextBudgetPlanner?,
        ragService: RAGService?,
        events: TurnEventEmitter,
        historyShaper: (any HistoryShaper)?,
        historyAssembler: HistoryAssembler,
        hostTurnContextProvider: (any HostTurnContextProvider)?,
        legacyTurnContextProvider: (@Sendable (UUID) -> (any Sendable)?)?,
        bindings: RuntimeBindingsBox,
        toolDispatch: SessionToolDispatchBinder
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.pipeline = pipeline
        self.budgetPlanner = budgetPlanner
        self.ragService = ragService
        self.events = events
        self.historyShaper = historyShaper
        self.historyAssembler = historyAssembler
        self.hostTurnContextProvider = hostTurnContextProvider
        self.legacyTurnContextProvider = legacyTurnContextProvider
        self.bindings = bindings
        self.toolDispatch = toolDispatch
    }

    /// Failure taxonomy for the history-preparation phase. Mapped to
    /// ``ConversationError`` by the launch path before any stream starts.
    package enum HistoryFailure: Error {
        case persistence(any Error)
        case contextAssembly(any Error)
    }

    /// Failure taxonomy for the generation-setup phase (context assembly /
    /// budget planner). Distinct from RAG failures, which log-and-continue.
    package enum GenerationFailure: Error {
        case contextAssembly(any Error)
    }

    /// Immutable output of generation preparation — everything
    /// `enqueueAsync` needs plus the state the drain/finalize path threads.
    package struct PreparedTurn: Sendable {
        package let turnContext: TurnContext
        package let composedSystemPrompt: String?
        package let structuredHistory: [StructuredMessage]
        package let advertisedTools: [ToolDefinition]
        /// Names registered on the shared tool registry for this turn; the
        /// executor unregisters them on every exit path after enqueue.
        package let registeredSessionToolNames: Set<String>
        package let assistantMessage: ChatMessage
        package let ragDocuments: [RetrievedDocument]
        /// Multi-agent session snapshot. Drain mutates `activeAgentID` on a
        /// mid-stream handoff; held as a `var` only inside the drain path.
        package let sessionRecord: ChatSession?
        package let turnHookRegistry: HookRegistry?
        /// Per-request handoff detector for this turn. Passed into
        /// `enqueueAsync` rather than mutated onto the shared
        /// `InferenceService` — closes the race where two concurrent turns
        /// clobbered the service-global detector (#1494). `nil` for
        /// sessionless / single-agent turns.
        package let handoffDetector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)?
        /// Per-request pre-tool-use hook for this turn. See ``handoffDetector``
        /// for the rationale. `nil` when no host hook registry is wired.
        package let preToolUseHook: PreToolUseHook?
    }

    // MARK: History preparation

    /// History fetch/heal → host appData → shape → additive history providers.
    /// Throws ``HistoryFailure`` so the launch path can map to a typed
    /// ``ConversationError`` before any stream starts.
    package func prepareHistory(
        sessionID: UUID,
        turnKind: TurnKind,
        userPrompt: String?
    ) async throws -> PreparedTurnHistory {
        let canonicalHistory: [ChatMessage]
        do {
            // Generation-bound fetch: heals orphan tool calls (turn cancelled
            // or process killed mid-tool) before token estimation, the
            // optional HistoryShaper, and context-window assembly run —
            // otherwise the unanswered tool_use reproduces the #629 cloud-API
            // rejection. See HealedHistoryFetch.swift for the seam contract.
            canonicalHistory = try await persistence.fetchRecentHealedMessages(
                sessionID: sessionID,
                limit: 10_000
            )
        } catch {
            throw HistoryFailure.persistence(error)
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
            throw HistoryFailure.contextAssembly(error)
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
            throw HistoryFailure.contextAssembly(error)
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
            throw HistoryFailure.persistence(error)
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

    // MARK: Generation preparation

    /// Context assembly → RAG → session/bindings snapshot → system prompt →
    /// structured history → tool advertise/register. Throws
    /// ``GenerationFailure`` on budget/pipeline assembly errors; RAG failures
    /// log and continue (parity with the pre-split path).
    package func prepareGeneration(
        sessionID: UUID,
        userPrompt: String?,
        preparedHistory: PreparedTurnHistory,
        config: TurnConfig
    ) async throws -> PreparedTurn {
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
        events.emit(.beforeContextAssembly(prompt: userPrompt, request: request))

        let slots: [PromptSlot]
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
                throw GenerationFailure.contextAssembly(error)
            }
        } else if let pipeline {
            do {
                slots = try await pipeline.assemble(
                    totalBudget: Int.max,
                    contextSize: 0,
                    context: turnContext
                )
            } catch {
                throw GenerationFailure.contextAssembly(error)
            }
        } else {
            slots = []
        }

        var mutableSlots = slots
        var ragCitations: [Citation] = []
        // Structured retrieved passages for the embedded-Jinja `documents` block
        // (#1967). A grounding template formats these directly; templates without
        // a `documents` block still get the same passages via the system-prompt
        // slots above. Empty when RAG didn't run or returned nothing.
        var ragDocuments: [RetrievedDocument] = []
        if let ragService, let userPrompt {
            do {
                let result = try await ragService.retrieve(query: userPrompt)
                mutableSlots.append(contentsOf: result.slots)
                ragCitations = result.citations
                ragDocuments = result.documents
            } catch {
                Log.inference.warning("ConversationRuntime: RAG retrieval failed, continuing without retrieved context: \(error.localizedDescription)")
            }
        }

        events.emit(.contextAssembled(slots: mutableSlots))

        // Multi-agent session snapshot. Read once per turn so the active
        // agent's system prompt, handoff detector, and message tagging all
        // use the same state — a mid-turn write from another flow can't
        // partially update us. `sessionRecord` is `nil` for sessionless
        // flows or hosts without a SessionStore wired in; both paths are
        // identical to the legacy single-agent surface.
        let sessionRecord: ChatSession? = await persistence.fetchSession(sessionID: sessionID)

        // Snapshot the host-mutable bindings once per turn. A
        // `ConversationRuntime.updateSessionToolSources(_:)` /
        // `updateHookRegistry(_:)` call concurrent with this turn takes
        // effect on the *next* turn — deliberately, so a long in-flight
        // generation isn't reconfigured mid-stream.
        let (turnSessionToolSources, turnHookRegistry) = await bindings.snapshot()

        let activeAgent: AgentDefinition? = {
            guard let sessionRecord, let activeID = sessionRecord.activeAgentID else { return nil }
            return sessionRecord.agents.first(where: { $0.id == activeID })
        }()

        // Per-request handoff detector. Prefer the per-request channel on
        // `enqueueAsync` (closes the service-global race #1494); also install
        // on the service for any legacy path still reading the queue-level
        // detector.
        let handoffDetector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)?
        if let sessionRecord {
            let captured = sessionRecord
            handoffDetector = { @Sendable callSessionID, call in
                guard callSessionID == captured.id else {
                    // Detector closures live on the queue but loop captures
                    // a per-request sessionID; mismatches are defensive —
                    // route through the regular dispatch path.
                    return .regular(call)
                }
                return HandoffDetector.classify(call, in: captured)
            }
        } else {
            handoffDetector = nil
        }
        await inferenceService.setHandoffDetector(handoffDetector)

        // Pre-tool-use hook plumbing. The runtime owns the HookRegistry
        // (Runtime can import Inference, not the other way round) so we
        // adapt the registry into the closure shape the dispatch loop
        // accepts. The adapter enforces the sanitize-only invariant and
        // emits `.hookFired(event: "preToolUse", ...)` on every call.
        let preToolUseHook: PreToolUseHook?
        if let turnHookRegistry {
            // Pass the bare `@Sendable` sink (not a main-actor-capturing
            // wrapper) so the adapter closure stays free of `@MainActor` state
            // — invariant 5.
            let sink = events.sink
            preToolUseHook = PreToolUseHookAdapter.make(
                registry: turnHookRegistry,
                eventEmitter: { event in sink(event) }
            )
        } else {
            preToolUseHook = nil
        }
        await inferenceService.setPreToolUseHook(preToolUseHook)

        // Build the assistant message slot up front so token deltas can
        // reference its id from the first emitted token.
        //
        // Citations carry the provenance of any retrieved passages so the UI
        // can render a "Sources" disclosure beneath the assistant bubble.
        // `nil` when RAG didn't run for this turn (no service, no user
        // prompt, or retrieval threw).
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            sessionID: sessionID,
            citations: ragCitations.isEmpty ? nil : ragCitations,
            agentID: activeAgent?.id
        )

        // Multi-agent: re-derive the active system prompt from the
        // session's `activeAgentID` per turn (plan §Handoff semantics
        // option (a)). Prior assistant messages keep their `agentID`
        // attribution — no history rewrite. The handoff-instructions block
        // is prepended so weak local models actually trigger transfers
        // when they're appropriate (plan AI-review fix #2). Shared with
        // pre-turn compression budgeting via ``resolveBaseSystemPrompt``.
        let basePrompt = Self.resolveBaseSystemPrompt(sessionRecord: sessionRecord, config: config)
        let composedSystemPrompt = Self.composeSystemPrompt(basePrompt, slots: mutableSlots)

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

        return PreparedTurn(
            turnContext: turnContext,
            composedSystemPrompt: composedSystemPrompt,
            structuredHistory: structuredHistory,
            advertisedTools: advertisedTools,
            registeredSessionToolNames: registeredSessionToolNames,
            assistantMessage: assistantMessage,
            ragDocuments: ragDocuments,
            sessionRecord: sessionRecord,
            turnHookRegistry: turnHookRegistry,
            handoffDetector: handoffDetector,
            preToolUseHook: preToolUseHook
        )
    }

    // MARK: System-prompt composition (package for direct unit tests)

    /// Base system prompt the turn puts on the wire **before** prompt-slot /
    /// RAG composition — multi-agent active agent (+ handoff instructions)
    /// when present, otherwise ``TurnConfig/systemPrompt``. Shared by
    /// generation preparation and pre-turn compression budgeting
    /// (``ConversationTurnExecutor/runSendFlow``) so both budget against the
    /// same base (#1957). Does **not** read `ChatSession.systemPrompt`; hosts
    /// that store the prompt on the session must also put it on `TurnConfig`
    /// (as `ChatViewModel` does via `effectiveSystemPrompt()`).
    package static func resolveBaseSystemPrompt(
        sessionRecord: ChatSession?,
        config: TurnConfig
    ) -> String? {
        let activeAgent: AgentDefinition? = {
            guard let sessionRecord, let activeID = sessionRecord.activeAgentID else { return nil }
            return sessionRecord.agents.first(where: { $0.id == activeID })
        }()
        let agentSiblings: [AgentDefinition] = {
            guard let sessionRecord, let activeID = sessionRecord.activeAgentID else { return [] }
            return sessionRecord.agents.filter { $0.id != activeID }
        }()
        if let activeAgent {
            let instructions = HandoffDetector.handoffInstructions(
                for: activeAgent, siblings: agentSiblings
            )
            if instructions.isEmpty {
                return activeAgent.systemPrompt
            }
            return "\(instructions)\n\n\(activeAgent.systemPrompt)"
        }
        return config.systemPrompt
    }

    /// Joins the base system prompt with enabled non-empty prompt slots.
    package static func composeSystemPrompt(_ base: String?, slots: [PromptSlot]) -> String? {
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

    // MARK: History helpers

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
        events.emit(.historyShaped(sessionID: sessionID, diagnostics: result.diagnostics))
        return result.promptHistory
    }

    /// package for direct unit tests of the shaper validation rules.
    package static func validateShapedHistory(
        _ promptHistory: [ChatMessage],
        against canonicalHistory: [ChatMessage]
    ) throws {
        let canonicalIDs = canonicalHistory.map(\.id)
        let canonicalIDSet = Set(canonicalIDs)
        let promptIDs = promptHistory.map(\.id)
        // Build a Set once for O(1) membership — reused for both duplicate
        // detection and the canonicalVisibleIDs filter below (was O(n×m)).
        let promptIDSet = Set(promptIDs)

        guard promptIDSet.count == promptIDs.count else {
            throw HistoryShaperValidationError.duplicateMessageIDs
        }

        guard promptIDs.allSatisfy(canonicalIDSet.contains) else {
            throw HistoryShaperValidationError.nonCanonicalMessageIDs
        }

        // Order is preserved: we filter canonicalIDs (canonical ordering) using
        // the set, so canonicalVisibleIDs retains canonical order as before.
        let canonicalVisibleIDs = canonicalIDs.filter { promptIDSet.contains($0) }
        guard canonicalVisibleIDs == promptIDs else {
            throw HistoryShaperValidationError.orderViolation
        }
    }

    private func validateShapedHistory(
        _ promptHistory: [ChatMessage],
        against canonicalHistory: [ChatMessage]
    ) throws {
        try Self.validateShapedHistory(promptHistory, against: canonicalHistory)
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

    @MainActor
    private func readTokenizer() async -> (any TokenizerProvider)? {
        inferenceService.tokenizer
    }
}
