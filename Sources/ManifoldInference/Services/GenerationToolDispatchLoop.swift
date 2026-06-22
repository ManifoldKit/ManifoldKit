import Foundation

/// Drives backend tool-call turns for a queued generation request while keeping
/// `GenerationQueue` focused on queue and lifecycle coordination.
@MainActor
struct GenerationToolDispatchLoop {
    /// Upper bound on cumulative bytes of tool-result content that can be fed
    /// back into a single generation request.
    private static let toolResultByteBudget: Int = 512 * 1024

    /// Bounded retry policy for transient tool failures.
    ///
    /// The dispatch loop retries the *same* tool call (identical arguments) with
    /// exponential backoff when an executor returns a retry-safe error kind
    /// (``ToolResult/ErrorKind/transient``, ``ToolResult/ErrorKind/rateLimited``,
    /// ``ToolResult/ErrorKind/timeout``). Permanent failures, cancellation, and
    /// successful results never retry. Defaults are conservative so an existing
    /// caller sees at most a couple of extra dispatches on a genuinely flaky
    /// tool, not an unbounded loop.
    struct RetryPolicy: Sendable {
        /// Total attempts per call, including the first. `1` disables retry.
        /// Clamped to `>= 1` so a misconfigured `0` cannot drop the first
        /// dispatch entirely.
        let maxAttempts: Int
        /// Base delay before the *first* retry. Each subsequent retry doubles
        /// it (`base`, `base * 2`, `base * 4`, …). `.zero` retries immediately.
        let baseDelay: Duration

        init(maxAttempts: Int, baseDelay: Duration) {
            self.maxAttempts = max(1, maxAttempts)
            self.baseDelay = baseDelay
        }

        /// Conservative default: up to 3 attempts (2 retries) with a 200ms base
        /// delay, doubling to 400ms before the final attempt.
        static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(200))

