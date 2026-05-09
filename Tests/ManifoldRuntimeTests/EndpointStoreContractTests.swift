import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Locks the ``EndpointStore`` protocol contract via an in-memory reference
/// implementation. The SwiftData-backed implementation is exercised in
/// ``SwiftDataEndpointStoreTests`` (in `ManifoldCoreTests`); this file
/// defends the protocol's documented behaviour independently of any backing
/// store, so a future second implementation has a target to verify against.
@MainActor
final class EndpointStoreContractTests: XCTestCase {

    // MARK: - In-memory reference implementation

    /// Minimal port-conforming implementation used purely as a test double.
    /// Mirrors the contract documented on ``EndpointStore``: most-recently-
    /// created first ordering, throws ``EndpointStoreError/endpointNotFound(_:)``
    /// for missing-id update / delete.
    private final class InMemoryEndpointStore: EndpointStore {
        private var endpoints: [APIEndpointRecord] = []

        func fetchEndpoints() async throws -> [APIEndpointRecord] {
            endpoints.sorted(by: { $0.createdAt > $1.createdAt })
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

    // MARK: - Tests

    func test_fetchEndpoints_emptyStore_returnsEmptyArray() async throws {
        let store = InMemoryEndpointStore()
        let result = try await store.fetchEndpoints()
        XCTAssertTrue(result.isEmpty)
    }

    func test_insertThenFetch_returnsInsertedRecord() async throws {
        let store = InMemoryEndpointStore()
        let record = APIEndpointRecord(name: "Probe", provider: .openAI)
        try await store.insertEndpoint(record)

        let fetched = try await store.fetchEndpoints()
        XCTAssertEqual(fetched.map(\.id), [record.id])
    }

    func test_fetch_ordersMostRecentlyCreatedFirst() async throws {
        let store = InMemoryEndpointStore()
        let older = APIEndpointRecord(
            name: "Older", provider: .openAI,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let newer = APIEndpointRecord(
            name: "Newer", provider: .claude,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        try await store.insertEndpoint(older)
        try await store.insertEndpoint(newer)

        let fetched = try await store.fetchEndpoints()
        XCTAssertEqual(fetched.map(\.id), [newer.id, older.id])
    }

    func test_update_unknownID_throwsEndpointNotFound() async throws {
        let store = InMemoryEndpointStore()
        let ghost = APIEndpointRecord(name: "Ghost", provider: .ollama)
        do {
            try await store.updateEndpoint(ghost)
            XCTFail("update of unknown id must throw")
        } catch let EndpointStoreError.endpointNotFound(id) {
            XCTAssertEqual(id, ghost.id)
        } catch {
            XCTFail("expected EndpointStoreError.endpointNotFound, got \(error)")
        }
    }

    func test_delete_unknownID_throwsEndpointNotFound() async throws {
        let store = InMemoryEndpointStore()
        let id = UUID()
        do {
            try await store.deleteEndpoint(id)
            XCTFail("delete of unknown id must throw")
        } catch let EndpointStoreError.endpointNotFound(missingID) {
            XCTAssertEqual(missingID, id)
        } catch {
            XCTFail("expected EndpointStoreError.endpointNotFound, got \(error)")
        }
    }

    // MARK: - EndpointStoreError

    func test_endpointStoreError_errorDescription_includesUUID() {
        let id = UUID()
        let error = EndpointStoreError.endpointNotFound(id)
        let message = try? XCTUnwrap(error.errorDescription)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains(id.uuidString))
    }

    func test_endpointStoreError_equatable_byUUID() {
        let id = UUID()
        XCTAssertEqual(
            EndpointStoreError.endpointNotFound(id),
            EndpointStoreError.endpointNotFound(id)
        )
        XCTAssertNotEqual(
            EndpointStoreError.endpointNotFound(id),
            EndpointStoreError.endpointNotFound(UUID())
        )
    }
}
