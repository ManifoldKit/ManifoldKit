import XCTest
import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - InMemoryEndpointStore (test double for contract adoption)

@MainActor
private final class InMemoryEndpointStore: EndpointStore {
    private var endpoints: [APIEndpointRecord] = []

    func fetchEndpoints() async throws -> [APIEndpointRecord] {
        endpoints.sorted { $0.createdAt > $1.createdAt }
    }

    func insertEndpoint(_ record: APIEndpointRecord) async throws {
        endpoints.append(record)
    }

    func updateEndpoint(_ record: APIEndpointRecord) async throws {
        guard let idx = endpoints.firstIndex(where: { $0.id == record.id }) else {
            throw EndpointStoreError.endpointNotFound(record.id)
        }
        endpoints[idx] = record
    }

    func deleteEndpoint(_ id: UUID) async throws {
        guard let idx = endpoints.firstIndex(where: { $0.id == id }) else {
            throw EndpointStoreError.endpointNotFound(id)
        }
        endpoints.remove(at: idx)
    }
}

// MARK: - InMemoryEndpointStoreContractTests

@MainActor
final class InMemoryEndpointStoreContractTests: XCTestCase, EndpointStoreContract {

    func makeEndpointStore() -> any EndpointStore {
        InMemoryEndpointStore()
    }

    func test_emptyStore_returnsNoEndpoints() async throws {
        try await assertEndpointStore_emptyStoreReturnsNoEndpoints()
    }

    func test_insert_thenFetch_returnsRecord() async throws {
        try await assertEndpointStore_insertThenFetchReturnsRecord()
    }

    func test_fetch_ordersByMostRecentlyCreatedFirst() async throws {
        try await assertEndpointStore_fetchOrdersByMostRecentlyCreatedFirst()
    }

    func test_update_persistsChanges() async throws {
        try await assertEndpointStore_updatePersistsChanges()
    }

    func test_update_unknownID_throwsNotFound() async throws {
        try await assertEndpointStore_updateUnknownIDThrowsNotFound()
    }

    func test_delete_deletedEndpointNotReturned() async throws {
        try await assertEndpointStore_deletedEndpointNotReturned()
    }

    func test_delete_unknownID_throwsNotFound() async throws {
        try await assertEndpointStore_deleteUnknownIDThrowsNotFound()
    }
}
