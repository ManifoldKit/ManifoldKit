#if Ollama
import Foundation
import ManifoldInference
import ManifoldCloudCore

/// Stateful per-stream event extractor for Ollama's NDJSON `/api/chat` and
/// `/api/generate` response shapes.
///
/// Mirrors ``OpenAIStreamEventExtractor`` in role: the stateless
/// ``CloudPayloadHandler/ollama`` `extractEvents(from:)` surface can only
/// emit events whose decision is local to one frame (`.token`,
/// `.thinkingToken`). The full Ollama event vocabulary —
/// `.toolCallStart` / `.toolCallArgumentsDelta` / `.toolCall`, `.usage`,
/// the implicit `.thinkingComplete` transition, the inline `<think>`-tag
/// fallback parser, and the per-stream visible/thinking caps — requires
/// cross-frame state that lives here.
///
/// ### Differences vs. OpenAI
///
///   - Ollama's tool calls are **whole** (one terminal-ish line carries the
///     entire `tool_calls[]` array), not delta-streamed. The extractor
///     synthesises a uniform `.toolCallStart` → `.toolCallArgumentsDelta`
///     → `.toolCall` triple so downstream consumers stay on a single code
///     path with the OpenAI/Claude paths (PR #783's invariant).
///   - The `.usage` event is carried on the `"done":true` terminal line
///     via `prompt_eval_count` / `eval_count` — handled here (we let the
///     envelope still relay it for `lastUsage` bookkeeping).
///   - Inline `<think>`-tag fallback runs when the server never emits a
///     dedicated `message.thinking` field — engaged once on first
///     sighting of the open marker and stays engaged for the rest of the
///     stream so a tag split across NDJSON lines is held in the parser's
///     own buffer.
///   - Cancellation is observed at the consume boundary so a host
///     `Task.cancel()` mid-stream does not surface phantom `.toolCall`
///     events for entries the orchestrator never agreed to dispatch.
///
/// ### Configuration injection
///
/// Unlike OpenAI's extractor (which is config-free), Ollama needs runtime
/// access to `GenerationConfig` for the visible/thinking caps and the
/// fallback marker pair. The factory closure in
/// ``OllamaBackend`` stashes the active config in a stateLock-guarded
/// snapshot at `parseResponseStream(bytes:config:continuation:)` entry,
/// then the factory pulls that snapshot when constructing the consumer.
/// This keeps the ``CloudStreamEventConsumer`` protocol config-free while
/// still letting Ollama honour the per-call caps the legacy
/// `OllamaStreamProcessor` did.
public final class OllamaStreamEventExtractor: CloudStreamEventConsumer, @unchecked Sendable {

    private let visibleLimit: Int?
    private let thinkingLimit: Int?
    private let fallbackMarkers: ThinkingMarkers
    private let autoDetectedMarkers: ThinkingMarkers?
    private let initialThinkingMarkers: ThinkingMarkers?

    // Mutable per-stream state.
    private var thinkingOpen: Bool = false
    private var thinkingTokenCount: Int = 0
    private var visibleLineCount: Int = 0
    private var sawThinkingField: Bool = false
    private var contentParser: ThinkingParser?
    /// One-shot guard. Ollama can in principle emit `tool_calls[]` on
    /// successive NDJSON lines (older qwen2.5 builds split parallel calls
    /// across lines); finalisation must still be one-per-call. The
    /// equivalent of OpenAI's `finalisedToolCalls` flag is implicit here
    /// because each `tool_calls[]` entry produces a finalised `.toolCall`
    /// in the same `consume(payload:)` invocation — there is no buffering.
    /// We do not need a separate guard.
    private var visibleCapHit: Bool = false

    public init(
        config: GenerationConfig,
        autoDetectedMarkers: ThinkingMarkers? = nil
    ) {
        self.visibleLimit = config.maxOutputTokens
        self.thinkingLimit = config.maxThinkingTokens
        self.initialThinkingMarkers = config.thinkingMarkers
        self.autoDetectedMarkers = autoDetectedMarkers
        // Same precedence as the legacy `OllamaStreamProcessor`:
        // per-request override > auto-detected from `/api/show` template >
        // Qwen3 default. The lookup order matters: hardcoding `.qwen3`
        // was the bug that leaked `<thinking>` and `<reasoning>` markers
        // as visible tokens before the auto-detection landed.
        self.fallbackMarkers = config.thinkingMarkers ?? autoDetectedMarkers ?? .qwen3
    }

