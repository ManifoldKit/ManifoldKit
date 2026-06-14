import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

// MARK: - ClaudePayloadParser (moved from ClaudePayloadParser.swift, Phase 5)

/// Stateless parser for Anthropic Messages API SSE payloads.
///
/// Moved inline from the now-deleted `ClaudePayloadParser.swift`. Kept as an
/// internal enum so `CloudPayloadHandler`'s `ClaudePayloadParsingDispatch`
/// shim (in the same module) can still call into it. The `ClaudePayloadHandler`
/// compatibility shim that lived alongside it was also deleted — callers use
/// `CloudPayloadHandler.claude` directly.
enum ClaudePayloadParser {
    struct ToolUseBlockStart {
        let index: Int
        let id: String
        let name: String
    }

    struct InputJSONDelta {
        let index: Int
        let partialJSON: String
    }

    struct WholeToolUseBlock {
        let id: String
        let name: String
        let serializedInput: String
    }

    static func parseEventType(from json: String) -> String? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseEventType(from: parsed)
    }

    static func parseEventType(from json: JSONValue) -> String? {
        json["type"]?.stringValue
    }

    static func parseToolUseBlockStart(from json: String) -> ToolUseBlockStart? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseToolUseBlockStart(from: parsed)
    }

    static func parseToolUseBlockStart(from json: JSONValue) -> ToolUseBlockStart? {
        guard json["type"]?.stringValue == "content_block_start",
              let index = json["index"]?.intValue,
              let block = json["content_block"]?.objectValue,
              block["type"]?.stringValue == "tool_use",
              let id = block["id"]?.stringValue, !id.isEmpty,
              let name = block["name"]?.stringValue, !name.isEmpty else {
            return nil
        }
        return ToolUseBlockStart(index: index, id: id, name: name)
    }

    static func parseInputJSONDelta(from json: String) -> InputJSONDelta? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseInputJSONDelta(from: parsed)
    }

    static func parseInputJSONDelta(from json: JSONValue) -> InputJSONDelta? {
        guard json["type"]?.stringValue == "content_block_delta",
              let index = json["index"]?.intValue,
              let delta = json["delta"]?.objectValue,
              delta["type"]?.stringValue == "input_json_delta",
              let partial = delta["partial_json"]?.stringValue else {
            return nil
        }
        return InputJSONDelta(index: index, partialJSON: partial)
    }

    static func parseContentBlockIndex(from json: String) -> Int? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseContentBlockIndex(from: parsed)
    }

    static func parseContentBlockIndex(from json: JSONValue) -> Int? {
        json["index"]?.intValue
    }

    static func parseWholeMessageToolUseBlocks(from json: String) -> [WholeToolUseBlock]? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseWholeMessageToolUseBlocks(from: parsed)
    }

    static func parseWholeMessageToolUseBlocks(from json: JSONValue) -> [WholeToolUseBlock]? {
        guard json["type"]?.stringValue == "message",
              let content = json["content"]?.objectArrayValue else {
            return nil
        }
        var result: [WholeToolUseBlock] = []
        for block in content {
            guard block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue, !id.isEmpty,
                  let name = block["name"]?.stringValue, !name.isEmpty else {
                continue
            }
            let input = block["input"] ?? .object([:])
            result.append(WholeToolUseBlock(id: id, name: name, serializedInput: serializeInputObject(input)))
        }
        return result
    }

    static func parseThinkingBlockStartSignature(from json: String) -> String? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseThinkingBlockStartSignature(from: parsed)
    }

    static func parseThinkingBlockStartSignature(from json: JSONValue) -> String? {
        guard json["type"]?.stringValue == "content_block_start",
              let block = json["content_block"]?.objectValue,
              block["type"]?.stringValue == "thinking",
              let signature = block["signature"]?.stringValue,
              !signature.isEmpty else {
            return nil
        }
        return signature
    }

    static func parseSignatureDelta(from json: String) -> String? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseSignatureDelta(from: parsed)
    }

    static func parseSignatureDelta(from json: JSONValue) -> String? {
        guard json["type"]?.stringValue == "content_block_delta",
              let delta = json["delta"]?.objectValue,
              delta["type"]?.stringValue == "signature_delta",
              let signature = delta["signature"]?.stringValue,
              !signature.isEmpty else {
            return nil
        }
        return signature
    }

    static func parseThinkingDelta(from json: String) -> String? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseThinkingDelta(from: parsed)
    }

    static func parseThinkingDelta(from json: JSONValue) -> String? {
        guard json["type"]?.stringValue == "content_block_delta",
              let delta = json["delta"]?.objectValue,
              delta["type"]?.stringValue == "thinking_delta",
              let thinking = delta["thinking"]?.stringValue else {
            return nil
        }
        return thinking
    }

    static func parseToken(from json: String) -> String? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseToken(from: parsed)
    }

    static func parseToken(from json: JSONValue) -> String? {
        guard json["type"]?.stringValue == "content_block_delta",
              let delta = json["delta"]?.objectValue,
              let text = delta["text"]?.stringValue else {
            return nil
        }
        return text
    }

    static func parseIsStreamEnd(_ json: String) -> Bool {
        guard let parsed = JSONValue.parse(string: json) else { return false }
        return parsed["type"]?.stringValue == "message_stop"
    }

    struct CacheUsage {
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int
    }

    static func parseUsage(from json: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseUsage(from: parsed)
    }

    static func parseUsage(from json: JSONValue) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let type = json["type"]?.stringValue else { return nil }

        switch type {
        case "message_start":
            guard let message = json["message"]?.objectValue,
                  let usage = message["usage"]?.objectValue,
                  let inputTokens = usage["input_tokens"]?.intValue else {
                return nil
            }
            return (promptTokens: inputTokens, completionTokens: nil)
        case "message_delta":
            guard let usage = json["usage"]?.objectValue,
                  let outputTokens = usage["output_tokens"]?.intValue else {
                return nil
            }
            return (promptTokens: nil, completionTokens: outputTokens)
        default:
            return nil
        }
    }

    /// Parses Anthropic prompt-cache token counts from a `message_start` payload.
    ///
    /// Both fields default to 0 when absent — an absent field means no cache
    /// activity occurred, not a parse failure, so we treat them as optional
    /// with a zero fallback rather than nil-gating the whole result.
    static func parseCacheUsage(from json: String) -> CacheUsage? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseCacheUsage(from: parsed)
    }

    static func parseCacheUsage(from json: JSONValue) -> CacheUsage? {
        guard json["type"]?.stringValue == "message_start",
              let message = json["message"]?.objectValue,
              let usage = message["usage"]?.objectValue else {
            return nil
        }
        let creation = usage["cache_creation_input_tokens"]?.intValue ?? 0
        let read = usage["cache_read_input_tokens"]?.intValue ?? 0
        // Only materialise a CacheUsage when there is actual cache activity to
        // report — avoids a debug log on every non-cached turn.
        guard creation > 0 || read > 0 else { return nil }
        return CacheUsage(cacheCreationInputTokens: creation, cacheReadInputTokens: read)
    }

    static func parseStreamError(from json: String) -> CloudBackendError? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseStreamError(from: parsed)
    }

    static func parseStreamError(from json: JSONValue) -> CloudBackendError? {
        guard json["type"]?.stringValue == "error",
              let error = json["error"]?.objectValue,
              let message = error["message"]?.stringValue else {
            return nil
        }
        return .sanitizedParseError(message)
    }

    private static func serializeInputObject(_ value: JSONValue) -> String {
        let foundationValue = value.foundationObject
        guard JSONSerialization.isValidJSONObject(foundationValue) else {
            return "{}"
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: foundationValue, options: [])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            Log.inference.warning(
                "ClaudePayloadParser: tool_use.input could not be re-serialised — falling back to empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return "{}"
        }
    }
}

