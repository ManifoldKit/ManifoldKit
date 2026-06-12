import Foundation
import ManifoldBackends
import ManifoldFuzz
import ManifoldInference

/// `FuzzBackendFactory` conformance that instantiates a fresh `OpenAIBackend`
/// configured against any OpenAI-Chat-Completions-compatible cloud endpoint —
/// primarily OpenRouter (`https://openrouter.ai/api`), but equally OpenAI,
/// Together, Groq, or a self-hosted gateway.
///
/// Mirrors ``OllamaFuzzFactory``: it constructs the backend, configures it,
/// runs the no-op cloud `loadModel`, and snapshots the model's thinking
/// markers so the runner records the correct marker family. Unlike Ollama
/// there is no model-discovery round-trip — cloud endpoints don't enumerate a
/// stable per-host model list, so the model slug is supplied explicitly via
/// `--model`.
///
/// `baseURL` must NOT include the `/v1` suffix: `OpenAIBackend.buildRequest`
/// appends `v1/chat/completions` itself. The OpenRouter base is therefore
/// `https://openrouter.ai/api`, not `https://openrouter.ai/api/v1`.
public struct OpenAIFuzzFactory: FuzzBackendFactory {
    public let baseURL: URL
    public let apiKey: String
    public let modelName: String

    /// Per-request HTTP idle timeout (seconds) applied to every generation
    /// request via ``SSECloudBackend/requestIdleTimeout``. Bounds how long a
    /// hung iteration waits before abandoning, overriding the 300s session
    /// default from `URLSessionProvider` for the fuzz path only. Slow/throttled
    /// free OpenRouter models otherwise hang the full 300s per request even
    /// though the detectors already flag anything over 60s, so a tighter bound
    /// loses no signal while protecting throughput.
    public let requestTimeout: TimeInterval

    /// Cloud generation is non-deterministic — providers do not honour a seed
    /// reproducibly across requests, and `:free` slugs route to shifting
    /// backends. `Replayer` short-circuits with `.nonDeterministicBackend`
    /// when this is `false` rather than run a guaranteed-noisy replay.
    public var supportsDeterministicReplay: Bool { false }

    public init(baseURL: URL, apiKey: String, modelName: String, requestTimeout: TimeInterval) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.requestTimeout = requestTimeout
    }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        let backend = OpenAIBackend()
        backend.configure(baseURL: baseURL, apiKey: apiKey, modelName: modelName)
        // Bound the per-request HTTP idle window for the fuzz path. The shared
        // session default (`URLSessionProvider`, 300s) is production-tuned for
        // long generations; here a hung iteration should abandon promptly since
        // the detectors already flag >60s. This is the per-iteration time bound —
        // there is no separate runner deadline; the transport timeout is it.
        backend.requestIdleTimeout = requestTimeout
        // Cloud `loadModel` is a no-op that only validates the base URL and
        // flips `isModelLoaded` — no network round-trip happens here, so the
        // factory stays cheap and the first request fires only on `generate`.
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        // Reuse whatever marker family the manifest table mapped the slug to
        // (many OpenRouter-hosted reasoning models — Qwen3, DeepSeek-R1 — use
        // `<think>`/`</think>`). Fall back to the Qwen3-style tags when the
        // manifest carries no markers, matching `OllamaFuzzFactory`.
        let autoMarkers = backend.manifest?.thinkingMarkers
        let markers = autoMarkers.map { RunRecord.MarkerSnapshot(open: $0.open, close: $0.close) }
            ?? RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: modelName,
            modelURL: URL(string: "openai:" + modelName)!,
            backendName: "openai",
            templateMarkers: markers
        )
    }
}
