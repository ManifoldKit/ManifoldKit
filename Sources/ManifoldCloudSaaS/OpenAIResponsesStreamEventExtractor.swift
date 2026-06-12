import Foundation
import ManifoldInference
import ManifoldCloudCore

/// Stateful per-stream event extractor for the OpenAI Responses API wire
/// shape.
///
/// The Responses stream is a sequence of *named* SSE events
/// (`event: response.<kind>` paired with a `data:` JSON body). The
/// dispatch is keyed off the event name because two events
/// (`response.output_text.delta` and
/// `response.reasoning_summary_text.delta`) carry identically-shaped
/// `{"delta":"..."}` bodies — the name is the only signal that
/// distinguishes visible content from reasoning summary text. The
/// extractor consumes envelopes produced by ``NamedSSETransport`` so the
/// event name rides each frame.
///
/// ### Why this lives next to ``OpenAIResponsesBackend``
///
/// Phase 2/B/iii/δ migrated `OpenAIBackend` (Chat Completions) onto the
/// `CloudStreamEventConsumer` seam; Phase 3/Responses (this file) does
/// the same for the Responses API so the audit allowlist can drop
/// `OpenAIResponsesBackend.swift`. The extractor is a near-direct port of
/// the inline `OpenAIResponsesBackend.parseResponseStream` switch — same
/// event-name vocabulary, same accumulator semantics, same tool-call
/// finalisation model (batch-emit `.toolCall` on `response.completed` so
/// parallel calls land in insertion order).
///
/// ### Reasoning is summarised, not raw
///
/// Unlike Anthropic's `thinking_delta` blocks (signed, must round-trip on
/// the next tool-use turn), the Responses API exposes reasoning as a
/// post-hoc *summary* the server generates and discards. Emit it as
/// ``GenerationEvent/thinkingToken(_:)`` (and a single
/// ``GenerationEvent/thinkingCompleted`` on the transition to visible
/// content) — there is no signature to preserve.
///
/// ### Lifecycle
///
/// Create one extractor per generation; the envelope calls
/// ``consume(payload:)`` for each `NamedSSETransport` frame and
/// ``finish(cancelled:)`` exactly once at stream end (after either
/// natural completion or a thrown error) so any open thinking block
/// flushes and any tool calls the upstream didn't finalise via
/// `response.completed` still emit.
///
/// ### Parity with the inline path
///
/// The emission order, accumulator semantics, and finalisation guard
/// match ``OpenAIResponsesBackend``'s `handleEvent` cluster one-for-one.
/// The parity suite (`OpenAIResponsesStreamEventExtractorParityTests`)
/// drives the same SSE fixtures through both paths and asserts equal
/// event sequences.
public final class OpenAIResponsesStreamEventExtractor: CloudStreamEventConsumer, @unchecked Sendable {

    private var thinking = ThinkingBlockManager()

    /// Tool-call accumulator keyed by `item_id` (the Responses API's
    /// streaming handle for one function-call item). The accumulator
    /// stores the `call_id` (the value the model uses to refer to this
    /// call, and the value we feed back into
    /// `function_call_output.call_id` on the follow-up turn) under
    /// `entry.id` so `.toolCallStart` / `.toolCallArgumentsDelta` /
    /// `.toolCall` are emitted with the call_id end-to-end.
    private let toolAccumulator = StreamingArgumentAccumulator()

    /// One-shot guard. `.toolCall` events emit at most once per stream so
    /// a `response.completed` + a stream-end fallback can't both fire the
    /// finalisation.
    private var finalisedToolCalls = false

    public init() {}

    // MARK: - Per-frame event extraction

    /// Returns the event sequence to emit for `payload`, where `payload`
    /// is a `NamedSSETransport` envelope. Order mirrors the inline
    /// dispatcher in ``OpenAIResponsesBackend/parseResponseStream(bytes:config:continuation:)``:
    ///   1. `response.reasoning_summary_text.delta` → `.thinkingToken` +
    ///      mark thinking open
    ///   2. `response.reasoning_summary_text.done` → flush thinking (if
    ///      open)
    ///   3. `response.output_text.delta` → flush thinking + `.token`
    ///   4. `response.output_item.added` (function_call item) → flush
    ///      thinking + `.toolCallStart`
    ///   5. `response.function_call_arguments.delta` →
    ///      `.toolCallArgumentsDelta`
    ///   6. `response.function_call_arguments.done` → no-op (batch
    ///      emission on `response.completed` keeps parallel calls in
    ///      insertion order)
    ///   7. `response.completed` → flush thinking, `.usage`, finalise
    ///      buffered tool calls (`.toolCall` × N)
    ///   8. unknown event names → ignored (Responses API ships structural
    ///      events such as `response.content_part.added` we don't need)
    public func consume(payload: String) -> [GenerationEvent] {
        guard let envelope = NamedSSETransport.unwrap(envelope: payload) else {
            return []
        }
        return events(forEvent: envelope.name, data: envelope.data)
    }

