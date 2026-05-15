#if Ollama || CloudSaaS
import Foundation

/// Splits a raw HTTP response byte stream into discrete payload frames.
///
/// The two cloud wire formats in production today are Server-Sent Events
/// (OpenAI, Claude, OpenAI Responses) and newline-delimited JSON (Ollama).
/// They share the same upstream contract — `URLSession.AsyncBytes` of one
/// HTTP response — and the same downstream contract — a sequence of
/// `Data` payloads each representing one frame the payload handler can
/// decode. `FramedTransport` is the seam that lets `SSECloudBackend` stop
/// branching on the format.
///
/// `Data` is the frame currency rather than `String` so binary-leaning
/// formats (e.g. providers that ship UTF-8-invalid bytes in a `content`
/// field) survive the parse without a lossy decode at the transport
/// layer. The payload handler chooses how to interpret the bytes.
///
/// Implementations are `Sendable` value types so they can compose into
/// the `CloudHTTPProviderAdapter` without locking concerns.
///
/// > Note: This protocol ships in Phase 2 alongside two concrete
/// > implementations (``SSETransport`` and ``NDJSONTransport``).
/// > `SSECloudBackend.parseResponseStream` continues to drive
/// > `SSEStreamParser` / NDJSON line reading directly until Phase 2/B
/// > routes through the adapter; the protocol exists now so adapter
/// > types can compose against it without churn.
public protocol FramedTransport: Sendable {
    /// Convert a raw HTTP byte stream into discrete frame payloads.
    ///
    /// The returned stream yields one payload per frame and finishes when
    /// the upstream byte stream ends. Errors from the byte stream surface
    /// as stream termination (the returned `AsyncStream` does not throw);
    /// the caller is responsible for observing transport errors via the
    /// underlying `URLSession.AsyncBytes` separately.
    func frames(from bytes: URLSession.AsyncBytes) -> AsyncStream<Data>
}
#endif
