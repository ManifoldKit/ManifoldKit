import XCTest
import ManifoldRuntime
import ManifoldInference

// MARK: - EndpointStoreContract

/// Opt-in XCTestCase mixin that exercises the ``EndpointStore`` protocol
/// contract against any conforming implementation.
///
/// ```swift
/// @MainActor
/// final class InMemoryEndpointStoreContractTests: XCTestCase, EndpointStoreContract {
///     func makeEndpointStore() -> any EndpointStore {
///         InMemoryEndpointStoreImpl()
///     }
///
///     func test_insertFetch() async throws {
///         try await assertEndpointStore_insertThenFetchReturnsRecord()
///     }
/// }
/// ```
@MainActor
public protocol EndpointStoreContract: AnyObject {
    /// Returns a fresh, empty endpoint store for each assertion call.
    func makeEndpointStore() -> any EndpointStore
}

extension EndpointStoreContract where Self: XCTestCase {

    // MARK: - Fixture helpers

    private func makeEndpoint(
        name: String = "Test Endpoint",
        provider: APIProvider = .openAI,
        createdAt: Date = Date()
    ) -> APIEndpointRecord {
        APIEndpointRecord(name: name, provider: provider, createdAt: createdAt)
    }

    // MARK: - Empty-store baseline

    /// Asserts that a fresh store returns an empty array from ``fetchEndpoints()``.
    public func assertEndpointStore_emptyStoreReturnsNoEndpoints(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeEndpointStore()
        let result = try await store.fetchEndpoints()
        XCTAssertTrue(result.isEmpty, "Fresh store must return no endpoints", file: file, line: line)
    }

    // MARK: - Insert / Fetch

    /// Asserts that an inserted endpoint is returned by ``fetchEndpoints()``.
    public func assertEndpointStore_insertThenFetchReturnsRecord(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeEndpointStore()
        let endpoint = makeEndpoint(name: "Contract probe")
        try await store.insertEndpoint(endpoint)

        let fetched = try await store.fetchEndpoints()
        XCTAssertEqual(fetched.count, 1, file: file, line: line)
        XCTAssertEqual(fetched.first?.id, endpoint.id, file: file, line: line)
    }

    // MARK: - Most-recently-created ordering

    /// Asserts that ``fetchEndpoints()`` orders endpoints most-recently-created
    /// first, as documented on the protocol.
    public func assertEndpointStore_fetchOrdersByMostRecentlyCreatedFirst(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeEndpointStore()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let older = makeEndpoint(name: "Older", createdAt: base)
        let newer = makeEndpoint(name: "Newer", createdAt: base.addingTimeInterval(10))
        try await store.insertEndpoint(older)
        try await store.insertEndpoint(newer)

        let fetched = try await store.fetchEndpoints()
        XCTAssertEqual(
            fetched.map(\.id), [newer.id, older.id],
            "fetchEndpoints() must return most-recently-created first",
            file: file, line: line
        )
    }

    // MARK: - Update

    /// Asserts that ``updateEndpoint(_:)`` persists the changed name.
    public func assertEndpointStore_updatePersistsChanges(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeEndpointStore()
        var endpoint = makeEndpoint(name: "Original")
        try await store.insertEndpoint(endpoint)

        endpoint.name = "Updated"
        try await store.updateEndpoint(endpoint)

        let fetched = try await store.fetchEndpoints()
        XCTAssertEqual(fetched.first?.name, "Updated", file: file, line: line)
    }

    /// Asserts that ``updateEndpoint(_:)`` throws
    /// ``EndpointStoreError/endpointNotFound(_:)`` for an unknown ID.
    public func assertEndpointStore_updateUnknownIDThrowsNotFound(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeEndpointStore()
        let ghost = makeEndpoint(name: "Ghost")
        do {
            try await store.updateEndpoint(ghost)
            XCTFail("update of unknown endpoint must throw", file: file, line: line)
        } catch EndpointStoreError.endpointNotFound(let id) {
            XCTAssertEqual(id, ghost.id, file: file, line: line)
        } catch {
            XCTFail("Expected EndpointStoreError.endpointNotFound, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Delete

    /// Asserts that a deleted endpoint is no longer returned by
    /// ``fetchEndpoints()``.
    public func assertEndpointStore_deletedEndpointNotReturned(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeEndpointStore()
        let endpoint = makeEndpoint(name: "To delete")
        try await store.insertEndpoint(endpoint)
        try await store.deleteEndpoint(endpoint.id)

        let fetched = try await store.fetchEndpoints()
        XCTAssertFalse(
            fetched.contains { $0.id == endpoint.id },
            "Deleted endpoint must not appear in subsequent fetch",
            file: file, line: line
        )
    }

    /// Asserts that ``deleteEndpoint(_:)`` throws
    /// ``EndpointStoreError/endpointNotFound(_:)`` for an unknown ID.
    public func assertEndpointStore_deleteUnknownIDThrowsNotFound(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeEndpointStore()
        let unknownID = UUID()
        do {
            try await store.deleteEndpoint(unknownID)
            XCTFail("delete of unknown id must throw", file: file, line: line)
        } catch EndpointStoreError.endpointNotFound(let id) {
            XCTAssertEqual(id, unknownID, file: file, line: line)
        } catch {
            XCTFail("Expected EndpointStoreError.endpointNotFound, got \(error)", file: file, line: line)
        }
    }
}