        /// Error kinds that the loop treats as retry-safe. Aligned with the
        /// ``ToolResult/ErrorKind`` doc comments: `.transient` and
        /// `.rateLimited` are explicitly retry-after-backoff, and `.timeout`
        /// "may be retried" — so we include it. Everything else (permanent,
        /// permissionDenied, invalidArguments, notFound, unknownTool,
        /// cancelled, unknown, and the `nil` success case) is non-retriable.
        static func isRetriable(_ kind: ToolResult.ErrorKind?) -> Bool {
            switch kind {
            case .transient, .rateLimited, .timeout:
                return true
            case .invalidArguments, .permissionDenied, .notFound, .cancelled,
                 .permanent, .unknownTool, .unknown, .none:
                return false
            }
        }
    }

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
    /// Bounded retry policy for transient tool failures. Defaults to
    /// ``RetryPolicy/default``.
    let retryPolicy: RetryPolicy

    init(
        toolRegistry: ToolRegistry?,
        toolApprovalGate: any ToolApprovalGate,
        currentBackend: @escaping () -> InferenceBackend?,
        generateWithConfig: @escaping ([StructuredMessage], String?, GenerationConfig) throws -> GenerationStream,
        yieldEvent: @escaping (GenerationEvent) -> Void,
        pauseWhileThermalCritical: @escaping (GenerationRequestToken) async -> Void,
        handoffDetector: ((ToolCall) -> HandoffDetectionResult)? = nil,
        preToolUseHook: PreToolUseHook? = nil,
        retryPolicy: RetryPolicy = .default
    ) {
        self.toolRegistry = toolRegistry
        self.toolApprovalGate = toolApprovalGate
        self.currentBackend = currentBackend
        self.generateWithConfig = generateWithConfig
        self.yieldEvent = yieldEvent
        self.pauseWhileThermalCritical = pauseWhileThermalCritical
        self.handoffDetector = handoffDetector
        self.preToolUseHook = preToolUseHook
        self.retryPolicy = retryPolicy
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

    // MARK: - Per-turn dispatch bookkeeping

    /// Outcome of dispatching a single buffered tool call. Carries enough state
    /// for the caller to re-impose receipt order, fold byte budgets, and decide
    /// whether the loop should terminate.
    private struct CallOutcome: Sendable {
        /// The (possibly hook-sanitized) call that was dispatched.
        let effectiveCall: ToolCall
        let result: ToolResult
        let durationMilliseconds: Int
        /// True when the pre-tool-use hook blocked the call: the dispatch pair
        /// is still emitted but the call never reached the registry, so it is
        /// excluded from history and from the duplicate-call signature.
        let wasBlocked: Bool
        /// Attempts actually made (including the first). Surfaced as the
        /// `attempt` field on the terminal `.toolDispatchStarted` event.
        let attempts: Int
    }

    /// A tool call buffered during stream iteration, awaiting dispatch once the
    /// turn's stream has fully drained.
    private struct PendingCall {
        let call: ToolCall
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

            // Tool calls are buffered during stream iteration and dispatched
            // only after the turn's stream has fully drained. Buffering lets the
            // loop inspect *all* of a turn's calls at once so it can choose
            // parallel dispatch when every targeted executor opts in — while
            // still preserving receipt order in the recorded history. Cloud
            // parallel-tool backends emit every call in one turn before the
            // terminal `.usage`, so nothing is lost by deferring dispatch to the
            // end of the stream.
            var pendingCalls: [PendingCall] = []
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
                    pendingCalls.append(PendingCall(call: call))

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

            guard !pendingCalls.isEmpty else {
                return .stop
            }

            // Dispatch the buffered calls — parallel when every targeted
            // executor opts in, sequential otherwise. `dispatchedInThisTurn`
            // is returned in *receipt order* regardless of the dispatch shape
            // (`ParallelToolCallOrderingTests`), and `terminalReason` is
            // non-nil when a guard (cancellation / byte budget) demanded the
            // loop stop after this turn.
            let turn = await dispatchTurn(
                pendingCalls: pendingCalls,
                lastCallSignature: lastCallSignature,
                toolResultByteTotal: toolResultByteTotal
            )

            toolResultByteTotal = turn.toolResultByteTotal
            lastCallSignature = turn.lastCallSignature

            if let terminalReason = turn.terminalReason {
                return terminalReason
            }

            let dispatchedInThisTurn = turn.dispatchedInThisTurn
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

    /// Aggregated result of dispatching a single turn's worth of buffered calls.
    private struct TurnDispatchResult {
        /// Calls + results in *receipt order*, ready to thread into history.
        /// Excludes hook-blocked calls (which are not turn history).
        let dispatchedInThisTurn: [(ToolCall, ToolResult)]
        /// Non-nil when a guard requires the loop to terminate after this turn.
        let terminalReason: GenerationCompletion.Reason?
        let toolResultByteTotal: Int
        let lastCallSignature: (toolName: String, arguments: String)?
    }

    /// Dispatches every buffered call for a turn, choosing parallel or
    /// sequential execution and re-imposing receipt order on the results.
    ///
    /// Parallel dispatch (`withTaskGroup`) is used only when there is more than
    /// one call AND every targeted executor reports
    /// ``ToolExecutor/supportsConcurrentDispatch``. The duplicate-call
    /// short-circuit and per-result byte-budget guards are evaluated in receipt
    /// order *after* the group completes, so a parallel batch produces the same
    /// history and termination behavior as the sequential path.
    private func dispatchTurn(
        pendingCalls: [PendingCall],
        lastCallSignature: (toolName: String, arguments: String)?,
        toolResultByteTotal: Int
    ) async -> TurnDispatchResult {
        let calls = pendingCalls.map(\.call)

        // Decide the dispatch shape up front. Parallel requires (a) more than
        // one call and (b) every targeted executor to opt in. A missing
        // executor (unknown tool) reports `false`, so an unknown-tool batch
        // falls back to the sequential path — its synthesised `unknownTool`
        // result is identical either way.
        let canDispatchInParallel: Bool = {
            guard calls.count > 1, let registry = toolRegistry else { return false }
            return calls.allSatisfy { call in
                registry.executor(for: call.toolName)?.supportsConcurrentDispatch == true
            }
        }()

        let outcomes: [CallOutcome]
        if canDispatchInParallel {
            outcomes = await dispatchParallel(calls)
        } else {
            outcomes = await dispatchSequential(
                calls,
                lastCallSignature: lastCallSignature
            )
        }

        // Re-impose receipt order and apply the per-result guards (cancellation,
        // duplicate-call short-circuit, byte budget) in that order. This is the
        // single place history and termination are decided, so the parallel and
        // sequential paths converge to identical behavior here.
        var dispatchedInThisTurn: [(ToolCall, ToolResult)] = []
        var runningByteTotal = toolResultByteTotal
        var runningSignature = lastCallSignature

        for outcome in outcomes {
            let call = outcome.effectiveCall
            let result = outcome.result

            yieldEvent(.toolDispatchStarted(callId: call.id, name: call.toolName, attempt: outcome.attempts))
            Log.inference.info(
                "tool_dispatch_started call_id=\(call.id, privacy: .public) name=\(call.toolName, privacy: .public) attempt=\(outcome.attempts, privacy: .public)"
            )
            GenerationQueue.toolDispatchLogHook?(
                "tool_dispatch_started",
                [
                    "call_id": call.id,
                    "name": call.toolName,
                    "attempt": "\(outcome.attempts)"
                ]
            )

            if result.errorKind == .cancelled {
                // Cancellation completes the dispatch pair but is not recorded
                // as turn history — the loop unwinds immediately.
                yieldEvent(.toolResult(result))
                yieldEvent(
                    .toolDispatchCompleted(
                        callId: call.id,
                        durationMilliseconds: outcome.durationMilliseconds,
                        errorKind: result.errorKind
                    )
                )
                return TurnDispatchResult(
                    dispatchedInThisTurn: dispatchedInThisTurn,
                    terminalReason: .cancelled,
                    toolResultByteTotal: runningByteTotal,
                    lastCallSignature: runningSignature
                )
            }

            if outcome.wasBlocked {
                // Hook-blocked: emit the matched dispatch pair (with the denied
                // error kind) so consumers don't desync, but exclude the call
                // from history and from the duplicate-call signature.
                yieldEvent(.toolResult(result))
                yieldEvent(
                    .toolDispatchCompleted(
                        callId: call.id,
                        durationMilliseconds: outcome.durationMilliseconds,
                        errorKind: result.errorKind
                    )
                )
                continue
            }

            // Byte-budget guard, checked BEFORE persisting/yielding the result
            // as a successful completion. A result that pushes the cumulative
            // total over budget must not be recorded as success or threaded
            // into the next turn's history — instead substitute a synthetic
            // permanent error so the model sees the truncation and the loop
            // stops without ever logging the oversized payload as a
            // `.toolDispatchCompleted` success.
            let prospectiveTotal = runningByteTotal + result.content.utf8.count
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
                        durationMilliseconds: outcome.durationMilliseconds,
                        errorKind: .permanent
                    )
                )
                return TurnDispatchResult(
                    dispatchedInThisTurn: dispatchedInThisTurn,
                    terminalReason: .stop,
                    toolResultByteTotal: runningByteTotal,
                    lastCallSignature: runningSignature
                )
            }

            runningByteTotal = prospectiveTotal
            runningSignature = (toolName: call.toolName, arguments: call.arguments)
            dispatchedInThisTurn.append((call, result))

            yieldEvent(.toolResult(result))
            yieldEvent(
                .toolDispatchCompleted(
                    callId: call.id,
                    durationMilliseconds: outcome.durationMilliseconds,
                    errorKind: result.errorKind
                )
            )
            Log.inference.info(
                "tool_dispatch_completed call_id=\(call.id, privacy: .public) duration_ms=\(outcome.durationMilliseconds, privacy: .public) error_kind=\(result.errorKind?.rawValue ?? "none", privacy: .public)"
            )
            GenerationQueue.toolDispatchLogHook?(
                "tool_dispatch_completed",
                [
                    "call_id": call.id,
                    "duration_ms": "\(outcome.durationMilliseconds)",
                    "error_kind": result.errorKind?.rawValue ?? "none"
                ]
            )
        }

        return TurnDispatchResult(
            dispatchedInThisTurn: dispatchedInThisTurn,
            terminalReason: nil,
            toolResultByteTotal: runningByteTotal,
            lastCallSignature: runningSignature
        )
    }

    /// Sequential dispatch: one call after another, threading the running
    /// duplicate-call signature so a repeated `(name, args)` short-circuits.
    private func dispatchSequential(
        _ calls: [ToolCall],
        lastCallSignature: (toolName: String, arguments: String)?
    ) async -> [CallOutcome] {
        var outcomes: [CallOutcome] = []
        // Track the running signature across this turn's calls so a call that
        // repeats the immediately-preceding one short-circuits — matching the
        // pre-buffering inline behavior where `lastCallSignature` advanced after
        // every dispatch.
        var runningSignature = lastCallSignature
        // The duplicate short-circuit needs the previous successful result's
        // content to echo back. Track the last dispatched outcome's content.
        var previousContent = ""

        for call in calls {
            let outcome = await dispatchOne(
                call,
                duplicateOf: runningSignature,
                previousContent: previousContent
            )
            outcomes.append(outcome)
            if !outcome.wasBlocked {
                runningSignature = (toolName: outcome.effectiveCall.toolName, arguments: outcome.effectiveCall.arguments)
                previousContent = outcome.result.content
            }
        }
        return outcomes
    }

    /// Parallel dispatch. Every call runs concurrently in its own child Task;
    /// results are awaited in receipt order so the returned array index-aligns
    /// with `calls`. The duplicate-call short-circuit is intentionally NOT
    /// applied across a parallel batch — concurrent-safe executors are
    /// stateless, so two identical calls in one batch are independent reads, not
    /// a runaway loop. Cross-turn duplicate detection still runs in
    /// `dispatchTurn` against the prior turn's signature.
    private func dispatchParallel(_ calls: [ToolCall]) async -> [CallOutcome] {
        // Run each call's dispatch concurrently in its own child Task, then
        // await them in receipt order. Using an array of `Task` (rather than
        // `withTaskGroup`) sidesteps a Swift 6.2 region-isolation checker bug
        // that rejects `group.addTask { @MainActor in … }` closures invoking a
        // `@MainActor` method. `Task { @MainActor in … }` inherits the current
        // main-actor isolation (it is NOT `Task.detached`), so concurrency is
        // preserved while every body runs on the main actor — matching the
        // sequential path's isolation exactly.
        var tasks: [Task<CallOutcome, Never>] = []
        for call in calls {
            let task = Task { @MainActor in
                await dispatchOne(call, duplicateOf: nil, previousContent: "")
            }
            tasks.append(task)
        }

        var gathered: [CallOutcome] = []
        for task in tasks {
            gathered.append(await task.value)
        }
        return gathered
    }

    /// Dispatches one call: pre-tool-use hook, approval, then execution with
    /// bounded transient-error retry. Returns a ``CallOutcome`` describing the
    /// terminal result and the number of attempts made.
    ///
    /// `duplicateOf` / `previousContent` carry the running duplicate-call
    /// signature for the sequential path; the parallel path passes `nil`.
    private func dispatchOne(
        _ call: ToolCall,
        duplicateOf lastCallSignature: (toolName: String, arguments: String)?,
        previousContent: String
    ) async -> CallOutcome {
        // Pre-tool-use hook: give the host a synchronous chance to sanitize the
        // JSON arguments or block the call. A block synthesises a typed
        // permissionDenied result fed back to the model so the loop keeps
        // turning.
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
                return CallOutcome(
                    effectiveCall: call,
                    result: denied,
                    durationMilliseconds: 0,
                    wasBlocked: true,
                    attempts: 1
                )
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

        let dispatchStart = DispatchTime.now()
        let (result, attempts) = await dispatchWithRetry(
            effectiveCall,
            lastCallSignature: lastCallSignature,
            previousContent: previousContent
        )
        let dispatchDurationNs = DispatchTime.now().uptimeNanoseconds &- dispatchStart.uptimeNanoseconds
        let dispatchDurationMs = Int(dispatchDurationNs / 1_000_000)

        return CallOutcome(
            effectiveCall: effectiveCall,
            result: result,
            durationMilliseconds: dispatchDurationMs,
            wasBlocked: false,
            attempts: attempts
        )
    }

    /// Dispatches a single call, retrying with bounded exponential backoff while
    /// the executor returns a retry-safe error kind. Returns the terminal result
    /// and the number of attempts made (1 when no retry was needed).
    ///
    /// Cancellation is never retried: a `.cancelled` result, or an observed task
    /// cancellation, ends the retry loop immediately so the user's stop is
    /// honored promptly. The byte budget is enforced by the caller after this
    /// returns, so retries cannot smuggle oversized payloads past the ceiling —
    /// each attempt produces a single terminal result that the budget guard
    /// still sees.
    private func dispatchWithRetry(
        _ call: ToolCall,
        lastCallSignature: (toolName: String, arguments: String)?,
        previousContent: String
    ) async -> (result: ToolResult, attempts: Int) {
        var attempt = 0
        var lastResult = ToolResult(callId: call.id, content: "", errorKind: .permanent)

        while attempt < retryPolicy.maxAttempts {
            attempt += 1

            if Task.isCancelled {
                return (
                    ToolResult(callId: call.id, content: "cancelled by user", errorKind: .cancelled),
                    attempt
                )
            }

            let result = await dispatchResult(
                for: call,
                lastCallSignature: lastCallSignature,
                previousContent: previousContent,
                onProgress: { progress in
                    yieldEvent(.toolProgress(progress))
                }
            )
            lastResult = result

            // Non-retriable (success, permanent, cancelled, permission, …):
            // done. The duplicate short-circuit returns `.permanent`, so a
            // repeated call resolves on the first attempt without retrying.
            guard RetryPolicy.isRetriable(result.errorKind), attempt < retryPolicy.maxAttempts else {
                return (result, attempt)
            }

            // Retry-safe failure with attempts remaining: back off, then retry
            // the identical call. Delay doubles each retry (`base`, `2·base`, …).
            let shift = attempt - 1
            let delay = retryPolicy.baseDelay * (1 << shift)
            Log.inference.info(
                "tool_dispatch_retry call_id=\(call.id, privacy: .public) name=\(call.toolName, privacy: .public) error_kind=\(result.errorKind?.rawValue ?? "none", privacy: .public) attempt=\(attempt, privacy: .public) next_attempt=\(attempt + 1, privacy: .public)"
            )
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Sleep throws only on cancellation — honor the stop by
                    // returning a cancelled result rather than retrying.
                    Log.inference.info(
                        "tool_dispatch_retry_cancelled call_id=\(call.id, privacy: .public)"
                    )
                    return (
                        ToolResult(callId: call.id, content: "cancelled by user", errorKind: .cancelled),
                        attempt
                    )
                }
            }
        }

        return (lastResult, attempt)
    }

    private func dispatchResult(
        for call: ToolCall,
        lastCallSignature: (toolName: String, arguments: String)?,
        previousContent: String,
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
            return ToolResult(
                callId: call.id,
                content: "tool already called this turn with identical arguments — previous result was: \(previousContent)",
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
