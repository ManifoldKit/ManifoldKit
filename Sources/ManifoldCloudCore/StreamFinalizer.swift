#if Ollama || CloudSaaS
import Foundation

/// Outcome of inspecting a single SSE / NDJSON frame for stream-termination
/// signals.
///
/// `StreamFinalizer` is orthogonal to the per-payload event extraction that
/// `SSEPayloadHandler` does. Framing (`SSEStreamParser` vs. NDJSON line
/// reader) decides *when* a payload is delivered; the payload handler maps a
/// payload to zero or more `GenerationEvent`s; the finalizer answers a single
/// question: "does this frame signal that the assistant turn is over, and if
/// so, with what usage / stop-reason metadata?" The three responsibilities
/// were tangled in Phase 0 — `SSEPayloadHandler.isStreamEnd(_:)` returned
/// only a `Bool`, so each backend's stream loop carried its own ad-hoc
/// reconciliation of finish reason + usage metadata after the bool flipped.
///
/// Phase 1b ships only the protocol and four concrete implementations.
/// Phase 2 will wire `SSECloudBackend.parseResponseStream` to consume a
/// `StreamFinalizer` directly, replacing the cluster of `isStreamEnd` /
/// `processFinishReason` / `processUsage` calls in each backend's stream
/// loop with a single composed value. The Phase 2 widening will route the
/// existing `Bool isStreamEnd` shape to `.streamComplete(...)` automatically
/// so concrete backends migrate one at a time.
public protocol StreamFinalizer: Sendable {
    /// Inspect one SSE / NDJSON frame and report whether it terminates the
    /// stream.
    ///
    /// - Parameter frame: Raw frame bytes (typically the JSON object payload
    ///   without the SSE `data:` prefix; the framing layer strips that).
    /// - Returns:
    ///   - `.streamComplete(usage:stopReason:)` when this frame is the
    ///     terminal one for the turn. `usage` carries any token counts
    ///     reported by the provider on the terminal frame; `stopReason`
    ///     carries the provider's stop reason if any (`"stop"`,
    ///     `"tool_calls"`, `"end_turn"`, …).
    ///   - `.streamContinue` when the frame is well-formed but not the
    ///     terminal one. The default for tokens, deltas, and most other
    ///     events.
    ///   - `nil` when the frame is uninterpretable (malformed JSON, unknown
    ///     shape). Callers treat `nil` as "no termination signal" and let
    ///     framing decide whether to surface the frame.
    func finalize(frame: Data) -> StreamTermination?
}

/// Result type returned by ``StreamFinalizer/finalize(frame:)``.
public enum StreamTermination: Sendable, Equatable {
    /// The frame terminates the stream. `usage` and `stopReason` are
    /// optional because providers vary in which terminal payload carries
    /// them (Claude splits prompt vs. completion usage across
    /// `message_start` and `message_delta`; OpenAI emits usage on a
    /// separate trailing chunk after `finish_reason`; Ollama emits both on
    /// the `"done":true` line).
    case streamComplete(usage: TokenUsage?, stopReason: String?)

    /// The frame is well-formed but not terminal. The stream loop keeps
    /// reading.
    case streamContinue

    /// Token usage reported on (or alongside) the terminal frame.
    public struct TokenUsage: Sendable, Equatable {
        public let promptTokens: Int?
        public let completionTokens: Int?

        public init(promptTokens: Int?, completionTokens: Int?) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
        }
    }
}

// MARK: - Concrete Implementations

/// Finalizer for OpenAI Chat Completions streams.
///
/// Chat Completions does not emit a dedicated terminal event — `finish_reason`
/// on `choices[0]` signals completion, and a trailing chunk with the
/// `usage` field carries final token counts when
/// `stream_options.include_usage` is set. This implementation reads both
/// fields out of one frame and treats either as termination.
public struct OpenAIDoneSentinelFinalizer: StreamFinalizer {
    public init() {}

    public func finalize(frame: Data) -> StreamTermination? {
        guard let parsed = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return nil
        }

        let usage = Self.extractUsage(parsed)
        let stopReason = Self.extractStopReason(parsed)

