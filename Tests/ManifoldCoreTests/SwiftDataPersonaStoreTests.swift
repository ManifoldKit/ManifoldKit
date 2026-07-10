import XCTest
import SwiftData
import ManifoldRuntime
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

@MainActor
final class SwiftDataPersonaStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: SwiftDataPersonaStore!

    override func setUp() async throws {
        container = try makeInMemoryContainer()
        context = ModelContext(container)
        store = SwiftDataPersonaStore(modelContext: context)
    }

    override func tearDown() async throws {
        store = nil
        context = nil
        container = nil
    }

    // MARK: - Insert + fetch

    func test_fetchPersonas_emptyStore_returnsEmpty() async throws {
        let personas = try await store.fetchPersonas()
        XCTAssertTrue(personas.isEmpty)
    }

    func test_insertPersona_persistsAllFields() async throws {
        let record = PersonaRecord(
            name: "Coding Assistant",
            systemPrompt: "You are an expert Swift engineer. Be concise."
        )

        try await store.insertPersona(record)

        let personas = try await store.fetchPersonas()
        XCTAssertEqual(personas.count, 1)
        let fetched = try XCTUnwrap(personas.first)
        XCTAssertEqual(fetched.id, record.id)
        XCTAssertEqual(fetched.name, "Coding Assistant")
        XCTAssertEqual(fetched.systemPrompt, "You are an expert Swift engineer. Be concise.")
        XCTAssertEqual(fetched.createdAt.timeIntervalSince1970, record.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_fetchPersonas_returnsMostRecentFirst() async throws {
        let earliest = PersonaRecord(name: "A", systemPrompt: "prompt-a", createdAt: Date(timeIntervalSince1970: 100))
        let middle = PersonaRecord(name: "B", systemPrompt: "prompt-b", createdAt: Date(timeIntervalSince1970: 200))
        let newest = PersonaRecord(name: "C", systemPrompt: "prompt-c", createdAt: Date(timeIntervalSince1970: 300))

        try await store.insertPersona(earliest)
        try await store.insertPersona(middle)
        try await store.insertPersona(newest)

        let personas = try await store.fetchPersonas()
        XCTAssertEqual(personas.map(\.name), ["C", "B", "A"])
    }

    // MARK: - Delete

    func test_deletePersona_removesRow() async throws {
        let record = PersonaRecord(name: "ToRemove", systemPrompt: "prompt")
        try await store.insertPersona(record)

        try await store.deletePersona(record.id)

        let remaining = try await store.fetchPersonas()
        XCTAssertTrue(remaining.isEmpty)
    }

    func test_deletePersona_unknownID_throwsPersonaNotFound() async throws {
        let bogusID = UUID()

        do {
            try await store.deletePersona(bogusID)
            XCTFail("Expected personaNotFound error")
        } catch let error as PersonaStoreError {
            XCTAssertEqual(error, .personaNotFound(bogusID))
        }
    }

    func test_deletePersona_doesNotAffectOthers() async throws {
        let kept = PersonaRecord(name: "Keeper", systemPrompt: "keep")
        let removed = PersonaRecord(name: "Goner", systemPrompt: "gone")
        try await store.insertPersona(kept)
        try await store.insertPersona(removed)

        try await store.deletePersona(removed.id)

        let personas = try await store.fetchPersonas()
        XCTAssertEqual(personas.map(\.id), [kept.id])
    }
}
