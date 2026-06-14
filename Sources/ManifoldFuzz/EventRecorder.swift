import Foundation
import ManifoldInference

/// Consumes a `GenerationStream`, recording every event plus derived buffers.
///
/// Drives the stream itself (calls `for try await event in stream.events`),
/// so callers must not iterate the stream separately. Returns a fully populated
/// capture once the stream terminates.
public struct EventRecorder: Sendable {

    public init() {}

    public struct Capture: Sendable {
        public var events: [RunRecord.EventSnapshot]
        public var raw: String
        public var thinkingRaw: String
        public var thinkingParts: [String]
        public var thinkingCompleteCount: Int
        public var phase: String
        public var error: String?
        public var firstTokenMs: Double?
        public var totalMs: Double
        public var peakBytes: UInt64?
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var stopReason: String
        /// Full `.toolCall` payloads, preserved for `ToolCallValidityDetector`.
        public var toolCalls: [ToolCall]
        /// Full `.toolResult` payloads.
        public var toolResults: [ToolResult]

        public init(
            events: [RunRecord.EventSnapshot],
            raw: String,
            thinkingRaw: String,
            thinkingParts: [String],
            thinkingCompleteCount: Int,
            phase: String,
            error: String?,
            firstTokenMs: Double?,
            totalMs: Double,
            peakBytes: UInt64?,
            promptTokens: Int?,
            completionTokens: Int?,
            stopReason: String,
            toolCalls: [ToolCall] = [],
            toolResults: [ToolResult] = []
        ) {
            self.events = events
            self.raw = raw
            self.thinkingRaw = thinkingRaw
            self.thinkingParts = thinkingParts
            self.thinkingCompleteCount = thinkingCompleteCount
            self.phase = phase
            self.error = error
            self.firstTokenMs = firstTokenMs
            self.totalMs = totalMs
            self.peakBytes = peakBytes
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.stopReason = stopReason
            self.toolCalls = toolCalls
            self.toolResults = toolResults
        }
    }