    // MARK: - Per-frame event extraction

    public func consume(payload: String) -> [GenerationEvent] {
        // Cancellation contract: a consumer that drops the stream
        // mid-flight must NOT observe `.toolCall` events for entries the
        // orchestrator never agreed to dispatch. Honour `Task.isCancelled`
        // at the consume boundary so a tool_calls payload arriving
        // alongside the cancel does not fire a phantom dispatch.
        if Task.isCancelled { return [] }

        guard let parsed = OllamaPayloadParser.parseLine(payload) else { return [] }
        var out: [GenerationEvent] = []

        // Order: tool calls → thinking → content → done-flush (thinking
        // close on terminal). Matches the legacy `OllamaStreamProcessor`
        // step order one-for-one so the parity tests pass.
        appendToolCallEvents(parsed, into: &out)
        if Task.isCancelled { return out }

        appendThinkingEvents(parsed, into: &out)
        if visibleCapHit { return out }
        appendContentEvents(parsed, into: &out)

        if parsed.done {
            appendDoneFlush(into: &out)
            appendUsage(parsed, into: &out)
        }

        return out
    }

    public func finish(cancelled: Bool = false) -> [GenerationEvent] {
        var out: [GenerationEvent] = []
        // Drain any bytes still held back inside the fallback parser. A
        // stream that ends without a trailing done-chunk would otherwise
        // swallow the final held-back suffix.
        if var parser = contentParser {
            for event in parser.finalize() {
                _ = emit(event, into: &out)
            }
            contentParser = parser
        }
        // Safety net: if the stream ends while thinking is still "open"
        // (no done-chunk, no empty-thinking transition), close it out so
        // consumers don't hang in a thinking-only state.
        if thinkingOpen && !cancelled {
            out.append(.thinkingComplete)
            thinkingOpen = false
        }
        return out
    }

    // MARK: - Step helpers

    private func appendToolCallEvents(_ parsed: OllamaParsedLine, into out: inout [GenerationEvent]) {
        guard let toolCalls = parsed.toolCalls, !toolCalls.isEmpty else { return }
        for call in toolCalls {
            if Task.isCancelled { return }
            out.append(.toolCallStart(callId: call.id, name: call.toolName))
            if !call.arguments.isEmpty {
                out.append(.toolCallArgumentsDelta(callId: call.id, textDelta: call.arguments))
            }
            out.append(.toolCall(call))
        }
    }

    private func appendThinkingEvents(_ parsed: OllamaParsedLine, into out: inout [GenerationEvent]) {
        if let thinking = parsed.thinking, !thinking.isEmpty {
            sawThinkingField = true
            if let limit = thinkingLimit, thinkingTokenCount >= limit {
                return // Cap reached — drop silently.
            }
            out.append(.thinkingToken(thinking))
            thinkingOpen = true
            // Each thinking-bearing NDJSON line counts as one "token" for
            // cap purposes — Ollama ships whole-blob thinking per line, not
            // per-token, so this matches the wire format's grain.
            thinkingTokenCount += 1
            return
        }
        // Transition from thinking → content. Fire `.thinkingComplete`
        // exactly once on the first empty-thinking line we see after any
        // non-empty thinking was emitted. Skipped when the fallback parser
        // is driving state — the parser closes its own thinking block via
        // its own `.thinkingComplete`.
        if thinkingOpen && contentParser == nil {
            out.append(.thinkingComplete)
            thinkingOpen = false
        }
    }