    /// Flushes pending state at stream end. Yields a trailing
    /// `.thinkingCompleted` if a thinking block is still open and finalises
    /// any buffered tool calls the upstream didn't accompany with a
    /// `response.completed`.
    ///
    /// Pass `cancelled: true` to suppress phantom tool-call emission —
    /// dropping the consumer mid-stream must not produce calls the model
    /// didn't actually commit to.
    public func finish(cancelled: Bool = false) -> [GenerationEvent] {
        var out: [GenerationEvent] = []
        flushThinking(into: &out)
        if !cancelled {
            appendFinalisedToolCalls(into: &out)
        }
        return out
    }

    // MARK: - Per-event dispatch

    func events(forEvent name: String, data: String) -> [GenerationEvent] {
        var out: [GenerationEvent] = []
        switch OpenAIResponsesBackend.ResponsesEventKind(name: name) {
        case .reasoningDelta:
            for event in OpenAIResponsesBackend.eventsForReasoningDelta(data: data) {
                out.append(event)
                if case .thinkingToken = event { thinking.open() }
            }
        case .reasoningDone:
            flushThinking(into: &out)
        case .outputTextDelta:
            let textEvents = OpenAIResponsesBackend.eventsForOutputTextDelta(data: data)
            if !textEvents.isEmpty {
                flushThinking(into: &out)
                out.append(contentsOf: textEvents)
            }
        case .outputItemAdded:
            if let info = OpenAIResponsesBackend.parseFunctionCallItem(from: data) {
                flushThinking(into: &out)
                toolAccumulator.upsert(
                    key: info.itemId,
                    id: info.callId,
                    name: info.name,
                    argumentsDelta: nil
                )
                if !info.name.isEmpty {
                    out.append(.toolCallStart(callId: info.callId, name: info.name))
                    toolAccumulator.markStarted(key: info.itemId)
                }
            }
        case .functionCallArgumentsDelta:
            if let info = OpenAIResponsesBackend.parseFunctionCallArgumentsDelta(from: data) {
                toolAccumulator.upsert(
                    key: info.itemId,
                    id: nil,
                    name: nil,
                    argumentsDelta: info.delta
                )
                if !info.delta.isEmpty {
                    let resolvedId = toolAccumulator.resolvedId(forKey: info.itemId)
                    out.append(.toolCallArgumentsDelta(
                        callId: resolvedId,
                        textDelta: info.delta
                    ))
                }
            }
        case .functionCallArgumentsDone:
            // Batch-emit on `response.completed` (see appendFinalisedToolCalls)
            // so parallel calls preserve insertion order.
            break
        case .completed:
            flushThinking(into: &out)
            if let usage = OpenAIResponsesBackend.parseUsage(from: data) {
                if let prompt = usage.promptTokens,
                   let completion = usage.completionTokens {
                    out.append(.usage(prompt: prompt, completion: completion))
                }
            }
            appendFinalisedToolCalls(into: &out)
        case .error:
            // Surface as a thrown error from the consumer's perspective is
            // not part of the protocol surface; the envelope detects the
            // error event via the handler's `extractStreamError` shim.
            // Drop here to keep `consume` total.
            break
        case .unknown:
            break
        }
        return out
    }

    // MARK: - Internal helpers

    private func flushThinking(into out: inout [GenerationEvent]) {
        guard thinking.isOpen else { return }
        out.append(.thinkingCompleted)
        thinking = ThinkingBlockManager()
    }

    private func appendFinalisedToolCalls(into out: inout [GenerationEvent]) {
        guard !finalisedToolCalls else { return }
        guard !toolAccumulator.entriesByKey.isEmpty else {
            // Mark the guard even with no entries so a stream-end fallback
            // after a clean `response.completed` (zero tool calls) doesn't
            // need to re-check.
            finalisedToolCalls = true
            return
        }
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
    /// Returns a fresh per-stream consumer for the OpenAI Responses API
    /// wire shape. Returns `nil` for cases that route through different
    /// consumer surfaces (`.openAI` → `makeOpenAIStreamConsumer()`).
    func makeOpenAIResponsesStreamConsumer() -> OpenAIResponsesStreamEventExtractor? {
        guard provider == .openAIResponses else { return nil }
        return OpenAIResponsesStreamEventExtractor()
    }
}
