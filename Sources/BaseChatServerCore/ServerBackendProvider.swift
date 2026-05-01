import BaseChatInference
import Foundation

package struct ServerBackendRequest: Equatable, Sendable {
    package var model: String?

    package init(model: String? = nil) {
        self.model = model
    }
}

package protocol ServerBackendProvider: Sendable {
    func listModels() async throws -> [String]
    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend
}

package struct UnavailableServerBackendProvider: ServerBackendProvider {
    package init() {}

    package func listModels() async throws -> [String] { [] }

    package func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        throw ServerError.backendUnavailable("No server backend has been configured yet.")
    }
}
