import Foundation
import ManifoldInference

// Source-compatibility shim: lets callers continue to pass the SwiftData
// `@Model APIEndpoint` directly to `InferenceService.loadEndpointBackend(from:)`.
// The underlying inference API now operates on the storage-agnostic
// `APIEndpointRecord`; this extension converts the @Model to a record.
extension APIEndpoint {

    /// Returns a storage-agnostic snapshot of this endpoint suitable for
    /// passing to inference services that don't depend on SwiftData.
    ///
    /// `baseURL` and `modelName` are forwarded directly because the `@Model`
    /// stores them as non-optional `String` — the model's own initializer
    /// resolves any nil inputs to `provider.defaultBaseURL` /
    /// `provider.defaultModelName` at construction time, so persisted values
    /// are always concrete. There is no nil sentinel to preserve here.
    public var record: APIEndpointRecord {
        APIEndpointRecord(
            id: id,
            name: name,
            provider: provider,
            baseURL: baseURL,
            modelName: modelName,
            keychainAccount: keychainAccount,
            createdAt: createdAt,
            isEnabled: isEnabled
        )
    }
}

extension InferenceService {

    /// Loads an endpoint-based backend from a SwiftData `APIEndpoint`.
    ///
    /// Convenience overload that validates the endpoint URL using the canonical
    /// ``APIEndpoint/validate()`` check — blocking private/link-local SSRF targets,
    /// insecure schemes, and malformed URLs — before converting to an
    /// `APIEndpointRecord` and delegating to the storage-agnostic core API.
    @MainActor
    public func loadEndpointBackend(from endpoint: APIEndpoint) async throws {
        try endpoint.validate().get()
        try await loadEndpointBackend(from: endpoint.record)
    }

    /// Loads a cloud API backend from a SwiftData `APIEndpoint`.
    @available(*, deprecated, renamed: "loadEndpointBackend(from:)")
    @MainActor
    public func loadCloudBackend(from endpoint: APIEndpoint) async throws {
        try await loadEndpointBackend(from: endpoint)
    }
}
