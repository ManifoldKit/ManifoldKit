#if Server
import ManifoldInference
import Foundation

/// Identifies which model a chat/embedding request wants, so a
/// ``ServerBackendProvider`` can route between multiple loaded backends.
///
/// Public (v0.71+): the request shape a host-injected ``ServerBackendProvider``
/// receives — see that protocol's doc comment for the end-to-end recipe.
public struct ServerBackendRequest: Equatable, Sendable {
    public var model: String?

    public init(model: String? = nil) {
        self.model = model
    }
}

/// The extension point ``ManifoldServer/serve(configuration:backendProvider:)``
/// dispatches every request through to obtain an ``InferenceBackend``. A host
/// app links a companion package (e.g. manifold-mlx / manifold-llama) and
/// implements this protocol to serve real local models — the CLI's built-in
/// `TraitAwareServerBackendProvider` only ever reaches Foundation/Ollama in a
/// core-only build; `--backend mlx`/`--backend llama` fail there with a
/// pointer back to this seam.
public protocol ServerBackendProvider: Sendable {
    func listModels() async throws -> [String]
    func listModelRecords() async throws -> [ModelsListResponse.Model]
    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend
    /// Returns an `EmbeddingBackend` for the given request, or `nil` when this
    /// provider does not support embeddings (e.g. a cloud-only configuration).
    func embeddingBackend(for request: ServerBackendRequest) async -> (any EmbeddingBackend)?
}

extension ServerBackendProvider {
    public func listModelRecords() async throws -> [ModelsListResponse.Model] {
        try await listModels().map { ModelsListResponse.Model(id: $0, status: "available") }
    }

    /// Default: no embedding support. Providers that vend an embedding backend
    /// override this method.
    public func embeddingBackend(for request: ServerBackendRequest) async -> (any EmbeddingBackend)? {
        nil
    }
}

internal struct UnavailableServerBackendProvider: ServerBackendProvider {
    internal init() {}

    internal func listModels() async throws -> [String] { [] }

    internal func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        throw ServerError.backendUnavailable("No server backend has been configured yet.")
    }
}

#endif
