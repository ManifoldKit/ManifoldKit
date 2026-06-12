import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

// MARK: - OllamaPayloadParser (moved from OllamaPayloadHandler.swift, Phase 5)

/// Decoded shape of a single Ollama NDJSON record.
///
/// Ollama's two endpoints carry data in different places:
/// - `/api/chat` streams put content in `message.content` and reasoning in
///   `message.thinking`.
/// - `/api/generate` (non-chat) uses top-level `response` and top-level
///   `thinking`.
/// `parseLine` normalises both shapes; consumers read `content` and
/// `thinking` without caring which endpoint produced the line.
///
/// `evalCount` / `promptEvalCount` are the exact token counts reported by
/// the Ollama server. Per Ollama's documented API, these appear on the
/// terminal `"done":true` line — `eval_count` is the number of tokens the
/// model produced this turn and `prompt_eval_count` is the number of tokens
/// in the prompt. Some Ollama-compatible servers also emit a running
/// `eval_count` on intermediate lines; parsing it unconditionally lets the
/// stream cap visible output precisely when available and falls back to a
/// line counter when not.
struct OllamaParsedLine {
    var content: String?
    var thinking: String?
    var done: Bool
    var evalCount: Int?
    var promptEvalCount: Int?
    /// Tool calls emitted by the assistant this line, in emission order.
    /// `nil` when the line carries no `tool_calls` field; an empty array
    /// is normalised to `nil` so downstream callers can short-circuit on
    /// `parsed.toolCalls != nil`.
    var toolCalls: [ToolCall]?
}

enum OllamaPayloadParser {

    /// Parses a single Ollama NDJSON line into a normalised shape.
    ///
    /// Returns `nil` for malformed lines so the stream parser can skip them
    /// the same way it historically skipped unparseable JSON.
    static func parseLine(_ json: String) -> OllamaParsedLine? {
        guard let data = json.data(using: .utf8) else { return nil }
        let parsed: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            parsed = object
        } catch {
            return nil
        }

        let done = (parsed["done"] as? Bool) ?? false

        var content: String?
        var thinking: String?
        var toolCalls: [ToolCall]?

        if let message = parsed["message"] as? [String: Any] {
            // `/api/chat` shape.
            content = message["content"] as? String
            thinking = message["thinking"] as? String
            if let rawCalls = message["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
                toolCalls = rawCalls.compactMap(OllamaPayloadParser.decodeToolCall)
                if toolCalls?.isEmpty == true { toolCalls = nil }
            }
        }

        // `/api/generate` shape — top-level `response` and `thinking`. If both
        // `message.content` and top-level `response` are present (shouldn't
        // happen in practice), chat-shape wins because it arrived first.
        if content == nil, let response = parsed["response"] as? String {
            content = response
        }
        if thinking == nil, let topThinking = parsed["thinking"] as? String {
            thinking = topThinking
        }

        // Usage fields — `eval_count` (output tokens) and `prompt_eval_count`
        // (prompt tokens). Documented as done-line fields but we parse them
        // unconditionally so a running-count-emitting server is handled too.
        let evalCount = parsed["eval_count"] as? Int
        let promptEvalCount = parsed["prompt_eval_count"] as? Int

