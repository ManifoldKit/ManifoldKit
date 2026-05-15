#if CloudSaaS
import Foundation
import ManifoldInference
import ManifoldCloudCore

/// Stateful per-stream event extractor for the Anthropic Messages API wire
/// shape.
///
/// The stateless ``CloudPayloadHandler/claude`` `extractEvents(from:)`
/// surface can only emit the events whose decision is local to one frame
/// (`.token`, `.thinkingToken`). The full Claude event vocabulary —
/// `.toolCallStart` / `.toolCallArgumentsDelta` / `.toolCall`,
/// `.thinkingSignature`, `.thinkingComplete` transition, `.usage` — requires
/// cross-frame state (index-keyed tool-use accumulator, the open-thinking
/// flag, the once-only tool-call finalisation guard).
/// `ClaudeStreamEventExtractor` owns that state.
///
/// ### Mirrors `OpenAIStreamEventExtractor`
///
/// Modelled one-for-one on `OpenAIStreamEventExtractor` (shipped in #1269).
/// Same lifecycle, same flush-at-finish discipline, same per-stream
/// freshness contract — the factory pattern is enforced via
/// ``CloudPayloadHandler/makeClaudeStreamConsumer()``.
///
/// ### Anthropic-specific surface
///
/// - **Thinking signatures.** Anthropic carries an opaque `signature` on
///   each thinking block; multi-turn extended-thinking requests are
///   rejected if the signature isn't echoed verbatim. The extractor
///   forwards `.thinkingSignature(_)` whether the signature appears on
///   `content_block_start` (early endpoints) or in a `signature_delta`
///   event (the path real production streams use today).
/// - **Tool-use blocks.** `content_block_start` declares the call id +
///   name. Each `content_block_delta` with `type: input_json_delta`
///   appends to the per-index argument buffer. `content_block_stop` on
///   the same index finalises the call and emits `.toolCall(...)`.
///   Empty-input tool_use blocks (no delta arrived) emit a synthesised
///   `"{}"` arguments delta on finalisation so consumers always see a
///   start → delta → call triple.
/// - **Whole-message tool_use.** Some synthesised replay paths and some
///   future non-streaming endpoint variants deliver the entire
///   `content[]` array on one payload. The extractor treats each
///   embedded `tool_use` block as a uniform start + single delta +
///   `.toolCall` triple.
/// - **Stream end.** `message_stop` is the terminal event; `message_delta`
///   carries the final `output_tokens`. The extractor doesn't decide
///   termination itself — `ClaudeMessageStopFinalizer` (in the routing)
///   owns that — but `finish(cancelled:)` flushes any open thinking
///   block and any tool calls upstream never accompanied with an
///   explicit `content_block_stop`.
///
/// ### Lifecycle
///
/// Create one extractor per generation; call ``consume(payload:)`` for each
/// SSE frame; call ``finish(cancelled:)`` exactly once at stream end
/// (after either a natural completion or a thrown error) to flush pending
/// state. Pass `cancelled: true` to suppress phantom tool-call emission.
public final class ClaudeStreamEventExtractor: CloudStreamEventConsumer, @unchecked Sendable {

    private var thinking = ThinkingBlockManager()
    private let toolAccumulator = StreamingArgumentAccumulator()
    /// Indices declared by a `content_block_start` with `type: tool_use`.
    private var toolUseIndexes: Set<Int> = []
    /// Indices that have already emitted at least one
    /// `.toolCallArgumentsDelta`. Drives the empty-input synthesised
    /// `"{}"` delta on finalisation so consumers always see a uniform
    /// start → delta → call triple.
    private var toolUseEmittedDelta: Set<Int> = []
    /// Indices already finalised via `content_block_stop`; second sightings
    /// are no-ops so a defensive `finalizePending` at stream end can't
    /// re-emit calls.
    private var toolUseFinalized: Set<Int> = []
    /// Guard against the whole-message path running twice on the same
    /// stream (defensive — Anthropic never sends both shapes today).
    private var emittedWholeMessageToolCalls = false

    // Claude splits usage across two frames: `input_tokens` arrives on
    // `message_start`, `output_tokens` arrives on `message_delta`. The
    // stateless `extractUsage` surface returns one half at a time
    // (`(12, nil)` then `(nil, 48)`), so a per-frame gate that requires
    // both halves would never fire. The extractor merges them so it can
    // emit a single `.usage(prompt, completion)` event on the
    // message_delta frame, matching the inline `parseResponseStream`
    // behaviour the routed path replaces.
    private var pendingPromptTokens: Int?
    private var emittedUsage = false

