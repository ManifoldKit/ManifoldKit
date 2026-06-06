import Foundation
import ManifoldHardware

/// Plain-data snapshot of a configured cloud API endpoint, decoupled from any
/// specific storage backend.
///
/// `ManifoldCore` provides a SwiftData `@Model APIEndpoint` that maps to this
/// record, but inference orchestration only depends on the record so consumers
/// with their own persistence layer can still call
/// ``InferenceService/loadCloudBackend(from:)``.
public struct APIEndpointRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var provider: APIProvider
    public var baseURL: String
    public var modelName: String
    public var keychainAccount: String
    public var createdAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        provider: APIProvider,
        baseURL: String? = nil,
        modelName: String? = nil,
        keychainAccount: String? = nil,
        createdAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.modelName = modelName ?? provider.defaultModelName
        self.keychainAccount = keychainAccount ?? id.uuidString
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }

    /// Convenience initializer for headless / CLI consumers that only need to
    /// call ``InferenceService/loadEndpointBackend(from:)`` and don't have a
    /// persistence layer to supply the full set of metadata fields.
    ///
    /// Sets `name` to `modelName`, derives `keychainAccount` from a freshly
    /// generated `id`, and uses sensible defaults for `createdAt` and
    /// `isEnabled`.
    public init(provider: APIProvider, baseURL: String, modelName: String) {
        let id = UUID()
        self.id = id
        self.provider = provider
        self.baseURL = baseURL
        self.modelName = modelName
        self.name = modelName
        self.keychainAccount = id.uuidString
        self.createdAt = Date()
        self.isEnabled = true
    }
}