        return OllamaParsedLine(
            content: content,
            thinking: thinking,
            done: done,
            evalCount: evalCount,
            promptEvalCount: promptEvalCount,
            toolCalls: toolCalls
        )
    }

    /// Extracts the assistant content token from an Ollama NDJSON line.
    ///
    /// Ollama streaming format (one JSON object per line, no `data:` prefix):
    /// ```json
    /// {"model":"llama3","message":{"role":"assistant","content":"Hello"},"done":false}
    /// ```
    /// Final chunk has `"done":true` and empty or absent content — we skip it.
    ///
    /// This method only surfaces visible content; reasoning-model `thinking`
    /// fields are handled inline by ``parseResponseStream(bytes:config:continuation:)``
    /// so they can be emitted as ``GenerationEvent/thinkingToken(_:)`` with
    /// proper ``GenerationEvent/thinkingCompleted`` bracketing. Kept for the
    /// ``SSEPayloadHandler`` protocol conformance and external callers.
    static func extractToken(from json: String) -> String? {
        guard let parsed = parseLine(json) else { return nil }
        // Skip the final "done" chunk.
        if parsed.done { return nil }
        guard let content = parsed.content, !content.isEmpty else { return nil }
        return content
    }

    /// Extracts reasoning content from an Ollama NDJSON line, if any.
    ///
    /// Returns `nil` when the line carries no `thinking` field or an empty
    /// one. Exposed for symmetry with ``extractToken(from:)``; streaming
    /// callers use the inline logic in
    /// ``parseResponseStream(bytes:config:continuation:)`` to bracket
    /// thinking emissions with ``GenerationEvent/thinkingCompleted``.
    static func extractThinking(from json: String) -> String? {
        guard let parsed = parseLine(json),
              let thinking = parsed.thinking,
              !thinking.isEmpty else {
            return nil
        }
        return thinking
    }

    /// Decodes one `tool_calls[]` entry from a parsed NDJSON line.
    ///
    /// Ollama's streaming format follows the OpenAI shape:
    /// `{id, type: "function", function: {name, arguments}}`. The `arguments`
    /// field is sometimes a JSON string (the documented wire shape) and
    /// sometimes a pre-parsed dictionary (observed on some Ollama builds);
    /// the decoder handles both and always produces a ``ToolCall`` whose
    /// `arguments` property is a valid JSON string.
    ///
    /// `id` is optional on the wire — some Ollama builds omit it for the
    /// first tool call in a turn. Synthesise a deterministic fallback from
    /// the tool name plus a counter suffix when absent so downstream
    /// call/result pairing still works.
    ///
    /// Inlined from the former `OllamaMessageEncoder.decodeToolCall` as
    /// part of Phase 1b/B — parser helpers now co-locate with the parser
    /// rather than the encoder.
    static func decodeToolCall(_ raw: [String: Any]) -> ToolCall? {
        // Two observed shapes on the wire:
        //   A) {id, type: "function", function: {name, arguments}}  — documented
        //   B) {id, name, arguments}                                 — some 0.3.x builds
        // Prefer the nested `function` envelope; fall back to the flat shape
        // when it's absent so lenient Ollama forks still produce tool events.
        let nameSource: [String: Any]
        if let function = raw["function"] as? [String: Any] {
            nameSource = function
        } else {
            nameSource = raw
        }
        guard let name = nameSource["name"] as? String, !name.isEmpty else {
            return nil
        }

        let id: String
        if let wireId = raw["id"] as? String, !wireId.isEmpty {
            id = wireId
        } else {
            // Deterministic fallback: ids are only used for id→result pairing
            // inside one turn, so a name-based placeholder is sufficient.
            id = "ollama-\(name)-\(UUID().uuidString.prefix(8))"
        }

        let argumentsString: String
        if let raw = nameSource["arguments"] as? String {
            argumentsString = raw
        } else if let dict = nameSource["arguments"] as? [String: Any] {
            argumentsString = serialiseArgumentDictionary(dict)
        } else {
            argumentsString = "{}"
        }

        return ToolCall(id: id, toolName: name, arguments: argumentsString)
    }

    /// Serialise an already-parsed arguments dictionary to a JSON string,
    /// normalising Ollama builds that emit structured `arguments` instead of
    /// the documented stringified form. Falls back to `"{}"` when
    /// serialisation fails so ``ToolCall/arguments`` always contains valid
    /// JSON the registry can decode.
    static func serialiseArgumentDictionary(_ dict: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            Log.inference.warning(
                "OllamaPayloadParser: tool arguments dictionary serialised to non-UTF8 bytes — substituting empty object."
            )
            return "{}"
        } catch {
            Log.inference.warning(
                "OllamaPayloadParser: failed to serialise parsed tool arguments — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return "{}"
        }
    }
}

/// Stateful per-stream event extractor for Ollama's NDJSON `/api/chat` and
/// `/api/generate` response shapes.
///
/// Mirrors ``OpenAIStreamEventExtractor`` in role: the stateless
/// ``CloudPayloadHandler/ollama`` `extractEvents(from:)` surface can only
/// emit events whose decision is local to one frame (`.token`,
/// `.thinkingToken`). The full Ollama event vocabulary —
/// `.toolCallStart` / `.toolCallArgumentsDelta` / `.toolCall`, `.usage`,
/// the implicit `.thinkingCompleted` transition, the inline `<think>`-tag
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
    private var contentParser: OutputParserSession?
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

        // Mid-line cancellation contract (#972): if this line emitted
        // tool-call events, suppress thinking/content on the same line.
        // Real Ollama wire frames never mix `tool_calls[]` with visible
        // `content` or `thinking` on a single NDJSON record — the call
        // arrives in its own line. A consumer that observes
        // `.toolCallStart` and calls `stopGeneration()` cannot
        // deterministically suppress subsequent same-frame events via
        // `Task.isCancelled` alone (the producer runs synchronously
        // through one frame's events). Treating a tool-call frame as
        // tool-call-only is the deterministic guarantee: a malicious or
        // misbehaving server that crams thinking + content into a
        // tool-call line cannot leak that data after the consumer
        // requested cancel. Tests exercising this contract:
        //   - OllamaBackendToolCallingTests.test_cancellation_midLine_*
        //   - OllamaStreamEventExtractorTests (covers the legitimate
        //     production shape — tool_calls in their own line with
        //     empty content).
        let emittedToolCalls = !(parsed.toolCalls ?? []).isEmpty

        if !emittedToolCalls {
            appendThinkingEvents(parsed, into: &out)
            if visibleCapHit { return out }
            appendContentEvents(parsed, into: &out)
        }

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
            out.append(.thinkingCompleted)
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
        // Transition from thinking → content. Fire `.thinkingCompleted`
        // exactly once on the first empty-thinking line we see after any
        // non-empty thinking was emitted. Skipped when the fallback parser
        // is driving state — the parser closes its own thinking block via
        // its own `.thinkingCompleted`.
        if thinkingOpen && contentParser == nil {
            out.append(.thinkingCompleted)
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
            contentParser = OutputParserSession([.thinking(ThinkingTransform(markers: fallbackMarkers))])
        }
        if var parser = contentParser {
            for event in parser.ingest(content) {
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
        // think). Flush `.thinkingCompleted` so consumers don't leave the
        // thinking block open.
        if thinkingOpen {
            out.append(.thinkingCompleted)
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
    /// `.token`/`.thinkingToken`/`.thinkingCompleted` — anything else is
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
        case .thinkingCompleted:
            out.append(.thinkingCompleted)
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
        guard provider == .ollama else { return nil }
        return OllamaStreamEventExtractor(
            config: config,
            autoDetectedMarkers: autoDetectedMarkers
        )
    }
}
