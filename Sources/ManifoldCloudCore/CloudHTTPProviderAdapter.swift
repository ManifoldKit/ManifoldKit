import Foundation
import ManifoldInference

/// Composition root for cloud HTTP backends.
///
/// An adapter holds the essential per-provider divergences identified
/// by the cross-backend audit — message encoding, payload handling,
/// error-body decoding, framing transport, stream finalization — plus a
/// static capability declaration. Each is a small `Sendable` value
/// (closed-enum or witness protocol) so the adapter itself is a Sendable
/// value type. `SSECloudBackend` then composes one adapter and stops
/// branching on the provider.
///
/// > Note: An earlier revision of this protocol also declared five
/// > "wire-shape witness" properties (`toolCallShape`, `imageInputShape`,
/// > `structuredOutputShape`, `toolResultEncoding`, `promptCacheShape`).
/// > They were removed in the v0.64 inert-surface sweep: every adapter
/// > constructed a witness, but nothing ever read one back to make an
/// > encoding decision — the wire-encoding logic they were meant to
/// > eventually front still lives directly in each backend's
/// > `buildRequest`/payload-handler pair.
///
/// > Note: Phase 2/A ships the protocol and the OpenAI witness composition
/// > (`OpenAIAdapter`). `SSECloudBackend.parseResponseStream` is **not**
/// > yet routed through `framedTransport` / `streamFinalizer` — each
/// > concrete backend still drives its own parser. Phase 2/B widens the
/// > envelope to consume the adapter end-to-end, at which point the
/// > legacy parser files (`ClaudePayloadParser`, `OllamaPayloadHandler`,
/// > `OllamaStreamProcessor`, `ClaudeToolCallAccumulator`) become dead
/// > and get deleted.
///
/// ### Security invariant
///
/// `buildRequest` returns **only** a `URLRequest`. It never returns a
/// `URLSession` or a `URLSessionDelegate`. Pinning, DNS-rebind validation,
/// redirect-guard installation, and error sanitization all stay
/// envelope-level on `SSECloudBackend`. `SessionConstructionAuditTest`
/// fails CI if any cloud file outside `SSECloudBackend.swift` constructs
/// a `URLSession`.
public protocol CloudHTTPProviderAdapter: Sendable {
    /// How the adapter encodes outbound messages (system prompt, history,
    /// tool definitions, tool results, image content parts).
    var messageEncoder: CloudMessageEncoder { get }

    /// How the adapter interprets inbound SSE / NDJSON payloads.
    var payloadHandler: CloudPayloadHandler { get }

    /// Framing transport (SSE vs. NDJSON). Phase 2/B routes
    /// `parseResponseStream` through this; Phase 2/A keeps the existing
    /// inline parser path.
    var framedTransport: any FramedTransport { get }

    /// Stream-termination decoder.
    var streamFinalizer: any StreamFinalizer { get }

    /// Error-body decoder for non-2xx responses.
    var errorBodyDecoder: any ErrorBodyDecoder { get }

    /// Static capabilities declaration. Backends derive this from the
    /// configured `modelName` and a vendored manifest table; the adapter
    /// stores the resolved value once per `loadModel` cycle.
    var capabilities: BackendCapabilities { get }

    /// Build the per-turn `URLRequest`. Returns only a `URLRequest`;
    /// pinning / DNS guard / redirect guard apply at the envelope.
    func buildRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        history: [StructuredMessage]
    ) throws -> URLRequest

    /// Optional runtime capability probe (e.g. Ollama `/api/show`). The
    /// default returns the static `capabilities` so adapters that don't
    /// probe at runtime get a one-line conformance.
    func probeCapabilities() async throws -> BackendCapabilities
}

extension CloudHTTPProviderAdapter {
    public func probeCapabilities() async throws -> BackendCapabilities {
        capabilities
    }
}
