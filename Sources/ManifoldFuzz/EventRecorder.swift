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
        /// `true` when `consume` dropped some of `raw`/`thinkingRaw`/`events` to
        /// stay under ``maxBufferedCharacters``/``maxBufferedEvents`` — see
        /// those constants' doc comments for the truncation strategy.
        public var truncated: Bool

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
            toolResults: [ToolResult] = [],
            truncated: Bool = false
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
            self.truncated = truncated
        }
    }

    /// Cap on `raw`/`thinkingRaw`, in characters, each. Once either buffer
    /// exceeds this, ``consume`` drops characters from the FRONT (keeps the
    /// most recent tail) rather than simply stopping accumulation — a
    /// genuinely-looping model is exactly the anomaly the fuzzer exists to
    /// catch, and `LoopingDetector`'s `RepetitionDetector.looksLikeLooping`
    /// check reads a suffix of `raw`/`thinkingRaw`, so the truncation strategy
    /// must preserve the tail, not the head. 1 MiB is generous relative to any
    /// bounded `maxOutputTokens` run (64–512 tokens in this harness); only a
    /// backend that ignores the token cap and never stops naturally can hit it.
    public static let maxBufferedCharacters = 1_048_576

    /// Cap on `events.count`. Same front-drop rationale as
    /// ``maxBufferedCharacters`` — keeps the most recent event history rather
    /// than the earliest. Generous relative to a normal run's event count
    /// (one entry per token/thinkingToken plus occasional metadata events).
    public static let maxBufferedEvents = 50_000

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
        var truncated = false

        func memoryTick() {
            if let now = AppMemoryUsage.currentBytes() {
                peakBytes = max(peakBytes ?? now, now)
            }
        }

        // Keeps `raw`/`thinkingRaw`/`events` bounded for a generation that
        // never naturally stops (a real anomaly, not just noise — see the
        // doc comments on `maxBufferedCharacters`/`maxBufferedEvents`).
        // Dropping from the front preserves the tail, which is what
        // `LoopingDetector` and "most recent event history" readers need.
        func capBuffers() {
            if raw.count > Self.maxBufferedCharacters {
                raw.removeFirst(raw.count - Self.maxBufferedCharacters)
                truncated = true
            }
            if thinkingRaw.count > Self.maxBufferedCharacters {
                thinkingRaw.removeFirst(thinkingRaw.count - Self.maxBufferedCharacters)
                truncated = true
            }
            if events.count > Self.maxBufferedEvents {
                events.removeFirst(events.count - Self.maxBufferedEvents)
                truncated = true
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
                case .promptRendered(let text):
                    // Opt-in diagnostic; record presence but not the potentially
                    // large prompt body so fuzz trace files stay compact.
                    events.append(.init(t: t, kind: "promptRendered", v: "\(text.count)chars"))
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
                case .runTokenBudgetExceeded(let tokensUsed, let limit):
                    events.append(.init(t: t, kind: "runTokenBudgetExceeded", v: "\(tokensUsed)/\(limit)"))
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
                case .generationCompleted(let completion):
                    // Terminal "response finished" signal from the
                    // orchestrator. Record the reason in the trace so fuzz
                    // scenarios can pin exactly-once terminal emission.
                    events.append(.init(t: t, kind: "generationCompleted", v: "\(completion.reason)"))
                case .toolCallParseFailed(let rawBody):
                    events.append(.init(t: t, kind: "toolCallParseFailed", v: rawBody))
                case .toolCallTruncated(let rawBody):
                    events.append(.init(t: t, kind: "toolCallTruncated", v: rawBody))
                }
                memoryTick()
                capBuffers()
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
            toolResults: toolResults,
            truncated: truncated
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
