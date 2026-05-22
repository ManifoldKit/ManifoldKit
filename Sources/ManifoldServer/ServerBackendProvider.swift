#if Server
import ManifoldInference
import Foundation

internal struct ServerBackendRequest: Equatable, Sendable {
    internal var model: String?

    internal init(model: String? = nil) {
        self.model = model
    }
}

internal protocol ServerBackendProvider: Sendable {
    func listModels() async throws -> [String]
    func listModelRecords() async throws -> [ModelsListResponse.Model]
    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend
    /// Returns an `EmbeddingBackend` for the given request, or `nil` when this
    /// provider does not support embeddings (e.g. a cloud-only configuration).
    func embeddingBackend(for request: ServerBackendRequest) async -> (any EmbeddingBackend)?
}

extension ServerBackendProvider {
    internal func listModelRecords() async throws -> [ModelsListResponse.Model] {
        try await listModels().map { ModelsListResponse.Model(id: $0, status: "available") }
    }

    /// Default: no embedding support. Providers that vend an embedding backend
    /// override this method.
    internal func embeddingBackend(for request: ServerBackendRequest) async -> (any EmbeddingBackend)? {
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