    private func appendContentEvents(_ parsed: OllamaParsedLine, into out: inout [GenerationEvent]) {
        guard let content = parsed.content, !content.isEmpty else { return }
        if let limit = visibleLimit {
            // Prefer the server's running `eval_count` for an exact
            // token-count cap; fall back to the NDJSON line counter as an
            // upper bound that may overshoot by one line.
            let observed = parsed.evalCount ?? visibleLineCount
            if observed >= limit {
                visibleCapHit = true
                return
            }
        }
        if contentParser == nil,
           !sawThinkingField,
           content.contains(fallbackMarkers.open) {
            contentParser = ThinkingParser(markers: fallbackMarkers)
        }
        if var parser = contentParser {
            for event in parser.process(content) {
                if !emit(event, into: &out) {
                    contentParser = parser
                    return
                }
            }
            contentParser = parser
        } else {
            out.append(.token(content))
            visibleLineCount += 1
        }
    }

    private func appendDoneFlush(into out: inout [GenerationEvent]) {
        // Flush any held-back content from the fallback parser first;
        // held-back bytes (e.g. an unmatched prefix of `<`) must surface
        // before we decide whether thinking is still open.
        if var parser = contentParser {
            for event in parser.finalize() {
                if !emit(event, into: &out) {
                    contentParser = parser
                    return
                }
            }
            contentParser = parser
        }
        // Ollama can terminate with `"done":true` while thinking is still
        // the only content emitted (reasoning model hits num_predict mid-
        // think). Flush `.thinkingComplete` so consumers don't leave the
        // thinking block open.
        if thinkingOpen {
            out.append(.thinkingComplete)
            thinkingOpen = false
        }
    }

    private func appendUsage(_ parsed: OllamaParsedLine, into out: inout [GenerationEvent]) {
        // The envelope's adapter-routed loop also relays `.usage` events
        // (mirroring `handleUsage` on the backend). We emit here so the
        // event order is correct relative to the rest of the stream
        // (`.usage` after content, before stream-complete). The envelope
        // de-duplicates via the consumer-yielded event path.
        guard let prompt = parsed.promptEvalCount, let completion = parsed.evalCount else {
            return
        }
        out.append(.usage(prompt: prompt, completion: completion))
    }

    // MARK: - Cap-aware emit helper

    /// Emit one parser-produced event while honouring per-stream caps.
    /// Returns `false` when the visible-token cap was hit (caller stops
    /// producing further events on this line). Only handles
    /// `.token`/`.thinkingToken`/`.thinkingComplete` — anything else is
    /// forwarded verbatim.
    private func emit(_ event: GenerationEvent, into out: inout [GenerationEvent]) -> Bool {
        switch event {
        case .thinkingToken(let text):
            if let limit = thinkingLimit, thinkingTokenCount >= limit {
                return true // Drop silently — cap reached.
            }
            out.append(.thinkingToken(text))
            thinkingOpen = true
            thinkingTokenCount += 1
            return true
        case .thinkingComplete:
            out.append(.thinkingComplete)
            thinkingOpen = false
            return true
        case .token(let text):
            if let limit = visibleLimit, visibleLineCount >= limit {
                visibleCapHit = true
                return false
            }
            out.append(.token(text))
            visibleLineCount += 1
            return true
        default:
            out.append(event)
            return true
        }
    }
}

// MARK: - Factory on CloudPayloadHandler

public extension CloudPayloadHandler {
    /// Returns a fresh per-stream consumer for Ollama's NDJSON wire shape,
    /// or `nil` for non-Ollama cases. Mirrors
    /// ``makeOpenAIStreamConsumer`` (Phase 2/B/iii/γ).
    ///
    /// Unlike the OpenAI factory (which takes no parameters), Ollama needs
    /// the active ``GenerationConfig`` plus the auto-detected thinking
    /// markers captured at `loadModel` time. ``OllamaBackend`` plumbs both
    /// into the routing's `streamConsumerFactory` via a closure capture so
    /// each generation gets a fresh consumer with the live caps and the
    /// model's actual thinking markers.
    func makeOllamaStreamConsumer(
        config: GenerationConfig,
        autoDetectedMarkers: ThinkingMarkers? = nil
    ) -> OllamaStreamEventExtractor? {
        switch self {
        case .ollama:
            return OllamaStreamEventExtractor(
                config: config,
                autoDetectedMarkers: autoDetectedMarkers
            )
        default:
            return nil
        }
    }
}
#endif
