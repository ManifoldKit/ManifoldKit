#if Server
import BaseChatInference
import Foundation

internal struct ServerBackendRequest: Equatable, Sendable {
    internal var model: String?

    internal init(model: String? = nil) {
        self.model = model
    }
}

internal protocol ServerBackendProvider: Sendable {
    func listModels() async throws -> [String]
    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend
}

internal struct UnavailableServerBackendProvider: ServerBackendProvider {
    internal init() {}

    internal func listModels() async throws -> [String] { [] }

    internal func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        throw ServerError.backendUnavailable("No server backend has been configured yet.")
    }
}

#endif
