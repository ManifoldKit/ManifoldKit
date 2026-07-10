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
    /// string, which since v0.68 (API plan Wave 2, item A1) is a **stable
    /// opaque code** (`"openAIResponses"`, `"lmStudio"`, …), not the display
    /// label it used to be. ``APIProvider``'s custom `Codable` decodes both the
    /// stable codes *and* the legacy pre-0.68 display strings (via
    /// ``APIProvider/parse(_:)``), so JSON written by older builds still
    /// decodes; encoding always emits the stable code. An unrecognised provider
    /// string throws `DecodingError` rather than silently falling back. The key
    /// names themselves are unchanged.
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
