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

    /// Drives the backend through an entire tool-dispatch loop for one queued request.
    func run(
        token: GenerationRequestToken,
        messages: [StructuredMessage],
        systemPrompt: String?,
        config: GenerationConfig
    ) async throws {
        // First-time-only wiring: make sure the registry has a schema
        // validator installed so tools with non-trivial parameter schemas
        // get argument validation without requiring the host to know about
        // the `JSONSchemaValidating` protocol.
        if let registry = toolRegistry, registry.validator == nil {
            registry.validator = JSONSchemaValidator()
        }

        let currentMessages = messages
        // `toolAwareHistory` is maintained in parallel for tool-call turns.
        // Seeded lazily on the first tool dispatch so plain-text turns keep
        // using the classic `setConversationHistory` path and existing
        // backends that don't know about tool-aware history see no change.
        var toolAwareHistory: [ToolAwareHistoryEntry]?
        var lastCallSignature: (toolName: String, arguments: String)?
        var toolResultByteTotal = 0
        var iterations = 0
        let limit = max(1, config.maxToolIterations)

        while true {
            iterations += 1
            if iterations > limit {
                Log.inference.warning(
                    "GenerationQueue: tool-dispatch loop hit maxToolIterations=\(limit, privacy: .public); terminating."
                )
                yieldEvent(.toolLoopLimitReached(iterations: limit))
                return
            }

            if let toolAwareHistory,
               let receiver = currentBackend() as? ToolCallingHistoryReceiver {
                receiver.setToolAwareHistory(toolAwareHistory)
            }

            let stream = try generateWithConfig(currentMessages, systemPrompt, config)

            var dispatchedInThisTurn: [(ToolCall, ToolResult)] = []

            for try await event in stream.events {
                guard !Task.isCancelled else { return }

                await pauseWhileThermalCritical(token)
                guard !Task.isCancelled else { return }

                switch event {
                case .toolCall(let call) where toolRegistry != nil:
                    yieldEvent(.toolCall(call))

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
                        for: call,
                        lastCallSignature: lastCallSignature,
                        dispatchedInThisTurn: dispatchedInThisTurn,
                        toolResultByteTotal: toolResultByteTotal
                    )

                    toolResultByteTotal += result.content.utf8.count
                    lastCallSignature = (toolName: call.toolName, arguments: call.arguments)
                    dispatchedInThisTurn.append((call, result))

                    yieldEvent(.toolResult(result))

                    let dispatchDurationNs = DispatchTime.now().uptimeNanoseconds &- dispatchStart.uptimeNanoseconds
                    let dispatchDurationMs = Int(dispatchDurationNs / 1_000_000)
                    yieldEvent(
                        .toolDispatchCompleted(
                            callId: call.id,
                            durationMs: dispatchDurationMs,
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

                    if result.errorKind == .cancelled {
                        return
                    }

                    if toolResultByteTotal >= Self.toolResultByteBudget {
                        return
                    }

                default:
                    yieldEvent(event)
                }
            }

            if dispatchedInThisTurn.isEmpty {
                return
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
        }
    }

    private func dispatchResult(
        for call: ToolCall,
        lastCallSignature: (toolName: String, arguments: String)?,
        dispatchedInThisTurn: [(ToolCall, ToolResult)],
        toolResultByteTotal: Int
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
            return await registry.dispatch(call)
        }

        switch await toolApprovalGate.approve(call) {
        case .approved:
            return await registry.dispatch(call)
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
}
