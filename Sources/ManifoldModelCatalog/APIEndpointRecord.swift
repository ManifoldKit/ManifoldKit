import Foundation
import ManifoldHardware

/// Plain-data snapshot of a configured cloud API endpoint, decoupled from any
/// specific storage backend.
///
/// `ManifoldCore` provides a SwiftData `@Model APIEndpoint` that maps to this
/// record, but inference orchestration only depends on the record so consumers
/// with their own persistence layer can still call
/// ``InferenceService/loadEndpointBackend(from:)``.
public struct APIEndpointRecord: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var provider: APIProvider
    public var baseURL: String
    public var modelName: String
    public var keychainAccount: String
    public var createdAt: Date
    public var isEnabled: Bool

    /// Explicit wire keys for ``APIEndpointRecord``'s `Codable` conformance.
    ///
    /// Pinned deliberately, not left to the memberwise-derived default: this
    /// is a stable wire/persistence contract pre-1.0 for consumers who
    /// serialize the record directly (headless / CLI callers per the
    /// convenience initializer below, or hosts round-tripping it outside
    /// SwiftData). Adding a case is additive; renaming or removing a case is
    /// a breaking change to whatever already-serialized data exists.
    ///
    /// Note: the `provider` field's encoded *value* is ``APIProvider``'s raw
    /// string, which is currently a display label (e.g. `"OpenAI Responses"`).
    /// Those raw values are scheduled to migrate to stable opaque codes
    /// pre-1.0 (API plan Wave 2, item A1) — and synthesized `Codable` throws
    /// on an unrecognized raw value rather than falling back. Consumers
    /// persisting this record as JSON today should expect that one-time value
    /// migration; the key names themselves will not change.
    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case baseURL
        case modelName
        case keychainAccount
        case createdAt
        case isEnabled
    }

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
