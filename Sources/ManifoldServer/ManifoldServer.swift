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
/// import ManifoldServer
/// import ManifoldMLX // a companion package
///
/// struct MyMLXBackendProvider: ServerBackendProvider {
///     func listModels() async throws -> [String] { ["mlx-community/my-model"] }
///     func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
///         let backend = MLXBackend()
///         try await backend.loadModel(from: modelURL, plan: .cloud())
///         return backend
///     }
///     func embeddingBackend(for request: ServerBackendRequest) async -> (any EmbeddingBackend)? { nil }
/// }
///
/// try await ManifoldServer.serve(
///     configuration: ServerConfiguration(port: 8080, apiKey: "secret"),
///     backendProvider: MyMLXBackendProvider()
/// )
/// ```
///
/// `backendProvider` always takes precedence — this facade never falls back
/// to (or otherwise consults) the CLI's `TraitAwareServerBackendProvider`.
public enum ManifoldServer {
    /// Runs a ManifoldServer bound to `configuration.host`/`configuration.port`,
    /// dispatching every request through `backendProvider`. Suspends for the
    /// lifetime of the server; cancel the enclosing `Task` to shut it down.
    public static func serve(
        configuration: ServerConfiguration = ServerConfiguration(),
        backendProvider: any ServerBackendProvider
    ) async throws {
        let app = ServerApp(configuration: configuration, backendProvider: backendProvider)
        try await app.run()
    }
}

#endif
