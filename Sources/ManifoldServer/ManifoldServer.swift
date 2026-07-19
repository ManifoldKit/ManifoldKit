#if Server
import Foundation

/// The public entry point for embedding an OpenAI-compatible ManifoldKit
/// inference server in a host app or executable, with a real backend supplied
/// by the caller.
///
/// `manifold-server` (``ManifoldServerCommand``) is the CLI entry point and
/// stays on its own path — it always builds a `TraitAwareServerBackendProvider`
/// from `--backend`, which can only reach Foundation/Ollama in a core-only
/// build (`--backend mlx`/`--backend llama` fail with a pointer back here).
/// A host app that links a companion package (manifold-mlx / manifold-llama)
/// has no access to that CLI type — `ServerApp` and `ServerBackendProvider`'s
/// concrete conformers are internal — so this facade is the only supported
/// way to run a ManifoldServer with a real local backend from outside this
/// package:
///
/// ```swift
/// import Foundation
/// import ManifoldServer
/// import ManifoldInference   // InferenceBackend / EmbeddingBackend live here
/// import ManifoldMLX         // a companion package (provides MLXBackend)
///
/// // `backend(for:)` is called once PER REQUEST, so constructing +
/// // loadModel()-ing a multi-GB model inline would reload it on every call
/// // (measured ~20x slower on a 3GB model — 5.0s cold vs 0.23s warm — plus
/// // Metal-buffer churn). Cache the loaded backend; an `actor` makes the lazy
/// // load concurrency-safe.
/// actor MyMLXBackendProvider: ServerBackendProvider {
///     private let modelURL: URL
///     private var cached: (any InferenceBackend)?
///
///     init(modelURL: URL) { self.modelURL = modelURL }
///
///     func listModels() async throws -> [String] { ["mlx-community/my-model"] }
///
///     func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
///         if let cached { return cached }
///         let backend = MLXBackend()
///         try await backend.loadModel(from: modelURL, plan: .cloud())
///         cached = backend
///         return backend
///     }
///
///     func embeddingBackend(for request: ServerBackendRequest) async -> (any EmbeddingBackend)? { nil }
/// }
///
/// try await ManifoldServer.serve(
///     configuration: ServerConfiguration(port: 8080, apiKey: "secret"),
///     backendProvider: MyMLXBackendProvider(modelURL: URL(fileURLWithPath: "/path/to/model"))
/// )
/// ```
///
/// > The `MLXBackends` / `LlamaBackends` *registrars* (used with
/// > `quickStart(backends:)`) register a factory into an `InferenceService` —
/// > but the server never consults an `InferenceService`; it calls
/// > `backendProvider.backend(for:)` directly. The two extension points are
/// > **disjoint**, so a host serves a companion model by constructing the
/// > backend (`MLXBackend()`) inside its own `ServerBackendProvider`, as
/// > above — not by passing the registrar.
///
/// `backendProvider` always takes precedence — this facade never falls back
/// to (or otherwise consults) the CLI's `TraitAwareServerBackendProvider`.
public enum ManifoldServer {
    /// Runs a ManifoldServer bound to `configuration.host`/`configuration.port`,
    /// dispatching every request through `backendProvider`. Suspends for the
    /// lifetime of the server; cancel the enclosing `Task` to shut it down.
    ///
    /// Enforces the same bind-authorization guard as the CLI before binding
    /// (#2314): throws `ServerError.invalidConfiguration` for a keyless
    /// non-loopback bind, or a keyless loopback bind without
    /// `configuration.allowAnonymous`. A permitted keyless loopback bind emits
    /// a one-line warning to stderr, matching the CLI.
    public static func serve(
        configuration: ServerConfiguration = ServerConfiguration(),
        backendProvider: any ServerBackendProvider
    ) async throws {
        switch configuration.resolveBindAuthorization() {
        case .authenticated:
            break
        case .anonymousLoopback:
            FileHandle.standardError.write(Data(
                "warning: ManifoldServer.serve started without an API key on \(configuration.host); any process that can reach it can invoke inference without credentials\n".utf8
            ))
        case .refused(let reason):
            throw ServerError.invalidConfiguration(bindRefusalMessage(reason))
        }

        let app = ServerApp(configuration: configuration, backendProvider: backendProvider)
        try await app.run()
    }

    /// Library-surface wording for a refused bind. The CLI renders the same
    /// ``ServerConfiguration/BindRefusalReason`` cases with flag names instead
    /// (`ServerCommandOptions.validate()`); both derive from the one shared
    /// rule in ``ServerConfiguration/resolveBindAuthorization()``.
    private static func bindRefusalMessage(_ reason: ServerConfiguration.BindRefusalReason) -> String {
        switch reason {
        case .apiKeyCombinedWithAnonymous:
            return "ServerConfiguration.allowAnonymous cannot be combined with a non-empty apiKey."
        case .anonymousOnNonLoopback:
            return "ServerConfiguration.allowAnonymous is only valid for loopback binds (127.0.0.1, localhost, ::1); non-loopback hosts require an apiKey."
        case .keylessNonLoopback(let host):
            return "refusing to bind \(host) without an apiKey (non-loopback binds require authentication)."
        case .keylessLoopbackWithoutOptIn(let host):
            return "refusing an unauthenticated bind on \(host) without allowAnonymous (any local process can invoke inference). Set apiKey, or allowAnonymous: true to permit keyless loopback access."
        }
    }
}

#endif