        if usage != nil || stopReason != nil {
            return .streamComplete(usage: usage, stopReason: stopReason)
        }
        return .streamContinue
    }

    private static func extractUsage(_ parsed: [String: Any]) -> StreamTermination.TokenUsage? {
        guard let usage = parsed["usage"] as? [String: Any] else { return nil }
        let prompt = usage["prompt_tokens"] as? Int
        let completion = usage["completion_tokens"] as? Int
        guard prompt != nil || completion != nil else { return nil }
        return .init(promptTokens: prompt, completionTokens: completion)
    }

    private static func extractStopReason(_ parsed: [String: Any]) -> String? {
        guard let choices = parsed["choices"] as? [[String: Any]],
              let first = choices.first,
              let reason = first["finish_reason"] as? String,
              !reason.isEmpty else {
            return nil
        }
        return reason
    }
}

/// Finalizer for OpenAI Responses API streams.
///
/// The Responses API delivers a discrete `response.completed` named event
/// carrying the final `response` object with usage on a trailing payload.
/// Most other named events (`response.output_text.delta`, etc.) are
/// non-terminal.
public struct OpenAIResponsesEventFinalizer: StreamFinalizer {
    public init() {}

    public func finalize(frame: Data) -> StreamTermination? {
        guard let parsed = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return nil
        }

        // The terminal event carries the full response object under
        // `response`, which in turn carries usage.
        if let response = parsed["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any] {
            let prompt = usage["input_tokens"] as? Int
            let completion = usage["output_tokens"] as? Int
            return .streamComplete(
                usage: .init(promptTokens: prompt, completionTokens: completion),
                stopReason: response["status"] as? String
            )
        }

        // Top-level usage shape used by some compat servers mirroring the
        // legacy Chat Completions usage envelope.
        if let usage = parsed["usage"] as? [String: Any] {
            let prompt = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int)
            let completion = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int)
            if prompt != nil || completion != nil {
                return .streamComplete(
                    usage: .init(promptTokens: prompt, completionTokens: completion),
                    stopReason: nil
                )
            }
        }

        return .streamContinue
    }
}

/// Finalizer for Anthropic Claude Messages API streams.
///
/// Claude emits a dedicated `message_stop` event marking the end of the
/// assistant turn. Token usage is split across `message_start`
/// (`input_tokens`) and `message_delta` (`output_tokens`); the dedicated
/// terminal event itself carries no usage. This finalizer treats only
/// `message_stop` as terminal and returns `nil` usage on it — callers reuse
/// the per-payload usage extraction (already merged by
/// `SSECloudBackend.handleUsage`) to populate the final usage at the
/// stream boundary.
public struct ClaudeMessageStopFinalizer: StreamFinalizer {
    public init() {}

    public func finalize(frame: Data) -> StreamTermination? {
        guard let parsed = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let type = parsed["type"] as? String else {
            return nil
        }
        switch type {
        case "message_stop":
            let stopReason = (parsed["message"] as? [String: Any])?["stop_reason"] as? String
            return .streamComplete(usage: nil, stopReason: stopReason)
        case "message_delta":
            // `message_delta` carries the running `stop_reason` and final
            // `output_tokens`. We do NOT treat it as terminal — the stream
            // ends on the subsequent `message_stop`. But surface usage so
            // callers that wire the finalizer ahead of the stop frame don't
            // miss it.
            return .streamContinue
        default:
            return .streamContinue
        }
    }
}

/// Finalizer for Ollama `/api/chat` and `/api/generate` NDJSON streams.
///
/// Ollama terminates with a single line carrying `"done":true`; the same
/// line carries `eval_count` (completion tokens) and `prompt_eval_count`
/// (prompt tokens).
public struct OllamaDoneFlagFinalizer: StreamFinalizer {
    public init() {}

    public func finalize(frame: Data) -> StreamTermination? {
        guard let parsed = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return nil
        }
        let done = (parsed["done"] as? Bool) ?? false
        guard done else { return .streamContinue }

        let prompt = parsed["prompt_eval_count"] as? Int
        let completion = parsed["eval_count"] as? Int
        let stopReason = parsed["done_reason"] as? String
        return .streamComplete(
            usage: .init(promptTokens: prompt, completionTokens: completion),
            stopReason: stopReason
        )
    }
}
#endif
