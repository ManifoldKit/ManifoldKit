#if Server
import Foundation
import ManifoldInference

/// Public (v0.71+): the host-configurable knobs for
/// ``ManifoldServer/serve(configuration:backendProvider:)``.
///
/// A `nil`/empty `apiKey` means no bearer token is required. It does **not**
/// silently grant anonymous access: `serve()` refuses a keyless bind unless
/// ``allowAnonymous`` is set (loopback) — and refuses a keyless non-loopback
/// bind outright — exactly mirroring the CLI's `--allow-anonymous` /
/// `--api-key` guard. Before #2314 the facade skipped that guard entirely and
/// bound wide open, so a companion host (MLX/llama) that only reaches the
/// server through `serve()` could expose an unauthenticated inference server
/// with zero warning.
public struct ServerConfiguration: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var apiKey: String?

    /// Opt-in for a keyless bind. Required for a keyless **loopback** bind
    /// (`serve()` refuses one otherwise) and never sufficient for a
    /// non-loopback bind — those always require an `apiKey`. Mirrors the CLI's
    /// `--allow-anonymous` flag so the library facade and the CLI enforce the
    /// same rule (#2314). Combining it with a non-empty `apiKey` is rejected.
    public var allowAnonymous: Bool
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
        allowAnonymous: Bool = false,
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
        self.allowAnonymous = allowAnonymous
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

extension ServerConfiguration {
    /// The outcome of the shared bind-authorization rule (#2314).
    ///
    /// Both entry points evaluate the *same* rule via
    /// ``resolveBindAuthorization()`` and then translate this result into their
    /// own error type and surface-appropriate wording — the CLI
    /// (`ServerCommandOptions.validate()`) throws `ValidationError` with flag
    /// names (`--api-key` / `--allow-anonymous`); the library facade
    /// (`ManifoldServer.serve(...)`) throws `ServerError.invalidConfiguration`
    /// with field names. Sharing the branch logic in one place — rather than a
    /// second copy on `serve()` — is what keeps the two paths from drifting
    /// (the acceptance criterion of #2314). A new refusal case is a
    /// compile-time obligation on both surfaces because both `switch` over it
    /// exhaustively.
    internal enum BindAuthorization: Equatable {
        /// A non-empty API key is present — the bind is authenticated.
        case authenticated
        /// A keyless loopback bind with an explicit anonymous opt-in.
        /// Permitted, but the caller must warn.
        case anonymousLoopback
        /// The bind is refused; the reason lets each caller pick its wording.
        case refused(BindRefusalReason)
    }

    /// Why a bind was refused. Mirrors, one-for-one, the guard branches the CLI
    /// enforced before #2314.
    internal enum BindRefusalReason: Equatable {
        case apiKeyCombinedWithAnonymous
        case anonymousOnNonLoopback
        case keylessNonLoopback(host: String)
        case keylessLoopbackWithoutOptIn(host: String)
    }

    /// The single source of truth for whether this configuration may bind, and
    /// on what terms. Pure — it neither throws nor prints; callers translate
    /// the ``BindAuthorization`` into their own error/warning surface.
    internal func resolveBindAuthorization() -> BindAuthorization {
        let hasAPIKey = !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let loopback = ServerCommandOptions.isLoopbackBindHost(host)

        if allowAnonymous && hasAPIKey {
            return .refused(.apiKeyCombinedWithAnonymous)
        }
        if allowAnonymous && !loopback {
            return .refused(.anonymousOnNonLoopback)
        }
        if !hasAPIKey {
            if !loopback {
                return .refused(.keylessNonLoopback(host: host))
            }
            if !allowAnonymous {
                return .refused(.keylessLoopbackWithoutOptIn(host: host))
            }
            return .anonymousLoopback
        }
        return .authenticated
    }
}

#endif
