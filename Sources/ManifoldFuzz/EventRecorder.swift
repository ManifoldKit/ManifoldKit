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

    /// Total cap on `raw`/`thinkingRaw`, in characters, each — unchanged when
    /// truncation fires: the final buffer is always exactly this many
    /// characters (``headPreserveCharacters`` of frozen head + the rest as a
    /// sliding tail). `LoopingDetector.RepetitionDetector.looksLikeLooping`
    /// reads a SUFFIX to catch a genuinely-looping model (exactly the anomaly
    /// the fuzzer exists to find), so the tail must be preserved. But
    /// `ThinkingClassificationDetector` and `TemplateTokenLeakDetector` both
    /// scan for markers that appear near the START of a response (a `<think>`
    /// open tag, a leaked chat-template token) — pure front-drop would blind
    /// both of those the moment a run gets long enough to truncate. Keeping
    /// both ends is the fix: see ``headPreserveCharacters``.
    public static let maxBufferedCharacters = 1_048_576

    /// How many of the FIRST characters of `raw`/`thinkingRaw` are frozen
    /// once written and never dropped, carved out of ``maxBufferedCharacters``
    /// (so the tail budget becomes `maxBufferedCharacters - headPreserveCharacters`).
    /// 64 KiB is generous relative to where a leaked template token or a
    /// `<think>` open tag actually appears (the first few hundred characters
    /// of a response, essentially always) while leaving the overwhelming
    /// majority of the 1 MiB budget for the tail `LoopingDetector` needs.
    public static let headPreserveCharacters = 65_536

    /// Cap on `events.count`. Same head+tail rationale as
    /// ``maxBufferedCharacters`` — `CancellationRaceDetector` reads
    /// `turn1Events.first` (needs the earliest event), while most other
    /// consumers want recent history. Total is unchanged when truncation
    /// fires: ``eventsHeadReserve`` frozen head entries plus the rest as a
    /// sliding tail.
    public static let maxBufferedEvents = 50_000

    /// How many of the FIRST `events` entries are frozen once recorded and
    /// never dropped, carved out of ``maxBufferedEvents``. Generous relative
    /// to how many events a normal bounded run emits before its first
    /// meaningful content (metadata + the first handful of tokens).
    public static let eventsHeadReserve = 1_000

    /// - Parameter maxOutputTokens: the cap requested in `GenerationConfig`, used to
    ///   classify the stop reason as `maxTokens` when the final usage report meets/exceeds it.
    public func consume(_ stream: GenerationStream, maxOutputTokens: Int? = nil) async -> Capture {
        let start = ContinuousClock.now
        var events: [RunRecord.EventSnapshot] = []
        var raw = ""
        var thinkingRaw = ""
        // Frozen-once-full head snapshots — see `headPreserveCharacters`/
        // `eventsHeadReserve`. Grown in lockstep with `raw`/`thinkingRaw`/
        // `events` below, but never trimmed once they hit their cap, so they
        // always hold exactly the first N characters/entries of the stream.
        var rawHead = ""
        var thinkingRawHead = ""
        var eventsHead: [RunRecord.EventSnapshot] = []
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

        // Grows a frozen head snapshot with (a prefix of) `delta`, stopping
        // once it reaches `cap`. Called alongside every append to `raw`/
        // `thinkingRaw` so the head snapshot always holds exactly the first
        // `cap` characters of the stream, independent of any later
        // front-truncation applied to the main accumulator.
        func growHead(_ head: inout String, appending delta: String, cap: Int) {
            guard head.count < cap else { return }
            let remaining = cap - head.count
            head += delta.count <= remaining ? delta : String(delta.prefix(remaining))
        }

        // Keeps `raw`/`thinkingRaw`/`events` bounded for a generation that
        // never naturally stops (a real anomaly, not just noise — see the
        // doc comments on `maxBufferedCharacters`/`maxBufferedEvents`).
        // Trims from the FRONT of the main accumulator (keeps the most
        // recent tail, which `LoopingDetector` needs), while `rawHead`/
        // `thinkingRawHead`/`eventsHead` above independently preserve the
        // earliest characters/events untouched — combined back together at
        // the end in `finalize`, below.
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
                    growHead(&rawHead, appending: text, cap: Self.headPreserveCharacters)
                    events.append(.init(t: t, kind: "token", v: text))
                case .thinkingToken(let text):
                    if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
                    thinkingRaw += text
                    growHead(&thinkingRawHead, appending: text, cap: Self.headPreserveCharacters)
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
                if eventsHead.count < Self.eventsHeadReserve, let justAppended = events.last {
                    eventsHead.append(justAppended)
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

        // Only re-assemble head+tail when truncation actually fired — on the
        // (overwhelmingly common) untruncated path, `raw`/`thinkingRaw`/
        // `events` already hold the complete stream and `rawHead`/
        // `thinkingRawHead`/`eventsHead` are redundant. When truncated,
        // `raw`/`thinkingRaw`/`events` are guaranteed (by `capBuffers`) to
        // hold at most `maxBufferedCharacters`/`maxBufferedEvents` — taking
        // only their tail-most `maxBufferedCharacters - headPreserveCharacters`
        // characters (`maxBufferedEvents - eventsHeadReserve` events) before
        // prepending the frozen head guarantees no overlap between the two
        // halves and keeps the combined size at exactly the original cap.
        let finalRaw: String
        let finalThinkingRaw: String
        let finalEvents: [RunRecord.EventSnapshot]
        if truncated {
            finalRaw = rawHead + raw.suffix(Self.maxBufferedCharacters - Self.headPreserveCharacters)
            finalThinkingRaw = thinkingRawHead + thinkingRaw.suffix(Self.maxBufferedCharacters - Self.headPreserveCharacters)
            finalEvents = eventsHead + events.suffix(Self.maxBufferedEvents - Self.eventsHeadReserve)
        } else {
            finalRaw = raw
            finalThinkingRaw = thinkingRaw
            finalEvents = events
        }

        return Capture(
            events: finalEvents,
            raw: finalRaw,
            thinkingRaw: finalThinkingRaw,
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
