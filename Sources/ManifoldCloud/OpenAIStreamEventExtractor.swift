#if CloudSaaS
import Foundation
import ManifoldInference
import ManifoldCloudCore

/// Stateful per-stream event extractor for the OpenAI Chat Completions wire
/// shape.
///
/// The stateless ``CloudPayloadHandler/openAI`` `extractEvents(from:)` surface
/// can only emit the events whose decision is local to one frame
/// (`.token`, `.thinkingToken`). The full OpenAI Chat Completions event
/// vocabulary — `.toolCallStart` / `.toolCallArgumentsDelta` / `.toolCall`,
/// `.usage`, `.prefillProgress`, and the implicit `.thinkingComplete`
/// transition — requires cross-frame state (index-keyed tool-call delta
/// buffers, the open-thinking flag, the once-only tool-call finalisation
/// guard). `OpenAIStreamEventExtractor` owns that state.
///
/// ### Why this lives next to `CloudPayloadHandler.openAI`
///
/// Phase 2/B/iii/β (PR #1266) attempted to flip `OpenAIBackend`'s stream
/// path to the adapter-routed `extractEvents` flow but discovered the
/// stateless handler dropped the tool-call, reasoning-handoff, usage, and
/// prefill events. This extractor closes that gap so the migration in PR
/// #1266 can proceed without behavioural drift.
///
/// ### Lifecycle
///
/// Create one extractor per generation; call ``consume(payload:)`` for each
/// SSE frame; call ``finish()`` exactly once at stream end (after either a
/// natural completion or a thrown error) to flush any open thinking block
/// and yield any buffered tool calls that the upstream never accompanied
/// with an explicit `finish_reason`.
///
/// ### Parity with the inline path
///
/// The emission order, accumulator semantics, and finalisation guard match
/// ``OpenAIBackend``'s `processPayload` cluster one-for-one. The parity
/// test (`OpenAIStreamEventExtractorParityTests`) drives both paths through
/// the on-disk fixtures and asserts equal event sequences.
public final class OpenAIStreamEventExtractor: CloudStreamEventConsumer, @unchecked Sendable {

    private var thinking = ThinkingBlockManager()
    private let toolAccumulator = StreamingArgumentAccumulator()
    /// One-shot guard. `.toolCall` events are emitted at most once per
    /// stream, even when both a streaming `finish_reason: "tool_calls"`
    /// frame and a non-streaming `message.tool_calls[]` whole-call frame
    /// arrive in the same response.
    private var finalisedToolCalls = false

    public init() {}

    // MARK: - Per-frame event extraction

