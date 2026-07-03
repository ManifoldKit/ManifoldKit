import Foundation
import ManifoldInference
import ManifoldCloudCore

/// `CloudHTTPProviderAdapter` composition for Ollama's native `/api/chat`
/// endpoint. Mirrors ``OpenAIAdapter`` (Phase 2/B), with the Ollama-specific
/// shapes:
///
///   - **Framed transport**: `NDJSONTransport` — Ollama emits one JSON
///     object per line with no `data:` prefix and no `[DONE]` sentinel. The
///     terminal frame carries `"done": true`.
///   - **Stream finalizer**: `OllamaDoneFlagFinalizer` — reads
///     `prompt_eval_count` / `eval_count` / `done_reason` off the terminal
///     `"done":true` line.
///   - **Error-body decoder**: ``OllamaErrorBodyDecoder`` — Ollama's flat
///     `{"error": "message"}` shape (string at top level, not nested
///     `{error: {message:…}}` like OpenAI/Anthropic).
///   - **Runtime capability probe**: ``OllamaModelProbe.probeShow`` runs at
///     `loadModel` time to detect thinking-model markers, the model's real
///     `context_length`, and the auto-detected thinking markers. The probe
///     itself is not part of the standard adapter surface — it stays on
///     ``OllamaBackend`` where `loadModel` already owns the lifecycle.
///
/// > Important: This adapter composes the routing the
/// > ``OllamaBackend`` installs at init time. The backend body remains the
/// > canonical request builder (`buildRequest` carries the manifest-gated
/// > parameter logic, the tool-aware-history snapshot, the
/// > `effectiveNumCtx` budget, the thinking-budget mapping); the adapter's
/// > `requestBuilder` closure forwards to it. Stream parsing is driven by
/// > the routing's ``streamConsumerFactory`` which yields a fresh
/// > ``OllamaStreamEventExtractor`` per generation.
public struct OllamaAdapter: CloudHTTPProviderAdapter {

    public let messageEncoder: CloudMessageEncoder
    public let payloadHandler: CloudPayloadHandler
    public let framedTransport: any FramedTransport
    public let streamFinalizer: any StreamFinalizer
    public let errorBodyDecoder: any ErrorBodyDecoder
    public let capabilities: BackendCapabilities

    private let requestBuilder: @Sendable (
        _ prompt: String,
        _ systemPrompt: String?,
        _ config: GenerationConfig,
        _ history: [StructuredMessage]
    ) throws -> URLRequest

    public init(
        capabilities: BackendCapabilities,
        messageEncoder: CloudMessageEncoder = .ollama,
        payloadHandler: CloudPayloadHandler = .ollama,
        framedTransport: any FramedTransport = NDJSONTransport(),
        streamFinalizer: any StreamFinalizer = OllamaDoneFlagFinalizer(),
        requestBuilder: @escaping @Sendable (String, String?, GenerationConfig, [StructuredMessage]) throws -> URLRequest
    ) {
        self.capabilities = capabilities
        self.messageEncoder = messageEncoder
        self.payloadHandler = payloadHandler
        self.framedTransport = framedTransport
        self.streamFinalizer = streamFinalizer
        self.errorBodyDecoder = OllamaErrorBodyDecoder()
        self.requestBuilder = requestBuilder
    }

    public func buildRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        history: [StructuredMessage]
    ) throws -> URLRequest {
        try requestBuilder(prompt, systemPrompt, config, history)
    }
}

/// Error-body decoder for Ollama's flat `{"error": "message"}` shape.
///
/// Differs from ``DefaultErrorBodyDecoder`` (which expects the nested
/// `{error: {message: …}}` envelope OpenAI/Anthropic use): Ollama puts the
/// human-readable string directly at `error`. Falls back to the default
/// decoder for compat servers that mirror the OpenAI shape.
public struct OllamaErrorBodyDecoder: ErrorBodyDecoder {
    public init() {}
    public func extractMessage(from body: String) -> String? {
        // Try Ollama's native flat shape first.
        if let data = body.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = parsed["error"] as? String,
           !message.isEmpty {
            return message
        }
        // Fall back to the default decoder for OpenAI-style compat servers
        // (LM Studio, llama.cpp's HTTP server) that proxy through Ollama-
        // compatible URLs but emit the OpenAI envelope.
        return DefaultErrorBodyDecoder().extractMessage(from: body)
    }
}
