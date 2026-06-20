import Foundation

/// Drives backend tool-call turns for a queued generation request while keeping
/// `GenerationQueue` focused on queue and lifecycle coordination.
@MainActor
struct GenerationToolDispatchLoop {
    /// Upper bound on cumulative bytes of tool-result content that can be fed
    /// back into a single generation request.
    private static let toolResultByteBudget: Int = 512 * 1024

    let toolRegistry: ToolRegistry?
    let toolApprovalGate: any ToolApprovalGate
    let currentBackend: () -> InferenceBackend?
    let generateWithConfig: ([StructuredMessage], String?, GenerationConfig) throws -> GenerationStream
    let yieldEvent: (GenerationEvent) -> Void
    let pauseWhileThermalCritical: (GenerationRequestToken) async -> Void
    /// Session-aware handoff detector. `nil` when the executor has not
    /// wired multi-agent handoffs (e.g. host apps that never construct
    /// agents on the session). Returning `.handoff(...)` causes the loop
    /// to emit ``GenerationEvent/handoffRequested(_:)`` and skip dispatch
    /// for this call; returning `.regular(_)` (or being unset) falls
    /// through to the normal dispatch path.
    let handoffDetector: ((ToolCall) -> HandoffDetectionResult)?
    /// Optional pre-tool-use hook. When non-nil the dispatch loop invokes
    /// this closure BEFORE dispatching each tool call. The hook may
    /// sanitize the call's arguments (returned via ``PreToolUseOutcome/proceed(arguments:)``)
    /// or block the dispatch entirely (``PreToolUseOutcome/block(reason:)``).
    /// Wired from the runtime via ``InferenceService/setPreToolUseHook(_:)``;
    /// `nil` (the default) preserves the legacy direct-dispatch shape.
    let preToolUseHook: PreToolUseHook?

    init(
        toolRegistry: ToolRegistry?,
        toolApprovalGate: any ToolApprovalGate,
        currentBackend: @escaping () -> InferenceBackend?,
        generateWithConfig: @escaping ([StructuredMessage], String?, GenerationConfig) throws -> GenerationStream,
        yieldEvent: @escaping (GenerationEvent) -> Void,
        pauseWhileThermalCritical: @escaping (GenerationRequestToken) async -> Void,
        handoffDetector: ((ToolCall) -> HandoffDetectionResult)? = nil,
        preToolUseHook: PreToolUseHook? = nil
    ) {
        self.toolRegistry = toolRegistry
        self.toolApprovalGate = toolApprovalGate
        self.currentBackend = currentBackend
        self.generateWithConfig = generateWithConfig
        self.yieldEvent = yieldEvent
        self.pauseWhileThermalCritical = pauseWhileThermalCritical
        self.handoffDetector = handoffDetector
        self.preToolUseHook = preToolUseHook
    }

    /// Drives the backend through an entire tool-dispatch loop for one queued request.
    ///
    /// Emits exactly one terminal ``GenerationEvent/generationCompleted(_:)`` as
    /// the last event before returning, classifying why the turn ended. On a
    /// thrown error the completion is emitted (`.error`) before the error
    /// propagates so consumers still see a single in-band "finished" signal
    /// ahead of the stream's throwing finish.
    func run(
        token: GenerationRequestToken,
        messages: [StructuredMessage],
        systemPrompt: String?,
        config: GenerationConfig
    ) async throws {
        do {
            let reason = try await runLoop(
                token: token,
                messages: messages,
                systemPrompt: systemPrompt,
                config: config
            )
            yieldEvent(.generationCompleted(GenerationCompletion(reason: reason)))
        } catch is CancellationError {
            yieldEvent(.generationCompleted(GenerationCompletion(reason: .cancelled)))
            throw CancellationError()
        } catch {
            yieldEvent(.generationCompleted(GenerationCompletion(reason: .error)))
            throw error
        }
    }

