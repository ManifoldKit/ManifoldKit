import XCTest
import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - InMemoryPersonaStore (test double for contract adoption)

@MainActor
private final class InMemoryPersonaStore: PersonaStore {
    private var personas: [PersonaRecord] = []

    func fetchPersonas() async throws -> [PersonaRecord] {
        personas.sorted { $0.createdAt > $1.createdAt }
    }

    func insertPersona(_ record: PersonaRecord) async throws {
        personas.append(record)
    }

    func deletePersona(_ id: UUID) async throws {
        guard let idx = personas.firstIndex(where: { $0.id == id }) else {
            throw PersonaStoreError.personaNotFound(id)
        }
        personas.remove(at: idx)
    }
}

// MARK: - InMemoryPersonaStoreContractTests

@MainActor
final class InMemoryPersonaStoreContractTests: XCTestCase, PersonaStoreContract {

    func makePersonaStore() -> any PersonaStore {
        InMemoryPersonaStore()
    }

    func test_emptyStore_returnsNoPersonas() async throws {
        try await assertPersonaStore_emptyStoreReturnsNoPersonas()
    }

    func test_insert_thenFetch_returnsRecord() async throws {
        try await assertPersonaStore_insertThenFetchReturnsRecord()
    }

    func test_fetch_ordersByMostRecentlyCreatedFirst() async throws {
        try await assertPersonaStore_fetchOrdersByMostRecentlyCreatedFirst()
    }

    func test_delete_deletedPersonaNotReturned() async throws {
        try await assertPersonaStore_deletedPersonaNotReturned()
    }

    func test_delete_unknownID_throwsNotFound() async throws {
        try await assertPersonaStore_deleteUnknownIDThrowsNotFound()
    }

    func test_multiplePersonas_allReturned() async throws {
        try await assertPersonaStore_multiplePersonasAllReturned()
    }
}