/// Stateful per-stream event extractor for the Anthropic Messages API wire
/// shape.
///
/// The stateless ``CloudPayloadHandler/claude`` `extractEvents(from:)`
/// surface can only emit the events whose decision is local to one frame
/// (`.token`, `.thinkingToken`). The full Claude event vocabulary —
/// `.toolCallStart` / `.toolCallArgumentsDelta` / `.toolCall`,
/// `.thinkingSignature`, `.thinkingCompleted` transition, `.usage` — requires
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
    // emit a single `.usage(TokenUsage)` event on the
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
        guard let json = JSONValue.parse(string: payload) else { return [] }
        return consume(json: json)
    }

    /// Parse-once entry point. Reads the already-parsed frame; the
    /// stringly-typed ``consume(payload:)`` is a thin wrapper retained for
    /// legacy callers and per-payload tests.
    public func consume(frame: ParsedFrame) -> [GenerationEvent] {
        guard let json = frame.json else { return [] }
        return consume(json: json)
    }

    private func consume(json payload: JSONValue) -> [GenerationEvent] {
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
        let handlerEvents = Self.claudeHandlerEvents(from: payload)
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
        //    so consumers see a single `.usage(TokenUsage)` event
        //    once both halves have arrived. This mirrors the inline
        //    `ClaudeBackend.parseResponseStream` semantics (which got the
        //    same merge for free via `SSECloudBackend.handleUsage`'s
        //    bookkeeping).
        if let usage = ClaudePayloadParser.parseUsage(from: payload) {
            if let prompt = usage.promptTokens {
                pendingPromptTokens = prompt
            }
            if let completion = usage.completionTokens,
               let prompt = pendingPromptTokens,
               !emittedUsage {
                out.append(.usage(TokenUsage(promptTokens: prompt, completionTokens: completion)))
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
    /// `.thinkingCompleted` if a thinking block is still open, and finalises
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

    /// Parse-once mirror of ``ClaudeMessagesPayloadHandler/extractEvents(from:)``
    /// — thinking_delta → `.thinkingToken`, text_delta → `.token`. Kept here
    /// so the extractor reads off the already-parsed frame instead of
    /// round-tripping through the stringly-typed handler surface.
    private static func claudeHandlerEvents(from json: JSONValue) -> [GenerationEvent] {
        if let thinking = ClaudePayloadParser.parseThinkingDelta(from: json) {
            return [.thinkingToken(thinking)]
        }
        if let token = ClaudePayloadParser.parseToken(from: json) {
            return [.token(token)]
        }
        return []
    }

    private func flushThinking(into out: inout [GenerationEvent]) {
        guard thinking.isOpen else { return }
        out.append(.thinkingCompleted)
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
        guard provider == .claude else { return nil }
        return ClaudeStreamEventExtractor()
    }
}