    /// - Parameter maxOutputTokens: the cap requested in `GenerationConfig`, used to
    ///   classify the stop reason as `maxTokens` when the final usage report meets/exceeds it.
    public func consume(_ stream: GenerationStream, maxOutputTokens: Int? = nil) async -> Capture {
        let start = ContinuousClock.now
        var events: [RunRecord.EventSnapshot] = []
        var raw = ""
        var thinkingRaw = ""
        var thinkingBuffer = ""
        var thinkingParts: [String] = []
        var thinkingCompleteCount = 0
        var firstTokenAt: ContinuousClock.Instant?
        var peakBytes: UInt64? = AppMemoryUsage.currentBytes()
        var promptTokens: Int?
        var completionTokens: Int?
        var phase = "done"
        var errorString: String?
        var toolCalls: [ToolCall] = []
        var toolResults: [ToolResult] = []

        func memoryTick() {
            if let now = AppMemoryUsage.currentBytes() {
                peakBytes = max(peakBytes ?? now, now)
            }
        }

        do {
            for try await event in stream.events {
                let t = start.duration(to: ContinuousClock.now).seconds
                switch event {
                case .prefillProgress(let tokensProcessed, let tokensTotal, let tokensPerSecond):
                    events.append(.init(
                        t: t,
                        kind: "prefillProgress",
                        v: "\(tokensProcessed)/\(tokensTotal)@\(tokensPerSecond)"
                    ))
                case .token(let text):
                    if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
                    raw += text
                    events.append(.init(t: t, kind: "token", v: text))
                case .thinkingToken(let text):
                    if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
                    thinkingRaw += text
                    thinkingBuffer += text
                    events.append(.init(t: t, kind: "thinkingToken", v: text))
                case .thinkingCompleted:
                    thinkingCompleteCount += 1
                    if !thinkingBuffer.isEmpty {
                        thinkingParts.append(thinkingBuffer)
                        thinkingBuffer = ""
                    }
                    events.append(.init(t: t, kind: "thinkingCompleted", v: nil))
                case .usage(let usage):
                    promptTokens = usage.promptTokens
                    completionTokens = usage.completionTokens
                    events.append(.init(t: t, kind: "usage", v: "\(usage.promptTokens)/\(usage.completionTokens)"))
                case .toolCall(let call):
                    toolCalls.append(call)
                    events.append(.init(t: t, kind: "toolCall", v: call.toolName))
                case .toolResult(let result):
                    toolResults.append(result)
                    events.append(.init(t: t, kind: "toolResult", v: result.callId))
                case .toolIterationLimitExceeded(let iterations):
                    events.append(.init(t: t, kind: "toolIterationLimitExceeded", v: "\(iterations)"))
                case .kvCacheReuse(let tokens):
                    events.append(.init(t: t, kind: "kvCacheReuse", v: "\(tokens)"))
                case .throttleDiagnostic(let reason):
                    events.append(.init(t: t, kind: "throttleDiagnostic", v: reason))
                case .thinkingSignature(let signature):
                    // Provider-issued opaque token for multi-turn replay
                    // (Anthropic extended thinking). Surface in the trace so
                    // fuzz scenarios can pin its presence/absence without
                    // affecting reasoning text accumulation.
                    events.append(.init(t: t, kind: "thinkingSignature", v: signature))
                case .toolCallStart(let callId, let name):
                    events.append(.init(t: t, kind: "toolCallStart", v: "\(callId):\(name)"))
                case .toolCallArgumentsDelta(let callId, let textDelta):
                    events.append(.init(t: t, kind: "toolCallArgumentsDelta", v: "\(callId):\(textDelta)"))
                case .toolProgress(let progress):
                    let fraction = progress.fraction.map { String($0) } ?? "nil"
                    events.append(.init(t: t, kind: "toolProgress", v: "\(progress.callId):\(progress.message):\(fraction)"))
                case .toolDispatchStarted(let callId, let name, let attempt):
                    events.append(.init(t: t, kind: "toolDispatchStarted", v: "\(callId):\(name):\(attempt)"))
                case .toolCallApproved(let callId):
                    events.append(.init(t: t, kind: "toolCallApproved", v: callId))
                case .toolDispatchCompleted(let callId, let durationMilliseconds, let errorKind):
                    events.append(.init(t: t, kind: "toolDispatchCompleted", v: "\(callId):\(durationMilliseconds):\(errorKind?.rawValue ?? "none")"))
                case .handoffRequested(let handoff):
                    // Multi-agent handoffs only surface through the runtime
                    // executor; deterministic fuzz replays never observe
                    // them but the case stays exhaustive for growth.
                    events.append(.init(t: t, kind: "handoffRequested", v: handoff.targetAgentID.uuidString))
                }
                memoryTick()
            }
        } catch {
            phase = "failed"
            errorString = String(describing: error)
        }

        // Flush any unterminated thinking buffer so that a throw mid-thinking-block
        // (network drop, KV decode error, OOM) still preserves the partial reasoning
        // trace in `thinkingParts`. Without this, detectors like
        // `unbalanced-thinking-events` and the `looping` thinking-loop sub-check go
        // blind on mid-stream failures. On the success path the buffer is already
        // drained by the last `.thinkingCompleted`, so this is a no-op.
        if !thinkingBuffer.isEmpty {
            thinkingParts.append(thinkingBuffer)
            thinkingBuffer = ""
        }

        let totalMs = start.duration(to: ContinuousClock.now).milliseconds
        let firstTokenMs = firstTokenAt.map { start.duration(to: $0).milliseconds }

        let stopReason: String
        if phase == "failed" {
            stopReason = "error"
        } else if let cap = maxOutputTokens, let c = completionTokens, c >= cap {
            stopReason = "maxTokens"
        } else {
            stopReason = "naturalStop"
        }

        return Capture(
            events: events,
            raw: raw,
            thinkingRaw: thinkingRaw,
            thinkingParts: thinkingParts,
            thinkingCompleteCount: thinkingCompleteCount,
            phase: phase,
            error: errorString,
            firstTokenMs: firstTokenMs,
            totalMs: totalMs,
            peakBytes: peakBytes,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            stopReason: stopReason,
            toolCalls: toolCalls,
            toolResults: toolResults
        )
    }
}

private extension Duration {
    var seconds: Double {
        let comps = self.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
    var milliseconds: Double { seconds * 1000 }
}
