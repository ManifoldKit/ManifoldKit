import Foundation
import ManifoldInference
import ManifoldRuntime
import SwiftData

/// Default ``EndpointStore`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, converting between
/// ``ManifoldSchemaV4/APIEndpoint`` `@Model` rows and
/// ``APIEndpointRecord`` value types at the boundary.
@MainActor
public final class SwiftDataEndpointStore: EndpointStore {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func fetchEndpoints() async throws -> [APIEndpointRecord] {
        let descriptor = FetchDescriptor<APIEndpoint>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.record }
    }

    public func insertEndpoint(_ record: APIEndpointRecord) async throws {
        let endpoint = APIEndpoint(
            name: record.name,
            provider: record.provider,
            baseURL: record.baseURL,
            modelName: record.modelName
        )
        endpoint.id = record.id
        endpoint.createdAt = record.createdAt
        endpoint.isEnabled = record.isEnabled
        modelContext.insert(endpoint)
        try modelContext.save()
    }

    public func updateEndpoint(_ record: APIEndpointRecord) async throws {
        guard let endpoint = try fetchSwiftDataEndpoint(id: record.id) else {
            throw EndpointStoreError.endpointNotFound(record.id)
        }
        endpoint.name = record.name
        endpoint.provider = record.provider
        endpoint.baseURL = record.baseURL
        endpoint.modelName = record.modelName
        endpoint.isEnabled = record.isEnabled
        try modelContext.save()
    }

    public func deleteEndpoint(_ id: UUID) async throws {
        guard let endpoint = try fetchSwiftDataEndpoint(id: id) else {
            throw EndpointStoreError.endpointNotFound(id)
        }
        modelContext.delete(endpoint)
        try modelContext.save()
    }

    // MARK: - Private

    private func fetchSwiftDataEndpoint(id: UUID) throws -> APIEndpoint? {
        let descriptor = FetchDescriptor<APIEndpoint>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }
}
