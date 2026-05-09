#if Ollama
import Foundation
import ManifoldInference
import ManifoldCloudCore

/// Stateful NDJSON stream processor for Ollama's `/api/chat` and `/api/generate` response shapes.
struct OllamaStreamProcessor {
    let limits: SSEStreamLimits
    let config: GenerationConfig
    let autoDetectedThinkingMarkers: ThinkingMarkers?
    let continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    let handleUsage: ((promptTokens: Int?, completionTokens: Int?)) -> Void

    mutating func parse(bytes: URLSession.AsyncBytes) async throws {
        var lineBuffer = Data()
        var totalBytes = 0
        var rateWindowStart = ContinuousClock.now
        var rateWindowCount = 0

        // Tracks whether we've emitted any thinking content on this stream,
        // so we know when to fire the single .thinkingComplete event.
        var thinkingOpen = false
        var thinkingTokenCount = 0
        let thinkingLimit = config.maxThinkingTokens
        // Fallback per-line counter for servers that don't emit `eval_count`
        // until the done-line. When a line carries `eval_count`, we prefer it
        // over this counter for an exact cap.
        var visibleLineCount = 0
        let visibleLimit = config.maxOutputTokens

        // Inline `<think>` fallback state. Engaged only when the server never
        // populates `message.thinking` / top-level `thinking` and a content
        // chunk carries `<think>`. Once engaged it stays engaged for the rest
        // of the stream so partial tags split across chunks are held back
        // correctly by the parser's own buffering.
        var sawThinkingField = false
        // Order: explicit per-request override > auto-detected markers from
        // the `/api/show` template scan > Qwen3 default. Hardcoding
        // `.qwen3` was the bug — non-Qwen reasoning models (`<thinking>`,
        // `<reasoning>`) silently leaked their markers as visible tokens.
        let detectedMarkers = autoDetectedThinkingMarkers
        let fallbackMarkers = config.thinkingMarkers ?? detectedMarkers ?? .qwen3
        var contentParser: ThinkingParser?

        func noteEventYielded() throws {
            let now = ContinuousClock.now
            if now - rateWindowStart >= .seconds(1) {
                rateWindowStart = now
                rateWindowCount = 1
                return
            }
            rateWindowCount += 1
            if rateWindowCount > limits.maxEventsPerSecond {
                throw SSEStreamError.eventRateExceeded(rateWindowCount)
            }
        }

        // Yield a single parser-produced event while honouring the per-stream
        // caps used elsewhere. Returns `false` when the visible-token cap was
        // hit and the caller should stop producing further output on this
        // line. Only handles the events `ThinkingParser` actually emits
        // (`.token`, `.thinkingToken`, `.thinkingComplete`); anything else is
        // forwarded verbatim.
        func emit(_ event: GenerationEvent) throws -> Bool {
            switch event {
            case .thinkingToken(let text):
                if let limit = thinkingLimit, thinkingTokenCount >= limit {
                    return true // Drop silently — cap reached.
                }
                try noteEventYielded()
                continuation.yield(.thinkingToken(text))
                thinkingOpen = true
                thinkingTokenCount += 1
                return true
            case .thinkingComplete:
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
                return true
            case .token(let text):
                if let limit = visibleLimit, visibleLineCount >= limit {
                    continuation.finish()
                    return false
                }
                try noteEventYielded()
                continuation.yield(.token(text))
                visibleLineCount += 1
                return true
            default:
                continuation.yield(event)
                return true
            }
        }

        // Tool calls first: Ollama can emit multiple tool_calls in a single
        // assistant message. Dispatch them in emission order so the
        // coordinator's serial dispatch loop sees them in the same order
        // the model produced them.
        //
        // Event-shape contract (PR #783): every tool call surfaces as a
        // uniform start + single arguments-delta + toolCall triple, even
        // for whole-call backends like Ollama. That keeps consumers
        // (orchestrator, UI) on a single code path regardless of whether
        // the underlying transport streams arguments incrementally.
        //
        // TODO(#753): Some Ollama configs (notably `qwen2.5:7b` against
        // newer servers) reportedly emit incremental tool_call deltas
        // across multiple NDJSON lines. v1 treats Ollama as whole-call
        // only; if we observe incremental deltas in the wild, lift
        // `StreamingToolCallAccumulator` from `OpenAIToolEncoding.swift`
        // and key by tool-call index here. `streamsToolCallArguments`
        // would flip to `true` at the same time.
        // Returns `false` when `Task.isCancelled` is observed at any point
        // during this helper so `handleLine` can skip the remaining
        // sub-handlers (`processThinking` / `processContent`) for the same
        // NDJSON line. Pre-#970 the equivalent in-loop `if Task.isCancelled
        // { return }` exited `handleLine` directly; after the decomposition
        // a bare `return` exits only this helper, which would let
        // post-cancel thinking and content events surface — the regression
        // #972 fixes by mirroring `processContent`'s `Bool` convention.
        func processToolCalls(_ parsed: OllamaParsedLine) async throws -> Bool {
            guard let toolCalls = parsed.toolCalls, !toolCalls.isEmpty else {
                // Even with no tool_calls on this line, a cancel that
                // arrived between sub-handlers must short-circuit
                // downstream emission for the same line.
                return !Task.isCancelled
            }
            for call in toolCalls {
                // Cancellation contract: a consumer that drops the stream
                // mid-flight must NOT observe `.toolCall` events for
                // entries the orchestrator never agreed to dispatch. Honour
                // `Task.isCancelled` at the emit boundary so a single-line
                // tool_calls payload arriving alongside the cancel doesn't
                // fire a phantom dispatch.
                if Task.isCancelled { return false }
                try noteEventYielded()
                continuation.yield(.toolCallStart(callId: call.id, name: call.toolName))
                if !call.arguments.isEmpty {
                    try noteEventYielded()
                    continuation.yield(.toolCallArgumentsDelta(
                        callId: call.id,
                        textDelta: call.arguments
                    ))
                }
                try noteEventYielded()
                continuation.yield(.toolCall(call))
            }
            // Post-loop cancellation: if the cancel arrived after the last
            // tool_call was emitted but before this helper returned, still
            // bail so thinking/content on the same line don't surface.
            return !Task.isCancelled
        }

        // Route thinking field (if any) first so downstream consumers see
        // reasoning before visible content for a given NDJSON record.
        func processThinking(_ parsed: OllamaParsedLine) throws {
            if let thinking = parsed.thinking, !thinking.isEmpty {
                sawThinkingField = true
                if let limit = thinkingLimit, thinkingTokenCount >= limit {
                    return // Cap reached — drop this thinking chunk silently.
                }
                try noteEventYielded()
                continuation.yield(.thinkingToken(thinking))
                thinkingOpen = true
                // Count each thinking-bearing NDJSON line as one "token"
                // for cap purposes. Ollama ships whole-blob thinking per
                // line rather than per-token, so this matches the coarser
                // grain of the wire format.
                thinkingTokenCount += 1
                return
            }
            // Transition from thinking → content. Fire .thinkingComplete
            // exactly once on the first empty-thinking line we see after
            // any non-empty thinking was emitted. Skipped when the fallback
            // parser is driving state — the parser closes its own thinking
            // block via its own `.thinkingComplete`.
            if thinkingOpen && contentParser == nil {
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
            }
        }

        // Returns `false` when the stream should stop (visible-token cap hit
        // or the fallback parser surfaced a stop signal); `true` to keep
        // processing further fields on the same line.
        func processContent(_ parsed: OllamaParsedLine) throws -> Bool {
            guard let content = parsed.content, !content.isEmpty else { return true }
            // Prefer the server's running `eval_count` when present for an
            // exact token-count cap; otherwise fall back to the NDJSON line
            // counter which is an upper bound but may overshoot by one line.
            if let limit = visibleLimit {
                let observed = parsed.evalCount ?? visibleLineCount
                if observed >= limit {
                    continuation.finish()
                    return false
                }
            }
            // Engage the fallback `<think>`-in-content parser when the
            // server has never populated a dedicated thinking field on this
            // stream and the incoming content carries the opening tag. Once
            // engaged, every subsequent content chunk flows through the
            // parser so a tag split across two NDJSON lines is held in the
            // parser's own buffer.
            if contentParser == nil,
               !sawThinkingField,
               content.contains(fallbackMarkers.open) {
                contentParser = ThinkingParser(markers: fallbackMarkers)
            }
            if var parser = contentParser {
                for event in parser.process(content) {
                    if try !emit(event) {
                        contentParser = parser
                        return false
                    }
                }
                contentParser = parser
            } else {
                try noteEventYielded()
                continuation.yield(.token(content))
                visibleLineCount += 1
            }
            return true
        }

        // Returns `false` when the fallback parser surfaced a stop signal
        // mid-flush (visible-token cap hit while draining held-back bytes).
        func processDoneFlush() throws -> Bool {
            // Flush any remaining buffered content from the fallback parser
            // first — held-back bytes (e.g. an unmatched prefix of `<`)
            // must be emitted before we decide whether thinking is still
            // open.
            if var parser = contentParser {
                for event in parser.finalize() {
                    if try !emit(event) {
                        contentParser = parser
                        return false
                    }
                }
                contentParser = parser
            }
            // Ollama can terminate with `"done":true` while thinking is
            // still the only content emitted (e.g. reasoning model hits
            // num_predict mid-think). Flush .thinkingComplete so downstream
            // consumers don't leave the thinking block open.
            if thinkingOpen {
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
            }
            return true
        }

        // Surface usage from the done-line (`eval_count`,
        // `prompt_eval_count`). Wires into `handleUsage` (populating
        // `lastUsage` for `TokenUsageProvider` consumers) and emits a
        // `.usage` event on the stream, mirroring the SSE path in
        // `SSECloudBackend.parseResponseStream`.
        func processUsage(_ parsed: OllamaParsedLine) throws {
            guard parsed.evalCount != nil || parsed.promptEvalCount != nil else { return }
            let usage: (promptTokens: Int?, completionTokens: Int?) = (
                promptTokens: parsed.promptEvalCount,
                completionTokens: parsed.evalCount
            )
            handleUsage(usage)
            if let prompt = usage.promptTokens,
               let completion = usage.completionTokens {
                try noteEventYielded()
                continuation.yield(.usage(prompt: prompt, completion: completion))
            }
        }

        func handleLine(_ line: String) async throws {
            guard let parsed = OllamaPayloadParser.parseLine(line) else { return }
            guard try await processToolCalls(parsed) else { return }
            try processThinking(parsed)
            guard try processContent(parsed) else { return }
            if parsed.done {
                guard try processDoneFlush() else { return }
                try processUsage(parsed)
            }
        }

        for try await byte in bytes {
            if Task.isCancelled { break }

            totalBytes += 1
            if totalBytes > limits.maxTotalBytes {
                throw SSEStreamError.streamTooLarge(totalBytes)
            }

            if byte == UInt8(ascii: "\n") {
                if !lineBuffer.isEmpty {
                    if let line = String(data: lineBuffer, encoding: .utf8) {
                        try await handleLine(line)
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            } else {
                lineBuffer.append(byte)
                if lineBuffer.count > limits.maxEventBytes {
                    throw SSEStreamError.eventTooLarge(lineBuffer.count)
                }
            }
        }

        // Flush any final line without a trailing newline.
        if !lineBuffer.isEmpty,
           let line = String(data: lineBuffer, encoding: .utf8) {
            try await handleLine(line)
        }

        // Drain any bytes still held back inside the fallback parser. A stream
        // that ends without a trailing done-chunk (network cut, malformed
        // last line) would otherwise swallow the final held-back suffix.
        if var parser = contentParser {
            for event in parser.finalize() {
                _ = try emit(event)
            }
            contentParser = parser
        }

        // Safety net: if the stream ends while thinking is still "open"
        // (no done-chunk, no empty-thinking transition), still close it out
        // so consumers don't hang in a thinking-only state.
        if thinkingOpen {
            try noteEventYielded()
            continuation.yield(.thinkingComplete)
        }
    }
}
#endif
