import XCTest
import SwiftData
@testable import BaseChatCore
import BaseChatInference
import BaseChatTestSupport

@MainActor
final class SwiftDataEndpointStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: SwiftDataEndpointStore!

    override func setUp() async throws {
        container = try makeInMemoryContainer()
        context = ModelContext(container)
        store = SwiftDataEndpointStore(modelContext: context)
    }

    override func tearDown() async throws {
        store = nil
        context = nil
        container = nil
    }

    // MARK: - Insert + fetch

    func test_fetchEndpoints_emptyStore_returnsEmpty() async throws {
        let endpoints = try await store.fetchEndpoints()
        XCTAssertTrue(endpoints.isEmpty)
    }

    func test_insertEndpoint_persistsAllFields() async throws {
        let record = APIEndpointRecord(
            name: "My OpenAI",
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            modelName: "gpt-4o-mini"
        )

        try await store.insertEndpoint(record)

        let endpoints = try await store.fetchEndpoints()
        XCTAssertEqual(endpoints.count, 1)
        let fetched = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(fetched.id, record.id)
        XCTAssertEqual(fetched.name, "My OpenAI")
        XCTAssertEqual(fetched.provider, .openAI)
        XCTAssertEqual(fetched.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(fetched.modelName, "gpt-4o-mini")
        XCTAssertTrue(fetched.isEnabled)
        XCTAssertEqual(fetched.keychainAccount, record.id.uuidString)
    }

    func test_fetchEndpoints_returnsMostRecentFirst() async throws {
        let earliest = APIEndpointRecord(name: "A", provider: .openAI, createdAt: Date(timeIntervalSince1970: 100))
        let middle = APIEndpointRecord(name: "B", provider: .ollama, createdAt: Date(timeIntervalSince1970: 200))
        let newest = APIEndpointRecord(name: "C", provider: .claude, createdAt: Date(timeIntervalSince1970: 300))

        try await store.insertEndpoint(earliest)
        try await store.insertEndpoint(middle)
        try await store.insertEndpoint(newest)

        let endpoints = try await store.fetchEndpoints()
        XCTAssertEqual(endpoints.map(\.name), ["C", "B", "A"])
    }

    // MARK: - Update

    func test_updateEndpoint_persistsFieldChanges() async throws {
        let original = APIEndpointRecord(name: "Original", provider: .openAI)
        try await store.insertEndpoint(original)

        var updated = original
        updated.name = "Renamed"
        updated.modelName = "gpt-4o"
        updated.isEnabled = false
        try await store.updateEndpoint(updated)

        let endpoints = try await store.fetchEndpoints()
        XCTAssertEqual(endpoints.count, 1)
        let fetched = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(fetched.name, "Renamed")
        XCTAssertEqual(fetched.modelName, "gpt-4o")
        XCTAssertFalse(fetched.isEnabled)
    }

    func test_updateEndpoint_unknownID_throwsEndpointNotFound() async throws {
        let bogus = APIEndpointRecord(id: UUID(), name: "Ghost", provider: .openAI)

        do {
            try await store.updateEndpoint(bogus)
            XCTFail("Expected endpointNotFound error")
        } catch let error as EndpointStoreError {
            XCTAssertEqual(error, .endpointNotFound(bogus.id))
        }
    }

    // MARK: - Delete

    func test_deleteEndpoint_removesRow() async throws {
        let record = APIEndpointRecord(name: "ToRemove", provider: .ollama)
        try await store.insertEndpoint(record)

        try await store.deleteEndpoint(record.id)

        let remaining = try await store.fetchEndpoints()
        XCTAssertTrue(remaining.isEmpty)
    }

    func test_deleteEndpoint_unknownID_throwsEndpointNotFound() async throws {
        let bogusID = UUID()

        do {
            try await store.deleteEndpoint(bogusID)
            XCTFail("Expected endpointNotFound error")
        } catch let error as EndpointStoreError {
            XCTAssertEqual(error, .endpointNotFound(bogusID))
        }
    }

    func test_deleteEndpoint_doesNotAffectOthers() async throws {
        let kept = APIEndpointRecord(name: "Keeper", provider: .openAI)
        let removed = APIEndpointRecord(name: "Goner", provider: .ollama)
        try await store.insertEndpoint(kept)
        try await store.insertEndpoint(removed)

        try await store.deleteEndpoint(removed.id)

        let endpoints = try await store.fetchEndpoints()
        XCTAssertEqual(endpoints.map(\.id), [kept.id])
    }

    // MARK: - Record validation hoist

    func test_record_validateBaseURL_acceptsHTTPSEndpoint() {
        let record = APIEndpointRecord(name: "Cloud", provider: .openAI, baseURL: "https://api.openai.com/v1")
        if case .failure = record.validateBaseURL() {
            XCTFail("https://api.openai.com/v1 should validate")
        }
    }

    func test_record_validateBaseURL_rejectsPrivateHost() {
        let record = APIEndpointRecord(name: "Internal", provider: .custom, baseURL: "https://10.0.0.5/v1")
        guard case .failure(let reason) = record.validateBaseURL() else {
            XCTFail("Expected validation failure for 10.0.0.5")
            return
        }
        XCTAssertEqual(reason, .privateHost)
    }

    func test_record_validateBaseURL_acceptsLoopbackOverHTTP() {
        let record = APIEndpointRecord(name: "Local", provider: .ollama, baseURL: "http://localhost:11434")
        if case .failure = record.validateBaseURL() {
            XCTFail("loopback should validate over plain HTTP")
        }
    }

    func test_record_validateBaseURL_rejectsInsecureRemoteScheme() {
        let record = APIEndpointRecord(name: "Insecure", provider: .custom, baseURL: "http://api.example.com/v1")
        guard case .failure(let reason) = record.validateBaseURL() else {
            XCTFail("Expected validation failure for http remote")
            return
        }
        XCTAssertEqual(reason, .insecureScheme)
    }
}