    public init() {}

    // MARK: - Per-frame event extraction

    /// Returns the event sequence to emit for `payload`. The order mirrors
    /// `ClaudeBackend.parseResponseStream` precisely:
    ///   1. `content_block_start` with thinking signature → `.thinkingSignature`
    ///   2. `content_block_start` with type=tool_use → flush thinking +
    ///      `.toolCallStart` + record index
    ///   3. `content_block_delta` with input_json_delta → `.toolCallArgumentsDelta`
    ///   4. `content_block_stop` on a tool_use index → finalise that call
    ///   5. `content_block_delta` with signature_delta → `.thinkingSignature`
    ///   6. thinking_delta / text_delta via handler.extractEvents →
    ///      `.thinkingToken` (mark open) / `.token` (flush thinking)
    ///   7. whole-message `{type:"message", content:[…]}` with embedded
    ///      tool_use blocks → flush + uniform start/delta/call triples
    ///   8. usage on `message_start` / `message_delta` → `.usage`
    public func consume(payload: String) -> [GenerationEvent] {
        var out: [GenerationEvent] = []

        let eventType = ClaudePayloadParser.parseEventType(from: payload)

        // 1. Thinking-block start that opportunistically carries a signature
        //    on the start event itself (a couple of beta endpoints; harmless
        //    when also followed by a signature_delta).
        if eventType == "content_block_start",
           let signature = ClaudePayloadParser.parseThinkingBlockStartSignature(from: payload) {
            out.append(.thinkingSignature(signature))
            return out
        }

        // 2. tool_use content_block_start.
        if eventType == "content_block_start",
           let toolStart = ClaudePayloadParser.parseToolUseBlockStart(from: payload) {
            flushThinking(into: &out)
            let key = "\(toolStart.index)"
            toolAccumulator.upsert(key: key, id: toolStart.id, name: toolStart.name, argumentsDelta: nil)
            toolUseIndexes.insert(toolStart.index)
            out.append(.toolCallStart(callId: toolStart.id, name: toolStart.name))
            toolAccumulator.markStarted(key: key)
            return out
        }

        // 3. input_json_delta.
        if eventType == "content_block_delta",
           let inputDelta = ClaudePayloadParser.parseInputJSONDelta(from: payload) {
            let key = "\(inputDelta.index)"
            toolAccumulator.upsert(key: key, id: nil, name: nil, argumentsDelta: inputDelta.partialJSON)
            let resolvedId = toolAccumulator.resolvedId(forKey: key)
            if !inputDelta.partialJSON.isEmpty {
                out.append(.toolCallArgumentsDelta(callId: resolvedId, textDelta: inputDelta.partialJSON))
                toolUseEmittedDelta.insert(inputDelta.index)
            }
            return out
        }

        // 4. content_block_stop on a tool_use index → finalise.
        if eventType == "content_block_stop",
           let stopIndex = ClaudePayloadParser.parseContentBlockIndex(from: payload),
           toolUseIndexes.contains(stopIndex) {
            finaliseToolUse(at: stopIndex, into: &out)
            return out
        }

        // 5. signature_delta inside the thinking block.
        if eventType == "content_block_delta",
           let signature = ClaudePayloadParser.parseSignatureDelta(from: payload) {
            out.append(.thinkingSignature(signature))
            return out
        }

        // 6. Thinking + plain text deltas — route via the stateless handler
        //    surface (it classifies thinking_delta vs. text_delta in one
        //    place) and gate the thinking-handoff transition here.
        let handlerEvents = CloudPayloadHandler.claude.extractEvents(from: payload)
        for event in handlerEvents {
            switch event {
            case .thinkingToken:
                out.append(event)
                thinking.open()
            case .token:
                flushThinking(into: &out)
                out.append(event)
            default:
                out.append(event)
            }
        }

        // 7. Whole-message tool_use shape — synthesised replay payloads that
        //    deliver the entire `content[]` array in one frame.
        if !emittedWholeMessageToolCalls,
           let wholeCalls = ClaudePayloadParser.parseWholeMessageToolUseBlocks(from: payload),
           !wholeCalls.isEmpty {
            flushThinking(into: &out)
            emittedWholeMessageToolCalls = true
            for call in wholeCalls {
                let key = "whole-\(call.id.isEmpty ? UUID().uuidString : call.id)"
                toolAccumulator.upsert(key: key, id: call.id, name: call.name, argumentsDelta: call.serializedInput)
                let resolvedId = toolAccumulator.resolvedId(forKey: key)
                out.append(.toolCallStart(callId: resolvedId, name: call.name))
                toolAccumulator.markStarted(key: key)
                out.append(.toolCallArgumentsDelta(callId: resolvedId, textDelta: call.serializedInput))
                out.append(.toolCall(ToolCall(id: resolvedId, toolName: call.name, arguments: call.serializedInput)))
            }
        }

        // 8. Usage. Claude splits the counts across two frames:
        //    `message_start` carries `input_tokens` (the prompt half) and
        //    `message_delta` carries `output_tokens` (the completion half).
        //    `extractUsage` returns each half independently; we merge them
        //    so consumers see a single `.usage(prompt, completion)` event
        //    once both halves have arrived. This mirrors the inline
        //    `ClaudeBackend.parseResponseStream` semantics (which got the
        //    same merge for free via `SSECloudBackend.handleUsage`'s
        //    bookkeeping).
        if let usage = CloudPayloadHandler.claude.extractUsage(from: payload) {
            if let prompt = usage.promptTokens {
                pendingPromptTokens = prompt
            }
            if let completion = usage.completionTokens,
               let prompt = pendingPromptTokens,
               !emittedUsage {
                out.append(.usage(prompt: prompt, completion: completion))
                emittedUsage = true
            }
        }

        // Prompt-cache hit/creation counts (Anthropic-only; message_start
        // only). Logged at debug for operator visibility — matches the
        // inline parser's behaviour and remains side-effect-only (no event
        // surface today; structured exposure tracked in TokenUsage
        // extension work).
        if let cacheUsage = ClaudePayloadParser.parseCacheUsage(from: payload) {
            Log.inference.debug(
                "Claude prompt cache: creation=\(cacheUsage.cacheCreationInputTokens) read=\(cacheUsage.cacheReadInputTokens)"
            )
        }

        return out
    }

