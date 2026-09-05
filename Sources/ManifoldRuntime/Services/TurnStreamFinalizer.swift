import Foundation
import ManifoldInference

// MARK: - TurnStreamFinalizer
//
// Issue #1957 Tier 4 / architecture Priority 3: the three hand-rolled
// finalization branches in `runGenerationTurn` (stream-failed / cancelled /
// happy-path) each implemented persist→emit→completeOutcome slightly
// differently, which is exactly how Priority-1-class asymmetries survive
// review. This type owns the stream-drain state machine and a **single**
// finalization path parameterized by ``TerminalKind``, so a finalization
// edge case is testable with a struct literal instead of a full
// ConversationRuntime + mock backend + in-memory store.

/// Owns stream drain + terminal finalization for a generation turn.
///
/// `package`, not `public`, per docs/API-DESIGN.md's default.
package struct TurnStreamFinalizer: Sendable {
    private let persistence: any TurnPersistencePort
    private let inferenceService: InferenceService
    private let registry: InFlightStreamRegistry
    private let events: TurnEventEmitter
    private let emptyResponseObserver: (@Sendable (ConversationRuntime.EmptyResponseDiagnostic) -> Void)?
    private let generationHooks: [any GenerationHook]
    private let compression: TurnCompressionCoordinator
    private let usageStore: (any UsageStore)?
    private let hookTimeout: Duration
    private let toolDispatch: SessionToolDispatchBinder

    init(
        persistence: any TurnPersistencePort,
        inferenceService: InferenceService,
        registry: InFlightStreamRegistry,
        events: TurnEventEmitter,
        emptyResponseObserver: (@Sendable (ConversationRuntime.EmptyResponseDiagnostic) -> Void)?,
        generationHooks: [any GenerationHook],
        compression: TurnCompressionCoordinator,
        usageStore: (any UsageStore)?,
        hookTimeout: Duration,
        toolDispatch: SessionToolDispatchBinder
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.registry = registry
        self.events = events
        self.emptyResponseObserver = emptyResponseObserver
        self.generationHooks = generationHooks
        self.compression = compression
        self.usageStore = usageStore
        self.hookTimeout = hookTimeout
        self.toolDispatch = toolDispatch
    }

    // MARK: Terminal kind

    /// Why the stream ended. Drives the single finalization path — the
    /// branch differences that used to be hand-rolled live here as data.
    package enum TerminalKind: Sendable, Equatable {
        /// Mid-stream inference failure. `timedOut` selects
        /// ``FinishReason/timedOut`` over ``FinishReason/stop``.
        case failed(error: ConversationError, timedOut: Bool)
        /// Caller cancelled (registry or `CancellationError`).
        case cancelled
        /// No visible text, tool content, or thinking content.
        case empty
        /// Normal completion with content to persist.
        case completed

        package var finishReason: FinishReason {
            switch self {
            case .failed(_, timedOut: true): return .timedOut
            case .failed: return .stop
            case .cancelled: return .cancelled
            case .empty: return .empty
            case .completed: return .stop
            }
        }

        package var streamError: ConversationError? {
            switch self {
            case .failed(let error, _): return error
            case .cancelled, .empty, .completed: return nil
            }
        }

        /// Whether a persist failure aborts the path (failed/completed) or
        /// falls through to still emit streamFinished (cancelled).
        package var persistFailureIsFatal: Bool {
            switch self {
            case .failed, .completed: return true
            case .cancelled, .empty: return false
            }
        }

        /// Post-turn effects (touchSession, usage, hooks, compression) run
        /// only on the happy path — never on cancel/error/empty.
        package var runsPostTurnEffects: Bool {
            if case .completed = self { return true }
            return false
        }

        /// `.afterGeneration` fires on empty (with `""`) and completed; not
        /// on cancel/error (parity with the pre-split branches).
        package var emitsAfterGeneration: Bool {
            switch self {
            case .empty, .completed: return true
            case .failed, .cancelled: return false
            }
        }
    }

    // MARK: Finalize input / result

    /// Everything the single finalization path needs. Constructible from a
    /// struct literal in unit tests — no ConversationRuntime required.
    package struct FinalizeInput: Sendable {
        package var sessionID: UUID
        package var handle: ConversationStreamHandle
        package var assistantMessage: ChatMessage
        package var visibleText: String
        package var hasToolContent: Bool
        package var hasThinkingContent: Bool
        package var usage: (promptTokens: Int, completionTokens: Int, cachedInputTokens: Int?, cacheWriteTokens: Int?)?
        package var kind: TerminalKind
        package var turnContext: TurnContext
        package var turnHookRegistry: HookRegistry?
        package var outcomeCompletion: ConversationTurnOutcomeCompletion?
        /// The turn's fully composed wire system prompt (base + prompt
        /// slots / RAG) — threaded to post-turn compression so it budgets
        /// against what was actually sent, not `ChatSession.systemPrompt`
        /// (#1957). `nil` defaults to `.unresolved` at the compression call
        /// site, i.e. legacy session-store fallback.
        package var composedSystemPrompt: String?

        package init(
            sessionID: UUID,
            handle: ConversationStreamHandle,
            assistantMessage: ChatMessage,
            visibleText: String,
            hasToolContent: Bool = false,
            hasThinkingContent: Bool = false,
            usage: (promptTokens: Int, completionTokens: Int, cachedInputTokens: Int?, cacheWriteTokens: Int?)? = nil,
            kind: TerminalKind,
            turnContext: TurnContext,
            turnHookRegistry: HookRegistry? = nil,
            outcomeCompletion: ConversationTurnOutcomeCompletion? = nil,
            composedSystemPrompt: String? = nil
        ) {
            self.sessionID = sessionID
            self.handle = handle
            self.assistantMessage = assistantMessage
            self.visibleText = visibleText
            self.hasToolContent = hasToolContent
            self.hasThinkingContent = hasThinkingContent
            self.usage = usage
            self.kind = kind
            self.turnContext = turnContext
            self.turnHookRegistry = turnHookRegistry
            self.outcomeCompletion = outcomeCompletion
            self.composedSystemPrompt = composedSystemPrompt
        }

        /// True when the assistant turn carries anything worth persisting
        /// (visible text, tool parts, or thinking content).
        package var hasPersistableContent: Bool {
            !visibleText.isEmpty || hasToolContent || hasThinkingContent
        }
    }

    /// Outcome of ``finalize(_:)`` — primarily for unit tests asserting
    /// whether the message was persisted and which terminal reason fired.
    package struct FinalizeResult: Sendable {
        package let reason: FinishReason
        package let didPersist: Bool
        package let persistenceError: ConversationError?
        package let assistantMessage: ChatMessage?
    }

    // MARK: Drain outcome

    /// Mutable state produced by stream drain, handed to finalization.
    package struct DrainOutcome: Sendable {
        package var accumulator: GenerationStreamAccumulator
        package var assistantMessage: ChatMessage
        package var sessionRecord: ChatSession?
        package var streamFailed: ConversationError?
        package var timedOut: Bool
    }

    // MARK: Full post-enqueue path

    /// Drain → flush → unregister → capture usage → finalize. The executor
    /// calls this after a successful `enqueueAsync` + `streamStarted`.
    func run(
        sessionID: UUID,
        prepared: TurnPreparation.PreparedTurn,
        token: InferenceService.GenerationRequestToken,
        stream: GenerationStream,
        config: TurnConfig,
        handle: ConversationStreamHandle,
        outcomeCompletion: ConversationTurnOutcomeCompletion?
    ) async {
        var sessionRecord = prepared.sessionRecord
        var assistantMessage = prepared.assistantMessage
        let assistantID = assistantMessage.id

        let drained = await drain(
            sessionID: sessionID,
            token: token,
            stream: stream,
            config: config,
            handle: handle,
            assistantMessage: &assistantMessage,
            sessionRecord: &sessionRecord
        )

        // Tool dispatch is complete once the stream has drained — the dispatch
        // loop runs on the producer side as we consume events. Unregister the
        // session-scoped executors now so the shared registry doesn't carry a
        // stale ``ChatSession`` binding into the next turn (#1606). All
        // remaining exit paths below are post-stream, so this is the single
        // cleanup point alongside the enqueue-failure path above.
        await toolDispatch.unregisterSessionToolExecutors(prepared.registeredSessionToolNames)

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
        let usage: (promptTokens: Int, completionTokens: Int, cachedInputTokens: Int?, cacheWriteTokens: Int?)?
        if let recordedUsage = drained.accumulator.tokenUsage {
            usage = recordedUsage
        } else if let fallback = await readLastTokenUsage() {
            // The fallback reads `TokenUsageProvider.lastUsage`, a
            // prompt/completion-only tracker predating cache-token
            // accounting — no cache fields available on this path.
            usage = (fallback.promptTokens, fallback.completionTokens, nil, nil)
        } else {
            usage = nil
        }
        if let usage {
            assistantMessage.promptTokens = usage.promptTokens
            assistantMessage.completionTokens = usage.completionTokens
            events.emit(.tokenUsageRecorded(
                messageID: assistantID,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens
            ))
        }

        // True when the assistant message already carries tool-related content
        // parts, even if no visible text tokens arrived. Used below so all
        // three terminal paths (error, cancellation, normal) persist tool-only
        // turns rather than silently dropping them.
        let hasToolContent = assistantMessage.hasToolContent

        // True when the model emitted reasoning/thinking content this turn,
        // even with no visible text and no tool calls. Without this, a
        // thinking-only turn fell through `isEmptyResponse` (which only
        // tracks visible tokens) and was silently dropped below — a real
        // behavioral bug once thinking content parts are persisted (#2281).
        let hasThinkingContent = drained.accumulator.hasThinkingContent

        let kind: TerminalKind
        if cancelled {
            kind = .cancelled
        } else if let streamFailed = drained.streamFailed {
            kind = .failed(error: streamFailed, timedOut: drained.timedOut)
        } else if drained.accumulator.isEmptyResponse && !hasToolContent && !hasThinkingContent {
            kind = .empty
        } else {
            kind = .completed
        }

        _ = await finalize(FinalizeInput(
            sessionID: sessionID,
            handle: handle,
            assistantMessage: assistantMessage,
            visibleText: drained.accumulator.visibleText,
            hasToolContent: hasToolContent,
            hasThinkingContent: hasThinkingContent,
            usage: usage,
            kind: kind,
            turnContext: prepared.turnContext,
            turnHookRegistry: prepared.turnHookRegistry,
            outcomeCompletion: outcomeCompletion,
            composedSystemPrompt: prepared.composedSystemPrompt
        ))
    }

    // MARK: Single finalization path

    /// Persist → emit → completeOutcome, parameterized by ``TerminalKind``.
    /// Directly unit-testable with a ``FinalizeInput`` literal.
    @discardableResult
    package func finalize(_ input: FinalizeInput) async -> FinalizeResult {
        var assistantMessage = input.assistantMessage
        let assistantID = assistantMessage.id
        let reason = input.kind.finishReason
        let visibleText = input.visibleText

        // Empty path: drop the assistant message. No persistence; emit
        // terminal events and return. Issue #965: log a warning with backend
        // + sessionID so a future regression is observable instead of silent.
        if case .empty = input.kind {
            let backendName = await readActiveBackendName()
            Log.inference.warning(
                "ConversationRuntime: dropping empty assistant turn (sessionID=\(input.sessionID, privacy: .private), backend=\(backendName ?? "nil", privacy: .public))"
            )
            emptyResponseObserver?(ConversationRuntime.EmptyResponseDiagnostic(
                sessionID: input.sessionID,
                backendName: backendName
            ))
            events.emit(.streamFinished(messageID: assistantID, reason: reason))
            events.emit(.afterGeneration(messageID: assistantID, finalText: ""))
            await completeOutcome(
                input.outcomeCompletion,
                sessionID: input.sessionID,
                handle: input.handle,
                assistantMessageID: assistantID,
                reason: reason,
                finalText: "",
                promptTokens: input.usage?.promptTokens,
                completionTokens: input.usage?.completionTokens
            )
            return FinalizeResult(
                reason: reason,
                didPersist: false,
                persistenceError: nil,
                assistantMessage: nil
            )
        }

        // Decide whether to persist. Empty is handled above; failed/cancelled
        // persist only when there is content; completed always has content
        // (otherwise it would have classified as empty).
        let shouldPersist: Bool = {
            switch input.kind {
            case .completed:
                return true
            case .failed, .cancelled:
                return input.hasPersistableContent
            case .empty:
                return false
            }
        }()

        var didPersist = false
        var persistenceError: ConversationError?
        var persistedMessage: ChatMessage?

        if shouldPersist {
            writeFinalContent(visibleText, into: &assistantMessage)
            do {
                try await persistence.insertMessage(assistantMessage)
                events.emit(.messageInserted(assistantMessage))
                didPersist = true
                persistedMessage = assistantMessage
            } catch {
                let error = ConversationError.persistence(error)
                persistenceError = error
                events.emit(.errorRaised(error))

                if input.kind.persistFailureIsFatal {
                    // failed / completed: emit stream error (if any), finish,
                    // complete with the *persistence* error, and return.
                    if let streamError = input.kind.streamError {
                        events.emit(.errorRaised(streamError))
                    }
                    events.emit(.streamFinished(messageID: assistantID, reason: reason))
                    await completeOutcome(
                        input.outcomeCompletion,
                        sessionID: input.sessionID,
                        handle: input.handle,
                        assistantMessageID: assistantID,
                        reason: reason,
                        error: error,
                        finalText: visibleText,
                        promptTokens: input.usage?.promptTokens,
                        completionTokens: input.usage?.completionTokens
                    )
                    return FinalizeResult(
                        reason: reason,
                        didPersist: false,
                        persistenceError: error,
                        assistantMessage: nil
                    )
                }
                // cancelled: fall through — the cancellation outcome is the
                // load-bearing signal even when the partial save failed.
            }
        }

        // Stream-failure path emits the inference error after a successful
        // (or skipped) persist.
        if let streamError = input.kind.streamError {
            events.emit(.errorRaised(streamError))
        }

        events.emit(.streamFinished(messageID: assistantID, reason: reason))

        if input.kind.emitsAfterGeneration {
            events.emit(.afterGeneration(messageID: assistantID, finalText: visibleText))
        }

        // completeOutcome error: stream error on failed path (persist
        // already returned above if it failed fatally); nil on cancel/
        // completed. Cancelled always reports error: nil even when the
        // partial save failed (parity with the pre-split branch).
        let outcomeError: ConversationError? = {
            switch input.kind {
            case .failed(let error, _): return error
            case .cancelled, .empty, .completed: return nil
            }
        }()

        // Outcome assistant message: successful persist uses the stored row.
        // Cancel + persistable content always passes the in-memory message
        // even when insert failed — pre-split parity for classification
        // (tool/thinking-only cancel must not flip to cancelledEmpty),
        // ChatGenerationCoordinator fallback merge, and ResumableRunDriver
        // step.messageID. didPersist stays false when insert failed.
        let outcomeAssistantMessage: ChatMessage? = {
            if didPersist { return persistedMessage }
            if case .cancelled = input.kind, input.hasPersistableContent {
                return assistantMessage
            }
            return nil
        }()

        // Settle the turn *before* resolving the awaited outcome. Post-turn
        // effects touch the SwiftData store (touchSession, usage recording);
        // if the outcome resolved first, a caller that awaits `handle.outcome`
        // and then releases its ModelContainer — exactly what the runtime's
        // in-memory integration tests do at teardown — would leave these
        // fetches racing the store's dealloc (SIGTRAP in fetchSwiftDataSession
        // vs NSSQLCore dealloc). completeOutcome emits nothing to the event
        // stream, so moving it after the effects leaves event ordering — the
        // characterization oracle — unchanged; it only guarantees that
        // `await outcome` means the turn is fully settled and the store is
        // safe to release. compression/hooks are no-ops unless configured, so
        // the common path adds no user-facing latency.
        if input.kind.runsPostTurnEffects {
            await runPostTurnEffects(
                sessionID: input.sessionID,
                assistantMessage: assistantMessage,
                usage: input.usage,
                turnContext: input.turnContext,
                turnHookRegistry: input.turnHookRegistry,
                composedSystemPrompt: input.composedSystemPrompt
            )
        }

        await completeOutcome(
            input.outcomeCompletion,
            sessionID: input.sessionID,
            handle: input.handle,
            assistantMessageID: assistantID,
            assistantMessage: outcomeAssistantMessage,
            reason: reason,
            error: outcomeError,
            finalText: visibleText,
            promptTokens: input.usage?.promptTokens,
            completionTokens: input.usage?.completionTokens
        )

        return FinalizeResult(
            reason: reason,
            didPersist: didPersist,
            persistenceError: persistenceError,
            assistantMessage: outcomeAssistantMessage
        )
    }

    // MARK: Stream drain

    private func drain(
        sessionID: UUID,
        token: InferenceService.GenerationRequestToken,
        stream: GenerationStream,
        config: TurnConfig,
        handle: ConversationStreamHandle,
        assistantMessage: inout ChatMessage,
        sessionRecord: inout ChatSession?
    ) async -> DrainOutcome {
        let assistantID = assistantMessage.id

        // Drain the stream, mirroring GenerationQueue's four features:
        //   (a) token batcher — coalesce per-token events into UI-cadenced batches
        //   (b) thinking-block disclosure — track/batch reasoning tokens and emit
        //       thinkingStarted / thinkingUpdated / thinkingFinalized events
        //   (c) tool dispatch — persist toolCall + toolResult content parts and
        //       emit toolCallRequested / toolCallCompleted events
        //   (d) loop detection — stop the stream when RepetitionDetector fires
        var accumulator = GenerationStreamAccumulator()
        var streamFailed: ConversationError?

        var consumer = GenerationStreamConsumer(
            loopDetectionEnabled: config.loopDetectionEnabled,
            repetitionGuard: config.repetitionGuard
        )
        var batcher = StreamingTokenBatcher(
            interval: config.streamingUpdateInterval,
            maxBufferedCharacters: config.streamingBatchCharacterLimit
        )
        var thinkingBatcher = StreamingTokenBatcher(
            interval: config.thinkingStreamingUpdateInterval,
            maxBufferedCharacters: config.thinkingStreamingBatchCharacterLimit
        )
        var thinkingDisplayed = ""

        // Whether the turn's progress/stall timeout fired. When set, the
        // terminal path below reports `.timedOut` instead of the generic
        // `.stop` failure reason so a consumer can tell an unresponsive
        // backend apart from a real inference error.
        var timedOut = false

        // Progress/stall timeout (opt-in via `config.progressStallTimeout`).
        // Reuse `GenerationStream`'s existing idle-stream primitive — the same
        // one the structured-output reliability envelope uses — rather than a
        // bespoke monitor: wrapping the queue's event stream makes iteration
        // throw `InferenceError.idleTimeout` when no event arrives within the
        // window. When the timeout is nil we iterate the queue's stream
        // directly, keeping the default path byte-identical.
        let timeoutWrapper: GenerationStream? = config.progressStallTimeout.map {
            GenerationStream(stream.events, idleTimeout: $0)
        }
        let drainEvents = timeoutWrapper?.events ?? stream.events

        do {
            eventLoop: for try await event in drainEvents {
                let cancelled = await isCancelled(handle: handle)
                if cancelled { break }

                switch consumer.handle(event) {
                case .appendText(let text):
                    accumulator.recordTextToken()
                    if let batch = batcher.append(text, now: ContinuousClock.now) {
                        accumulator.appendVisibleText(batch)
                        events.emit(.tokenEmitted(messageID: assistantID, delta: batch))
                        if consumer.shouldStopForLoop(content: accumulator.visibleText) {
                            await inferenceService.cancelAsync(token)
                            events.emit(.loopDetected(messageID: assistantID))
                            break eventLoop
                        }
                    }

                case .appendThinkingText(let text):
                    if accumulator.appendThinkingText(text) {
                        events.emit(.thinkingStarted(messageID: assistantID))
                    }
                    if let batch = thinkingBatcher.append(text, now: ContinuousClock.now) {
                        thinkingDisplayed += batch
                        events.emit(.thinkingUpdated(messageID: assistantID, partialText: thinkingDisplayed))
                        if consumer.shouldStopForLoop(content: accumulator.currentThinkingText) {
                            await inferenceService.cancelAsync(token)
                            events.emit(.loopDetected(messageID: assistantID))
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
                        assistantMessage.contentParts.append(.thinking(block.text, signature: block.signature))
                        events.emit(.thinkingFinalized(messageID: assistantID, text: block.text, signature: block.signature))
                    }

                case .dispatchToolCall(let call):
                    assistantMessage.contentParts.append(.toolCall(call))
                    events.emit(.toolCallRequested(call))

                case .recordToolApproval(let callId):
                    events.emit(.toolCallApproved(callId))

                case .appendToolResult(let result):
                    assistantMessage.contentParts.append(.toolResult(result))
                    events.emit(.toolCallCompleted(result.callId, result))

                case .toolIterationLimitExceeded(let iterations):
                    events.emit(.errorRaised(.inference(
                        InferenceError.inferenceFailure("Tool-call loop stopped after \(iterations) iterations.")
                    )))

                case .runTokenBudgetExceeded(let tokensUsed, let limit):
                    events.emit(.errorRaised(.inference(
                        InferenceError.inferenceFailure("Tool-call loop stopped after reaching the run-level token budget (used \(tokensUsed) of \(limit) tokens).")
                    )))

                case .recordUsage(let prompt, let completion, let cachedInputTokens, let cacheWriteTokens):
                    accumulator.recordUsage(
                        prompt: prompt,
                        completion: completion,
                        cachedInputTokens: cachedInputTokens,
                        cacheWriteTokens: cacheWriteTokens
                    )

                case .recordHandoff(let handoff):
                    // Persist the active-agent swap and emit the typed
                    // ConversationEvent so adapters can render a handoff
                    // chip. The next turn re-derives the system prompt
                    // from the new activeAgentID and prepends the boundary
                    // message into structuredHistory.
                    if var current = sessionRecord {
                        let previousID = current.activeAgentID
                        current.activeAgentID = handoff.targetAgentID
                        // Use the narrow single-column write rather than
                        // rewriting the whole record: a concurrent edit to
                        // another session field (title, agents, updatedAt) must
                        // not be clobbered by this stale snapshot mid-stream.
                        _ = await persistence.setActiveAgent(
                            sessionID: current.id,
                            agentID: handoff.targetAgentID
                        )
                        sessionRecord = current
                        events.emit(.agentHandoff(from: previousID, to: handoff.targetAgentID))

                        // Persist the transfer call itself (#2378). The
                        // handoff short-circuits normal tool dispatch (the
                        // GenerationToolDispatchLoop never yields
                        // `.dispatchToolCall` for it), so without this the
                        // assistant message carries no content parts, the
                        // terminal-kind classification below sees no visible
                        // text/tool/thinking content, and the whole turn is
                        // dropped as `.empty` — silently discarding the
                        // agent switch's only visible trace. A synthesized
                        // success `ToolResult` keeps the tool-invocation UI
                        // in its `.completed` state instead of stuck
                        // `.running` (no result will ever arrive through the
                        // normal dispatch path) — appending only the call
                        // would instead make `TranscriptHealer` inject an
                        // `errorKind: .cancelled` "interrupted before
                        // completion" result on next load, misreporting a
                        // handoff that actually succeeded as a failed one.
                        // Mirror the `.dispatchToolCall` / `.appendToolResult`
                        // shape exactly (content parts + matching events) so
                        // the live-streaming UI (`ChatGenerationCoordinator`'s
                        // `.toolCallRequested`/`.toolCallCompleted` handlers)
                        // renders the handoff the same way it renders any
                        // other tool call, not just after a reload.
                        //
                        // `sourceCall` is nil only for an `AgentHandoff` built
                        // through the 2-argument source-compat initializer
                        // (see `Agent.swift`) — `HandoffDetector.classify`,
                        // the sole production producer, always supplies it.
                        // Without it there is nothing to persist, so this
                        // turn falls back to the pre-#2378 behaviour (agent
                        // swap only).
                        if let sourceCall = handoff.sourceCall {
                            assistantMessage.contentParts.append(.toolCall(sourceCall))
                            events.emit(.toolCallRequested(sourceCall))
                            let targetName = current.agents.first(where: { $0.id == handoff.targetAgentID })?.name
                                ?? "the next agent"
                            let result = ToolResult(
                                callId: sourceCall.id,
                                content: "Handed off to \(targetName)."
                            )
                            assistantMessage.contentParts.append(.toolResult(result))
                            events.emit(.toolCallCompleted(result.callId, result))
                        }
                    } else {
                        Log.inference.warning(
                            "ConversationTurnExecutor: received handoff event but session record was unavailable; agent swap dropped"
                        )
                    }

                case .generationCompleted:
                    // Terminal "response finished" signal from the
                    // orchestrator. The executor already finalizes the
                    // assistant turn (persistence, `.responseCompleted`) when
                    // the stream loop exits below, so there is no additional
                    // timeline work to do here — the event exists so UI /
                    // accessibility consumers that drive announcements off the
                    // raw event stream get a single in-band "finished" signal.
                    break

                case .ignore:
                    break
                }
            }
        } catch let InferenceError.idleTimeout(timeout) where config.progressStallTimeout != nil {
            // Progress/stall timeout fired: the backend went unresponsive for
            // longer than `config.progressStallTimeout`. Cancel the in-flight
            // backend work so it doesn't keep running after we stop consuming,
            // then classify this as a distinct timed-out outcome (not a generic
            // inference failure). A user cancel that raced ahead still wins —
            // the `isCancelled` check below re-derives the terminal reason.
            //
            // The `where` clause scopes the `.timedOut` reclassification to
            // turns that actually armed this executor's stall wrapper. An
            // `InferenceError.idleTimeout` surfacing from a deeper layer (a
            // cloud backend's own stream-idle policy) on a turn with no
            // `progressStallTimeout` falls through to the generic catch below
            // and stays a plain `.inference` failure — the turn-level
            // timed-out outcome means "the turn's own stall knob fired",
            // nothing broader.
            await inferenceService.cancelAsync(token)
            if await isCancelled(handle: handle) {
                streamFailed = .cancelled
            } else {
                timedOut = true
                streamFailed = .inference(InferenceError.idleTimeout(timeout))
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
            accumulator.appendVisibleText(batch)
            events.emit(.tokenEmitted(messageID: assistantID, delta: batch))
        }

        // Finalize an unclosed thinking block — the model may not emit a closing
        // event if generation is cut short.
        if accumulator.hasOpenThinkingBlock {
            _ = thinkingBatcher.flush(now: ContinuousClock.now)
            if let block = accumulator.finalizeThinking() {
                assistantMessage.contentParts.append(.thinking(block.text, signature: block.signature))
                events.emit(.thinkingFinalized(messageID: assistantID, text: block.text, signature: block.signature))
            }
        }

        return DrainOutcome(
            accumulator: accumulator,
            assistantMessage: assistantMessage,
            sessionRecord: sessionRecord,
            streamFailed: streamFailed,
            timedOut: timedOut
        )
    }

    // MARK: Post-turn effects (happy path only)

    private func runPostTurnEffects(
        sessionID: UUID,
        assistantMessage: ChatMessage,
        usage: (promptTokens: Int, completionTokens: Int, cachedInputTokens: Int?, cacheWriteTokens: Int?)?,
        turnContext: TurnContext,
        turnHookRegistry: HookRegistry?,
        composedSystemPrompt: String?
    ) async {
        // Touch session timestamp so the sidebar reflects the assistant
        // turn's recency (parity with ChatViewModel's behaviour).
        if await persistence.touchSession(sessionID: sessionID) == false {
            events.emit(.sessionTouchFailed(sessionID: sessionID))
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
                completionTokens: usage.completionTokens,
                cachedInputTokens: usage.cachedInputTokens,
                cacheWriteTokens: usage.cacheWriteTokens
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
        if !generationHooks.isEmpty || turnHookRegistry != nil {
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

            // B.2 unified hook seam: the same completed-turn payload also
            // flows through the HookRegistry so hosts standardised on the
            // registry (preToolUse/preCompact) get postGeneration without
            // adopting the separate `GenerationHook` protocol. Observational
            // like `.preCompact` — `block` is not honoured, there is no
            // mutation channel once the turn has committed.
            if let turnHookRegistry {
                let input = HookInput(
                    event: .postGeneration,
                    sessionID: sessionID,
                    completedTurn: completedTurn
                )
                let output = await turnHookRegistry.run(input)
                events.emit(.hookFired(event: "postGeneration", sessionID: sessionID))
                if output.block {
                    Log.inference.warning(
                        "postGeneration hook returned block:true — block is not honoured for postGeneration; the turn has already completed."
                    )
                }
            }
        }

        // Post-turn compression: runs after the terminal `streamFinished` /
        // `afterGeneration`, including the preCompact hook (observational in
        // v1 — block:true is ignored). Failures log and continue; the
        // generation has already succeeded. Thread the turn's actual
        // composed wire prompt so the budget matches what was sent (#1957).
        // See ``TurnCompressionCoordinator``.
        await compression.compressAfterTurnIfNeeded(
            sessionID: sessionID,
            promptTokens: usage?.promptTokens,
            wireSystemPrompt: .wire(composedSystemPrompt),
            hookRegistry: turnHookRegistry
        )
    }

    // MARK: Helpers

    private func writeFinalContent(_ text: String, into message: inout ChatMessage) {
        message.contentParts.removeAll {
            if case .text = $0 { return true }
            return false
        }
        if !text.isEmpty {
            message.contentParts.append(.text(text))
        }
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

    private func isCancelled(handle: ConversationStreamHandle) async -> Bool {
        if Task.isCancelled { return true }
        return await registry.isCancelled(handle)
    }

    /// Requests cancellation when `operation` exceeds `duration`, then joins
    /// the direct hook invocation before returning. Swift task cancellation is
    /// cooperative: an operation that ignores it keeps the turn unsettled
    /// until it returns. The hook is not forcibly killed.
    private func withHookTimeout(
        _ duration: Duration,
        label: String,
        operation: @escaping @Sendable () async -> Void
    ) async {
        let deadlineElapsed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: duration)
                    Log.inference.warning(
                        "GenerationHook '\(label, privacy: .public)' exceeded \(duration, privacy: .public); requested cancellation and is awaiting the hook's return"
                    )
                    return true
                } catch {
                    // Timer was cancelled because operation finished first.
                    return false
                }
            }
            // The first completion chooses whether the deadline elapsed. The
            // task-group scope still joins the direct hook invocation after
            // cancellation, preserving outcome/store-settlement ordering.
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if deadlineElapsed {
            Log.inference.info(
                "GenerationHook '\(label, privacy: .public)' returned after the cancellation request; turn settlement may continue"
            )
        }
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
}

// ConversationError equatable for TerminalKind — only used in tests via
// pattern matching on cases; the associated Error is not Equatable, so
// TerminalKind.Equatable compares the case + timedOut flag only for .failed.
extension TurnStreamFinalizer.TerminalKind {
    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.failed(_, let lt), .failed(_, let rt)): return lt == rt
        case (.cancelled, .cancelled): return true
        case (.empty, .empty): return true
        case (.completed, .completed): return true
        default: return false
        }
    }
}
