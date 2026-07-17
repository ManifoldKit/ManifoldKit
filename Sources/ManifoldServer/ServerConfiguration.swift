#if Server
import Foundation
import ManifoldInference

/// Public (v0.71+): the host-configurable knobs for
/// ``ManifoldServer/serve(configuration:backendProvider:)``. A `nil`/empty
/// `apiKey` means anonymous access, mirroring the CLI's `--allow-anonymous`
/// behavior — there is no separate `allowAnonymous` flag because `ServerApp`
/// derives it from `apiKey` alone (see its `authMiddleware` init logic).
public struct ServerConfiguration: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var apiKey: String?
    public var parallelSlots: Int
    public var unsafeCORS: Bool
    public var corsOrigin: String?
    public var metricsEnabled: Bool
    /// Maximum HTTP request body size accepted by the server in bytes.
    /// Requests whose body exceeds this limit are rejected with 413 before any
    /// handler logic runs. Defaults to the value in ``ManifoldConfiguration``.
    public var maxServerRequestBodyBytes: Int

    /// Wall-clock cap on a single non-streaming `/v1/chat/completions`
    /// generation. `nil` disables the cap, restoring the pre-#2265 behavior
    /// where a stalled backend held the request (and the `generationGate`
    /// slot it occupies) open indefinitely.
    ///
    /// Non-streaming has no intermediate progress signal at this layer — the
    /// whole `ChatCompletionsAdapter.response(for:using:)` call is one opaque
    /// await — so a wall-clock cap is the only shape that fits. Contrast with
    /// ``streamingIdleTimeout``, which resets per chunk because the streaming
    /// path *does* have a progress signal and a wall-clock cap there would
    /// wrongly kill a slow-but-healthy long completion (see that property's
    /// doc comment, and PR #2268's identical reasoning for the fuzz harness's
    /// OpenAI exemption).
    ///
    /// **Default-value assumption:** at the default 600s and the default
    /// ``maxGenerationOutputTokens`` ceiling of 4096, a generation must
    /// sustain roughly `4096 / 600 ≈ 6.83` tokens/sec to complete within
    /// budget when it actually uses the full output ceiling. Raise this (or
    /// lower the ceiling) if you run a model slower than that — a large or
    /// CPU-bound local model can fall under 7 tok/s.
    ///
    /// On expiry the backend's in-flight generation is cancelled via
    /// `InferenceBackend.stopGeneration()` — but **only when
    /// `parallelSlots == 1`**. `stopGeneration()`'s contract is backend-wide,
    /// not per-request, and `TraitAwareServerBackendProvider` hands out a
    /// single cached backend instance per model — so under `parallelSlots >
    /// 1`, calling it here would cancel a *different*, healthy sibling
    /// request sharing that same backend instance, not just the timed-out
    /// one. With `parallelSlots > 1` the operation is only abandoned
    /// (cancelled at the `Task` level, not at the backend), which is weaker
    /// but not actively harmful. Either way the request fails with
    /// `ServerError.generationTimedOut`, mapped to HTTP 504.
    public var generationTimeout: Duration?

    /// Idle-reset timeout for the streaming `/v1/chat/completions` path: the
    /// clock re-arms every time the backend/adapter produces a new chunk —
    /// NOT when that chunk is written to the client — so a generation that
    /// keeps producing tokens, however slowly, is never killed. Only a
    /// backend that stops emitting chunks entirely for this long trips it.
    /// A stalled *client* (one that stops reading a healthy stream) is not
    /// covered by this timeout. `nil` disables the cap.
    ///
    /// On expiry the backend's in-flight generation is cancelled via
    /// `InferenceBackend.stopGeneration()` — subject to the same
    /// `parallelSlots == 1` restriction documented on ``generationTimeout``
    /// — the client receives one terminal SSE `data:` frame carrying a
    /// `server_error`/`generation_timeout` envelope, and the underlying
    /// request then fails with `ServerError.generationTimedOut` so
    /// metrics/gate bookkeeping runs through the normal error path.
    public var streamingIdleTimeout: Duration?

    /// Ceiling applied to the effective `max_tokens`/`max_completion_tokens`
    /// for every chat-completion request, and the value substituted when a
    /// request specifies neither field.
    ///
    /// Without this, a request that omits both fields reaches
    /// `DefaultChatCompletionsAdapter.generationConfig(for:)` with
    /// `maxOutputTokens: nil` — `GenerationConfig`'s own doc comment defines
    /// `nil` as "no cap, fall back to the backend's own default" — so the
    /// common case of a client that never set an output-length field
    /// generates/streams genuinely unbounded output. `nil` here disables the
    /// server-side ceiling entirely and restores that pre-#2265 behavior.
    public var maxGenerationOutputTokens: Int?

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        apiKey: String? = nil,
        parallelSlots: Int = 1,
        unsafeCORS: Bool = false,
        corsOrigin: String? = nil,
        metricsEnabled: Bool = false,
        maxServerRequestBodyBytes: Int = ManifoldConfiguration.shared.maxServerRequestBodyBytes,
        generationTimeout: Duration? = .seconds(600),
        streamingIdleTimeout: Duration? = .seconds(60),
        maxGenerationOutputTokens: Int? = 4096
    ) {
        self.host = host
        self.port = port
        self.apiKey = apiKey
        self.parallelSlots = parallelSlots
        self.unsafeCORS = unsafeCORS
        self.corsOrigin = corsOrigin
        self.metricsEnabled = metricsEnabled
        self.maxServerRequestBodyBytes = maxServerRequestBodyBytes
        self.generationTimeout = generationTimeout
        self.streamingIdleTimeout = streamingIdleTimeout
        self.maxGenerationOutputTokens = maxGenerationOutputTokens
    }
}

#endif
