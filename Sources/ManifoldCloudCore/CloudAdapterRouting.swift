import Foundation
import ManifoldInference

/// Envelope-side projection of a `CloudHTTPProviderAdapter`.
///
/// `SSECloudBackend` consumes this value type so concrete backends can stop
/// branching on the provider — the framing transport, payload handler,
/// stream finalizer, error-body decoder, and request builder ride together
/// as one Sendable bundle. The full `CloudHTTPProviderAdapter` protocol
/// lives in `ManifoldCloud` (where the message encoders and wire-shape
/// witnesses live) but `SSECloudBackend` ships in `ManifoldCloudCore` and
/// must not depend on `ManifoldCloud`. The routing value is the seam: an
/// adapter in `ManifoldCloud` projects itself into a `CloudAdapterRouting`,
/// the backend hands the routing to its `SSECloudBackend` base, and the
/// envelope routes generation through the projected witnesses.
///
/// ### Security invariant (S1)
///
/// `buildRequest` returns **only** a `URLRequest`. The routing never
/// surfaces a `URLSession` or `URLSessionDelegate`. Pinning, DNS-rebind
/// validation, redirect-guard installation, retry, and error sanitization
/// stay envelope-level on `SSECloudBackend`. `SessionConstructionAuditTest`
/// enforces that no cloud file outside `SSECloudBackend.swift` constructs
/// a session.
public struct CloudAdapterRouting: Sendable {

    /// Per-payload event extraction (tokens, usage, stream-end, in-stream
    /// errors). Replaces `SSECloudBackend.payloadHandler` for adapter-routed
    /// backends; the existing `payloadHandler` injected at base init stays
    /// the legacy-path default.
    public let payloadHandler: any SSEPayloadHandler

    /// Framing strategy (SSE vs. NDJSON). The envelope feeds the raw
    /// `URLSession.AsyncBytes` to `framedTransport.frames(from:)` instead
    /// of hardcoding `SSEStreamParser`.
    public let framedTransport: any FramedTransport

    /// Stream-termination decoder. The envelope consults this on each
    /// frame; `.streamComplete` triggers a yield of usage information and
    /// stops the parse loop.
    public let streamFinalizer: any StreamFinalizer

    /// Non-2xx error-body decoder. The envelope sanitizes and surfaces the
    /// decoded message; the decoder is provider-shaped (e.g. Anthropic's
    /// nested `{error: {message: …}}` vs. OpenAI's flat shape).
    public let errorBodyDecoder: any ErrorBodyDecoder

    /// Build the per-turn `URLRequest`. The host (concrete backend)
    /// supplies the closure so it can capture per-call history, auth, and
    /// base URL without leaking those onto the routing value. The envelope
    /// invokes the closure once per generation; pinning + DNS guard wrap
    /// the resulting request.
    public let buildRequest: @Sendable (
        _ prompt: String,
        _ systemPrompt: String?,
        _ config: GenerationConfig
    ) throws -> URLRequest

    /// Optional factory for a stateful per-stream event consumer.
    ///
    /// When non-nil, `SSECloudBackend.parseResponseStreamRouted` invokes
    /// this factory at stream open and drives the resulting consumer with
    /// each decoded frame payload (`consume(payload:)`) followed by a
    /// single terminal `finish(cancelled:)`. The consumer takes over event
    /// emission entirely — neither ``payloadHandler/extractEvents(from:)``
    /// nor the envelope's thinking-handoff bookkeeping run on this path,
    /// because both responsibilities belong to the consumer.
    ///
    /// When nil (default), the envelope falls back to the stateless
    /// per-frame projection through ``payloadHandler``. The OpenAI Chat
    /// Completions backend is the first migration onto this seam (Phase
    /// 2/B/iii/δ); Claude, OpenAI Responses, and Ollama keep their inline
    /// stream loops until Phase 3.
    public let streamConsumerFactory: (@Sendable () -> any CloudStreamEventConsumer)?

    public init(
        payloadHandler: any SSEPayloadHandler,
        framedTransport: any FramedTransport,
        streamFinalizer: any StreamFinalizer,
        errorBodyDecoder: any ErrorBodyDecoder,
        buildRequest: @escaping @Sendable (String, String?, GenerationConfig) throws -> URLRequest,
        streamConsumerFactory: (@Sendable () -> any CloudStreamEventConsumer)? = nil
    ) {
        self.payloadHandler = payloadHandler
        self.framedTransport = framedTransport
        self.streamFinalizer = streamFinalizer
        self.errorBodyDecoder = errorBodyDecoder
        self.buildRequest = buildRequest
        self.streamConsumerFactory = streamConsumerFactory
    }
}
