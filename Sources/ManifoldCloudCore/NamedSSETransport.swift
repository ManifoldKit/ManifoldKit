#if Ollama || CloudSaaS
import Foundation
import ManifoldInference

/// `FramedTransport` over SSE that preserves the named-event field.
///
/// The default ``SSETransport`` strips the `event:` line and yields only
/// each `data:` payload as a `Data` frame. That contract works for the
/// OpenAI Chat Completions and Anthropic Messages streams (the event name
/// is either absent or redundant with the JSON body's `type` field) but
/// not for the OpenAI Responses API, whose dispatch is keyed off the
/// `event:` line — `response.output_text.delta` and
/// `response.reasoning_summary_text.delta` carry identically-shaped
/// `{"delta":"..."}` bodies, so the name is the *only* signal that
/// distinguishes visible content from reasoning summary text.
///
/// To keep `SSECloudBackend`'s routed stream loop oblivious to wire-format
/// nuance, this transport frames each named event as a small JSON envelope:
///
/// ```json
/// {"__event":"response.output_text.delta","__data":"{\"delta\":\"Hi\"}"}
/// ```
///
/// The consumer attached to the routing reads `__event` to pick a handler
/// and parses `__data` as the original event payload. The wrapper keys are
/// prefixed with `__` so they cannot collide with any provider field
/// (provider field names are JSON-identifier-safe but never start with
/// `__`).
///
/// ### Why a wrapper rather than the raw payload
///
/// The `FramedTransport` contract yields `Data` frames; it has no surface
/// for out-of-band metadata. Encoding the event name into the same frame
/// keeps the contract intact and lets a future provider (Gemini, Bedrock)
/// either compose `NamedSSETransport` for named-dispatch wire formats or
/// stay on the plain `SSETransport` if event names are redundant.
public struct NamedSSETransport: FramedTransport {

    /// JSON wrapper key for the SSE `event:` name.
    public static let eventNameKey = "__event"

    /// JSON wrapper key for the SSE `data:` payload (a JSON string, not
    /// the parsed object — the consumer re-parses to get a typed view).
    public static let eventDataKey = "__data"

    private let limits: SSEStreamLimits

    public init(limits: SSEStreamLimits = ManifoldConfiguration.shared.sseStreamLimits) {
        self.limits = limits
    }

    public func frames(from bytes: URLSession.AsyncBytes) -> AsyncStream<Data> {
        let limits = self.limits
        return AsyncStream<Data> { continuation in
            let task = Task {
                let parsed = SSEStreamParser.parseNamed(bytes: bytes, limits: limits)
                do {
                    for try await event in parsed {
                        if Task.isCancelled { break }
                        let envelope: [String: Any] = [
                            Self.eventNameKey: event.name ?? "",
                            Self.eventDataKey: event.data
                        ]
                        if let bytes = try? JSONSerialization.data(withJSONObject: envelope) {
                            continuation.yield(bytes)
                        }
                    }
                } catch {
                    Log.network.debug("NamedSSETransport: parser terminated with \(error.localizedDescription, privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Wrapper accessors
    //
    // Centralised here so the consumer doesn't reinvent the parse, and a
    // wire-format mismatch surfaces as one symbol rename instead of N
    // string-literal edits.

    /// Decodes a `NamedSSETransport` envelope. Returns `nil` if the
    /// payload is not a name-bearing envelope (e.g. a plain SSE payload
    /// from another transport, or malformed JSON).
    public static func unwrap(envelope payload: String) -> (name: String, data: String)? {
        guard let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = parsed[eventNameKey] as? String,
              let inner = parsed[eventDataKey] as? String else {
            return nil
        }
        return (name, inner)
    }

    /// Inner payload accessor for the stream finalizer. The Responses-API
    /// finalizer inspects the `response.completed` event's `response.usage`
    /// — that data lives inside the wrapped `__data` string. This helper
    /// returns the inner JSON as `Data` so a `StreamFinalizer` can parse
    /// it without depending on the wrapper itself.
    public static func unwrapData(frame: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let inner = parsed[eventDataKey] as? String,
              let bytes = inner.data(using: .utf8) else {
            return nil
        }
        return bytes
    }
}
#endif