    /// Runs the dispatch loop and returns the reason the turn ended. Throwing
    /// paths are classified by the caller (``run(token:messages:systemPrompt:config:)``).
    private func runLoop(
        token: GenerationRequestToken,
        messages: [StructuredMessage],
        systemPrompt: String?,
        config: GenerationConfig
    ) async throws -> GenerationCompletion.Reason {
        // First-time-only wiring: make sure the registry has a schema
        // validator installed so tools with non-trivial parameter schemas
        // get argument validation without requiring the host to know about
        // the `JSONSchemaValidating` protocol.
        if let registry = toolRegistry, registry.validator == nil {
            registry.validator = JSONSchemaValidator()
        }

        // Grows across iterations so each regeneration sees the prior turn's
        // tool calls and results. Cloud backends receive that history through
        // the structured `ToolCallingHistoryReceiver` wire (below); local
        // prompt-template backends — which are *not* tool-aware receivers —
        // instead need the tool turns threaded back into the structured
        // messages so `PromptRenderer` re-renders them natively. Without this,
        // a templated backend re-rendered the *identical* original prompt every
        // iteration and never saw a single tool result (#1909, Ring 2).
        var currentMessages = messages
        // `toolAwareHistory` is maintained in parallel for tool-call turns.
        // Seeded lazily on the first tool dispatch so plain-text turns keep
        // using the classic `setConversationHistory` path and existing
        // backends that don't know about tool-aware history see no change.
        var toolAwareHistory: [ToolAwareHistoryEntry]?
        var lastCallSignature: (toolName: String, arguments: String)?
        var toolResultByteTotal = 0
        var iterations = 0
        let limit = max(1, config.maxToolIterations)

        // Run-level token ceiling (sibling to `maxToolIterations`). Accumulates
        // the prompt + completion tokens each generation reports via its
        // terminal `.usage` event and aborts at the iteration boundary once the
        // running total reaches the configured budget. `nil` / `<= 0` disables
        // the ceiling. Checked at the boundary — not mid-stream — because cloud
        // backends only report usage at end-of-generation (#1939 item 3).
        let runTokenBudget: Int? = {
            guard let max = config.maxRunTokens, max > 0 else { return nil }
            return max
        }()
        var cumulativeRunTokens = 0

        while true {
            iterations += 1
            if iterations > limit {
                Log.inference.warning(
                    "GenerationQueue: tool-dispatch loop hit maxToolIterations=\(limit, privacy: .public); terminating."
                )
                yieldEvent(.toolIterationLimitExceeded(iterations: limit))
                return .toolIterationLimit
            }

            // Run-level token ceiling: check at the iteration boundary, before
            // dispatching another generation. The previous iteration's terminal
            // `.usage` has already been folded into `cumulativeRunTokens` by the
            // time we loop back here.
            if let runTokenBudget, cumulativeRunTokens >= runTokenBudget {
                Log.inference.warning(
                    "GenerationQueue: tool-dispatch loop hit maxRunTokens budget (used=\(cumulativeRunTokens, privacy: .public) limit=\(runTokenBudget, privacy: .public)); terminating."
                )
                yieldEvent(.runTokenBudgetExceeded(tokensUsed: cumulativeRunTokens, limit: runTokenBudget))
                return .runTokenBudget
            }

            if let toolAwareHistory,
               let receiver = currentBackend() as? ToolCallingHistoryReceiver {
                receiver.setToolAwareHistory(toolAwareHistory)
            }

            let stream = try generateWithConfig(currentMessages, systemPrompt, config)

            var dispatchedInThisTurn: [(ToolCall, ToolResult)] = []
            var consumer = GenerationStreamConsumer(loopDetectionEnabled: false)

            for try await event in stream.events {
                guard !Task.isCancelled else { return .cancelled }

                await pauseWhileThermalCritical(token)
                guard !Task.isCancelled else { return .cancelled }

                switch consumer.handle(event) {
                case .dispatchToolCall(let call):
                    // Multi-agent handoff short-circuit. When the executor
                    // wired a session-aware detector and the call resolves
                    // to a known `transfer_to_<agent>` synthetic tool, skip
                    // regular dispatch and emit the typed handoff event for
                    // the runtime to consume (system-prompt swap, boundary
                    // message injection). Handoff detection runs even when
                    // no ``ToolRegistry`` is wired — the synthetic transfer
                    // tools are advertised by ``HandoffToolSource`` directly
                    // and never round-trip through the registry.
                    if let detector = handoffDetector,
                       case .handoff(let handoff) = detector(call) {
                        yieldEvent(.handoffRequested(handoff))
                        // The loop is single-shot for handoffs: the runtime
                        // re-derives the system prompt on the next turn from
                        // session.activeAgentID, so there's nothing left to
                        // do in this turn's tool-dispatch path.
                        return .stop
                    }
                    // No handoff (or detector unset / non-handoff result) —
                    // fall through to regular dispatch when the registry is
                    // wired. Without a registry the event is forwarded
                    // verbatim and the host consumes the tool call upstream.
                    guard toolRegistry != nil else {
                        yieldEvent(event)
                        continue
                    }
                    yieldEvent(.toolCall(call))

                    // Pre-tool-use hook: give the host a synchronous chance
                    // to sanitize the JSON arguments or block the call. A
                    // block synthesises a typed permissionDenied result fed
                    // back to the model so the dispatch loop keeps turning.
                    var effectiveCall = call
                    if let preToolUseHook {
                        let outcome = await preToolUseHook(call.toolName, call.arguments, nil)
                        switch outcome {
                        case .block(let reason):
                            let denied = ToolResult(
                                callId: call.id,
                                content: "Tool call blocked by pre-tool-use hook: \(reason ?? "no reason given")",
                                errorKind: .permissionDenied
                            )
                            // Keep the dispatch event stream symmetric: consumers
                            // pair every `.toolDispatchStarted` with a
                            // `.toolDispatchCompleted`. A hook-blocked call still
                            // emits the pair (with the denied error kind) so those
                            // consumers don't desync waiting for a completion that
                            // never arrives.
                            yieldEvent(.toolDispatchStarted(callId: call.id, name: call.toolName, attempt: 1))
                            yieldEvent(.toolResult(denied))
                            yieldEvent(
                                .toolDispatchCompleted(
                                    callId: call.id,
                                    durationMilliseconds: 0,
                                    errorKind: .permissionDenied
                                )
                            )
                            continue
                        case .proceed(let sanitized):
                            if sanitized != call.arguments {
                                effectiveCall = ToolCall(
                                    id: call.id,
                                    toolName: call.toolName,
                                    arguments: sanitized
                                )
                            }
                        }
                    }

                    let dispatchAttempt = 1
                    let dispatchStart = DispatchTime.now()
                    yieldEvent(.toolDispatchStarted(callId: call.id, name: call.toolName, attempt: dispatchAttempt))
                    Log.inference.info(
                        "tool_dispatch_started call_id=\(call.id, privacy: .public) name=\(call.toolName, privacy: .public) attempt=\(dispatchAttempt, privacy: .public)"
                    )
                    GenerationQueue.toolDispatchLogHook?(
                        "tool_dispatch_started",
                        [
                            "call_id": call.id,
                            "name": call.toolName,
                            "attempt": "\(dispatchAttempt)"
                        ]
                    )

                    let result = await dispatchResult(
                        for: effectiveCall,
                        lastCallSignature: lastCallSignature,
                        dispatchedInThisTurn: dispatchedInThisTurn,
                        toolResultByteTotal: toolResultByteTotal,
                        onProgress: { progress in
                            yieldEvent(.toolProgress(progress))
                        }
                    )

                    let dispatchDurationNs = DispatchTime.now().uptimeNanoseconds &- dispatchStart.uptimeNanoseconds
                    let dispatchDurationMs = Int(dispatchDurationNs / 1_000_000)

                    if result.errorKind == .cancelled {
                        // Cancellation completes the dispatch pair but is not
                        // recorded as turn history — the loop unwinds immediately.
                        yieldEvent(.toolResult(result))
                        yieldEvent(
                            .toolDispatchCompleted(
                                callId: call.id,
                                durationMilliseconds: dispatchDurationMs,
                                errorKind: result.errorKind
                            )
                        )
                        return .cancelled
                    }

                    // Byte-budget guard, checked BEFORE persisting/yielding the
                    // result as a successful completion. A result that pushes the
                    // cumulative total over budget must not be recorded as success
                    // or threaded into the next turn's history — instead substitute
                    // a synthetic permanent error so the model sees the truncation
                    // and the loop stops without ever logging the oversized payload
                    // as a `.toolDispatchCompleted` success.
                    let prospectiveTotal = toolResultByteTotal + result.content.utf8.count
                    if prospectiveTotal >= Self.toolResultByteBudget {
                        Log.inference.warning(
                            "GenerationQueue: tool-result byte budget (\(Self.toolResultByteBudget, privacy: .public)) exceeded by '\(call.toolName, privacy: .public)' (\(prospectiveTotal, privacy: .public) bytes); dropping oversized result and terminating loop."
                        )
                        let overflow = ToolResult(
                            callId: call.id,
                            content: "tool result exceeded the cumulative byte budget and was dropped",
                            errorKind: .permanent
                        )
                        yieldEvent(.toolResult(overflow))
                        yieldEvent(
                            .toolDispatchCompleted(
                                callId: call.id,
                                durationMilliseconds: dispatchDurationMs,
                                errorKind: .permanent
                            )
                        )
                        return .stop
                    }

                    toolResultByteTotal = prospectiveTotal
                    lastCallSignature = (toolName: effectiveCall.toolName, arguments: effectiveCall.arguments)
                    dispatchedInThisTurn.append((effectiveCall, result))

                    yieldEvent(.toolResult(result))
                    yieldEvent(
                        .toolDispatchCompleted(
                            callId: call.id,
                            durationMilliseconds: dispatchDurationMs,
                            errorKind: result.errorKind
                        )
                    )
                    Log.inference.info(
                        "tool_dispatch_completed call_id=\(call.id, privacy: .public) duration_ms=\(dispatchDurationMs, privacy: .public) error_kind=\(result.errorKind?.rawValue ?? "none", privacy: .public)"
                    )
                    GenerationQueue.toolDispatchLogHook?(
                        "tool_dispatch_completed",
                        [
                            "call_id": call.id,
                            "duration_ms": "\(dispatchDurationMs)",
                            "error_kind": result.errorKind?.rawValue ?? "none"
                        ]
                    )

                // Token usage lands once per generation (terminal `.usage`
                // event). Fold it into the run-level accumulator so the
                // iteration-boundary ceiling can abort the turn, then forward
                // the raw event verbatim for upstream consumers (metrics, UI).
                case .recordUsage(let prompt, let completion):
                    cumulativeRunTokens += prompt + completion
                    yieldEvent(event)

                // Passthrough actions: the dispatch loop owns only tool-call
                // dispatch; every other action maps back to its raw event,
                // forwarded verbatim for upstream consumers to handle. Listed
                // explicitly (no `default:`) so a new StreamAction case forces
                // a compile error here instead of silently falling through.
                case .appendText,
                     .recordToolApproval,
                     .appendThinkingText,
                     .finalizeThinking,
                     .recordThinkingSignature,
                     .appendToolResult,
                     .toolIterationLimitExceeded,
                     .runTokenBudgetExceeded,
                     .recordHandoff,
                     .generationCompleted,
                     .ignore:
                    yieldEvent(event)
                }
            }

            if dispatchedInThisTurn.isEmpty {
                return .stop
            }

            var nextHistory = toolAwareHistory ?? currentMessages.map {
                ToolAwareHistoryEntry(role: $0.role, content: $0.textContent)
            }
            nextHistory.append(
                ToolAwareHistoryEntry(
                    role: "assistant",
                    content: "",
                    toolCalls: dispatchedInThisTurn.map(\.0)
                )
            )
            for (call, result) in dispatchedInThisTurn {
                nextHistory.append(
                    ToolAwareHistoryEntry(
                        role: "tool",
                        content: result.content,
                        toolCallId: call.id
                    )
                )
            }
            toolAwareHistory = nextHistory

            // Local prompt-template backends do not consume the tool-aware wire
            // history — they re-render `currentMessages` through `PromptRenderer`.
            // Thread the just-dispatched tool turn into that structured history so
            // the next regeneration shows the model its own call and the result
            // in the template's native format (#1909, Ring 2). Cloud backends
            // (tool-aware receivers) already got this via `setToolAwareHistory`,
            // so skip them to avoid duplicating the turn.
            if (currentBackend() as? ToolCallingHistoryReceiver) == nil {
                currentMessages.append(
                    StructuredMessage(
                        role: "assistant",
                        parts: dispatchedInThisTurn.map { MessagePart.toolCall($0.0) }
                    )
                )
                for (_, result) in dispatchedInThisTurn {
                    currentMessages.append(
                        StructuredMessage(role: "tool", parts: [.toolResult(result)])
                    )
                }
            }
        }
    }