    /// Returns the event sequence to emit for `payload`. Order matches the
    /// inline `OpenAIBackend.processPayload` step order:
    ///   1. prefill-progress (short-circuit; nothing else runs)
    ///   2. reasoning delta → `.thinkingToken` + mark thinking open
    ///   3. visible content → flush thinking + `.token`
    ///   4. streaming tool-call deltas → flush thinking on first sighting,
    ///      then `.toolCallStart` (once per key) + `.toolCallArgumentsDelta`
    ///      per fragment
    ///   5. non-streaming whole tool_calls → flush thinking, emit
    ///      `.toolCallStart` + `.toolCallArgumentsDelta` (whole), and
    ///      finalise immediately
    ///   6. `usage` → `.usage`
    ///   7. `finish_reason` → finalise buffered tool calls (`.toolCall` × N)
    public func consume(payload: String) -> [GenerationEvent] {
        var out: [GenerationEvent] = []

        if let progress = OpenAIChatCompletionsPayloadParsing.parsePrefillProgress(from: payload) {
            out.append(.prefillProgress(
                nPast: progress.nPast,
                nTotal: progress.nTotal,
                tokensPerSecond: progress.tokensPerSecond
            ))
            return out
        }

        if let reasoning = OpenAIChatCompletionsPayloadParsing.parseReasoningDelta(from: payload) {
            out.append(.thinkingToken(reasoning))
            thinking.open()
        }

        if let token = OpenAIChatCompletionsPayloadParsing.extractToken(from: payload) {
            flushThinking(into: &out)
            out.append(.token(token))
        }

        for delta in OpenAIChatCompletionsPayloadParsing.parseToolCallDeltas(from: payload) {
            let key = "\(delta.index)"
            let isNew = toolAccumulator.upsert(
                key: key,
                id: delta.id,
                name: delta.name,
                argumentsDelta: delta.argumentsDelta
            )
            if isNew {
                flushThinking(into: &out)
            }
            if let entry = toolAccumulator.entriesByKey[key],
               !entry.started, !entry.name.isEmpty {
                let resolvedId = toolAccumulator.resolvedId(forKey: key)
                out.append(.toolCallStart(callId: resolvedId, name: entry.name))
                toolAccumulator.markStarted(key: key)
            }
            if let fragment = delta.argumentsDelta, !fragment.isEmpty {
                let resolvedId = toolAccumulator.resolvedId(forKey: key)
                out.append(.toolCallArgumentsDelta(callId: resolvedId, textDelta: fragment))
            }
        }

        if !finalisedToolCalls {
            let wholeCalls = OpenAIChatCompletionsPayloadParsing.parseWholeToolCalls(from: payload)
            if !wholeCalls.isEmpty {
                flushThinking(into: &out)
                for call in wholeCalls {
                    let key = call.id.isEmpty ? UUID().uuidString : call.id
                    toolAccumulator.upsert(
                        key: key,
                        id: call.id,
                        name: call.name,
                        argumentsDelta: call.arguments
                    )
                    let resolvedId = toolAccumulator.resolvedId(forKey: key)
                    out.append(.toolCallStart(callId: resolvedId, name: call.name))
                    toolAccumulator.markStarted(key: key)
                    if !call.arguments.isEmpty {
                        out.append(.toolCallArgumentsDelta(
                            callId: resolvedId,
                            textDelta: call.arguments
                        ))
                    }
                }
            }
        }

        if let usage = OpenAIChatCompletionsPayloadParsing.extractUsage(from: payload),
           let prompt = usage.promptTokens,
           let completion = usage.completionTokens {
            out.append(.usage(prompt: prompt, completion: completion))
        }

        if let reason = OpenAIChatCompletionsPayloadParsing.parseFinishReason(from: payload) {
            if reason == "tool_calls" || !toolAccumulator.entriesByKey.isEmpty {
                appendFinalisedToolCalls(into: &out)
            }
        }

        return out
    }

    /// Flushes pending state at stream end. Yields a trailing
    /// `.thinkingComplete` if a thinking block is still open, and finalises
    /// any buffered tool calls that arrived without an explicit
    /// `finish_reason` (compat servers that close the stream silently).
    ///
    /// Pass `cancelled: true` from a cancellation path to suppress
    /// phantom tool-call emission — dropping the consumer mid-stream must
    /// not produce calls the model didn't actually commit to.
    public func finish(cancelled: Bool = false) -> [GenerationEvent] {
        var out: [GenerationEvent] = []
        flushThinking(into: &out)
        if !cancelled {
            appendFinalisedToolCalls(into: &out)
        }
        return out
    }

    // MARK: - Internal helpers

    private func flushThinking(into out: inout [GenerationEvent]) {
        guard thinking.isOpen else { return }
        out.append(.thinkingComplete)
        thinking = ThinkingBlockManager()
    }

    private func appendFinalisedToolCalls(into out: inout [GenerationEvent]) {
        guard !finalisedToolCalls else { return }
        finalisedToolCalls = true
        for entry in toolAccumulator.finalizedEntries() {
            out.append(.toolCall(ToolCall(
                id: entry.callId,
                toolName: entry.name,
                arguments: entry.arguments
            )))
        }
    }
}

// MARK: - Factory on CloudPayloadHandler

public extension CloudPayloadHandler {
    /// Returns a fresh per-stream consumer for the OpenAI Chat Completions
    /// wire shape. Returns `nil` for cases without per-stream state needs
    /// (Claude/Ollama/Responses handle their cross-frame state inside the
    /// existing per-backend stream loops; those move to dedicated consumers
    /// in Phase 3).
    ///
    /// ### Routing choice (option c)
    ///
    /// Per-stream state lives on a returned reference type rather than
    /// being threaded through the stateless `extractEvents(from:)` enum
    /// surface. `CloudAdapterRouting` itself stays a `Sendable` value
    /// type: the adapter-routed loop in PR #1266 will obtain a consumer
    /// from this factory at stream-open and discard it at stream-end,
    /// keeping the routing bundle stateless and reusable across turns.
    func makeOpenAIStreamConsumer() -> OpenAIStreamEventExtractor? {
        switch self {
        case .openAI:
            return OpenAIStreamEventExtractor()
        default:
            return nil
        }
    }
}
#endif