    /// Flushes pending state at stream end. Yields a trailing
    /// `.thinkingComplete` if a thinking block is still open, and finalises
    /// any tool_use indices that never received their own
    /// `content_block_stop` (truncated upstream, hangup).
    ///
    /// Pass `cancelled: true` to suppress the tool-call finalisation —
    /// dropping the consumer mid-stream must not produce calls the model
    /// didn't actually commit to.
    public func finish(cancelled: Bool = false) -> [GenerationEvent] {
        var out: [GenerationEvent] = []
        flushThinking(into: &out)
        guard !cancelled else { return out }
        for index in toolUseIndexes.sorted() where !toolUseFinalized.contains(index) {
            finaliseToolUse(at: index, into: &out)
        }
        return out
    }

    // MARK: - Internal helpers

    private func flushThinking(into out: inout [GenerationEvent]) {
        guard thinking.isOpen else { return }
        out.append(.thinkingComplete)
        thinking = ThinkingBlockManager()
    }

    private func finaliseToolUse(at index: Int, into out: inout [GenerationEvent]) {
        guard !toolUseFinalized.contains(index) else { return }
        let key = "\(index)"
        guard let entry = toolAccumulator.entriesByKey[key], !entry.name.isEmpty else { return }
        let resolvedId = !entry.id.isEmpty ? entry.id : "claude-call-\(key)"
        if !toolUseEmittedDelta.contains(index) {
            out.append(.toolCallArgumentsDelta(callId: resolvedId, textDelta: "{}"))
            toolUseEmittedDelta.insert(index)
        }
        let args = entry.arguments.isEmpty ? "{}" : entry.arguments
        out.append(.toolCall(ToolCall(id: resolvedId, toolName: entry.name, arguments: args)))
        toolUseFinalized.insert(index)
    }
}

// MARK: - Factory on CloudPayloadHandler

public extension CloudPayloadHandler {
    /// Returns a fresh per-stream consumer for the Anthropic Messages API
    /// wire shape. Returns `nil` for non-Claude cases (mirrors
    /// ``makeOpenAIStreamConsumer()``).
    func makeClaudeStreamConsumer() -> ClaudeStreamEventExtractor? {
        switch self {
        case .claude:
            return ClaudeStreamEventExtractor()
        default:
            return nil
        }
    }
}
#endif