    private func dispatchResult(
        for call: ToolCall,
        lastCallSignature: (toolName: String, arguments: String)?,
        dispatchedInThisTurn: [(ToolCall, ToolResult)],
        toolResultByteTotal: Int,
        onProgress: (ToolProgressEvent) -> Void
    ) async -> ToolResult {
        guard let registry = toolRegistry else {
            return ToolResult(callId: call.id, content: "", errorKind: .permanent)
        }

        if let prev = lastCallSignature,
           prev.toolName == call.toolName,
           prev.arguments == call.arguments {
            Log.inference.warning(
                "GenerationQueue: tool '\(call.toolName, privacy: .public)' called twice in a row with identical arguments; short-circuiting to previous result."
            )
            let prevContent = dispatchedInThisTurn.last?.1.content ?? ""
            return ToolResult(
                callId: call.id,
                content: "tool already called this turn with identical arguments — previous result was: \(prevContent)",
                errorKind: .permanent
            )
        }

        if toolResultByteTotal >= Self.toolResultByteBudget {
            Log.inference.warning(
                "GenerationQueue: tool-result byte budget (\(Self.toolResultByteBudget, privacy: .public)) exhausted before dispatching '\(call.toolName, privacy: .public)'; terminating loop."
            )
            return ToolResult(
                callId: call.id,
                content: "tool result budget exhausted",
                errorKind: .permanent
            )
        }

        if registry.requiresApproval(toolName: call.toolName) == false {
            // Auto-approved: the tool is not gated, so it clears approval
            // implicitly. Emit the approval signal before execution.
            yieldEvent(.toolCallApproved(callId: call.id))
            return await dispatchStreaming(call, through: registry, onProgress: onProgress)
        }

        switch await toolApprovalGate.approve(call) {
        case .approved:
            yieldEvent(.toolCallApproved(callId: call.id))
            return await dispatchStreaming(call, through: registry, onProgress: onProgress)
        case .denied(let reason):
            Log.inference.info(
                "GenerationQueue: tool '\(call.toolName, privacy: .public)' denied by ToolApprovalGate"
            )
            return ToolResult(
                callId: call.id,
                content: reason ?? "user denied tool execution",
                errorKind: .permissionDenied
            )
        }
    }

    private func dispatchStreaming(
        _ call: ToolCall,
        through registry: ToolRegistry,
        onProgress: (ToolProgressEvent) -> Void
    ) async -> ToolResult {
        var terminalResult: ToolResult?
        for await event in registry.dispatchStreaming(call) {
            switch event {
            case .progress(let message, let fraction):
                onProgress(
                    ToolProgressEvent(
                        callId: call.id,
                        name: call.toolName,
                        message: message,
                        fraction: fraction
                    )
                )

            case .completed(let result):
                terminalResult = result
            }
        }

        if Task.isCancelled {
            return ToolResult(
                callId: call.id,
                content: "cancelled by user",
                errorKind: .cancelled
            )
        }
        return terminalResult ?? ToolResult(
            callId: call.id,
            content: "tool stream finished without a terminal result",
            errorKind: .permanent
        )
    }
}
