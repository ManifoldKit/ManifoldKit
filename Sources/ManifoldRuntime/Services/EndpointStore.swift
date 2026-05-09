import Foundation
import ManifoldInference

/// Errors produced by ``EndpointStore`` implementations.
public enum EndpointStoreError: Error, LocalizedError, Sendable, Equatable {
    case endpointNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .endpointNotFound(id):
            return "API endpoint not found: \(id.uuidString)"
        }
    }
}

/// Storage-neutral port for cloud API endpoint CRUD.
///
/// Replaces the direct `@Query(\APIEndpoint.createdAt)` access in
/// `APIConfigurationView` and the `modelContext.insert/save/delete` calls
/// scattered across the endpoint editor flows
/// (`APIEndpointEditorView`, `RemoteServerConfigSheet`). The default
/// implementation is ``SwiftDataEndpointStore``.
///
/// All methods are `async throws` at the surface and traffic in
/// ``APIEndpointRecord`` value types — the SwiftData `@Model` never escapes
/// the impl.
///
/// Keychain lifecycle is **not** the store's responsibility: API keys live in
/// the system Keychain, keyed by the endpoint's id. The store deletes the
/// endpoint row; callers delete the matching Keychain item via
/// `KeychainService.delete(account:)`.
@MainActor
public protocol EndpointStore: AnyObject, Sendable {

    /// Fetches every persisted endpoint, ordered most-recently-created first.
    func fetchEndpoints() async throws -> [APIEndpointRecord]

    /// Inserts a new endpoint.
    func insertEndpoint(_ record: APIEndpointRecord) async throws

    /// Updates an existing endpoint, identified by ``APIEndpointRecord/id``.
    ///
    /// - Throws: ``EndpointStoreError/endpointNotFound(_:)`` when the endpoint
    ///   does not exist.
    func updateEndpoint(_ record: APIEndpointRecord) async throws

    /// Deletes an endpoint by id.
    ///
    /// - Throws: ``EndpointStoreError/endpointNotFound(_:)`` when the endpoint
    ///   does not exist.
    func deleteEndpoint(_ id: UUID) async throws
}
