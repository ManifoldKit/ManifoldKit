import XCTest
import ManifoldRuntime
import ManifoldInference

// MARK: - PersonaStoreContract

/// Opt-in XCTestCase mixin that exercises the ``PersonaStore`` protocol
/// contract against any conforming implementation.
///
/// ```swift
/// @MainActor
/// final class InMemoryPersonaStoreContractTests: XCTestCase, PersonaStoreContract {
///     func makePersonaStore() -> any PersonaStore {
///         InMemoryPersonaStoreImpl()
///     }
///
///     func test_insertFetch() async throws {
///         try await assertPersonaStore_insertThenFetchReturnsRecord()
///     }
/// }
/// ```
@MainActor
public protocol PersonaStoreContract: AnyObject {
    /// Returns a fresh, empty persona store for each assertion call.
    func makePersonaStore() -> any PersonaStore
}

extension PersonaStoreContract where Self: XCTestCase {

    // MARK: - Fixture helpers

    private func makePersona(
        name: String = "Test Persona",
        systemPrompt: String = "You are a helpful assistant.",
        createdAt: Date = Date()
    ) -> PersonaRecord {
        PersonaRecord(name: name, systemPrompt: systemPrompt, createdAt: createdAt)
    }

    // MARK: - Empty-store baseline

    /// Asserts that a fresh store returns an empty array from ``fetchPersonas()``.
    public func assertPersonaStore_emptyStoreReturnsNoPersonas(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makePersonaStore()
        let result = try await store.fetchPersonas()
        XCTAssertTrue(result.isEmpty, "Fresh store must return no personas", file: file, line: line)
    }

    // MARK: - Insert / Fetch

    /// Asserts that an inserted persona is returned by ``fetchPersonas()``.
    public func assertPersonaStore_insertThenFetchReturnsRecord(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makePersonaStore()
        let persona = makePersona(name: "Assistant")
        try await store.insertPersona(persona)

        let fetched = try await store.fetchPersonas()
        XCTAssertEqual(fetched.count, 1, file: file, line: line)
        XCTAssertEqual(fetched.first?.id, persona.id, file: file, line: line)
        XCTAssertEqual(fetched.first?.name, persona.name, file: file, line: line)
        XCTAssertEqual(fetched.first?.systemPrompt, persona.systemPrompt, file: file, line: line)
    }

    // MARK: - Most-recently-created ordering

    /// Asserts that ``fetchPersonas()`` orders personas most-recently-created
    /// first, as documented on the protocol.
    public func assertPersonaStore_fetchOrdersByMostRecentlyCreatedFirst(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makePersonaStore()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let older = makePersona(name: "Older", createdAt: base)
        let newer = makePersona(name: "Newer", createdAt: base.addingTimeInterval(10))
        try await store.insertPersona(older)
        try await store.insertPersona(newer)

        let fetched = try await store.fetchPersonas()
        XCTAssertEqual(
            fetched.map(\.id), [newer.id, older.id],
            "fetchPersonas() must return most-recently-created first",
            file: file, line: line
        )
    }

    // MARK: - Delete

    /// Asserts that a deleted persona is no longer returned by ``fetchPersonas()``.
    public func assertPersonaStore_deletedPersonaNotReturned(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makePersonaStore()
        let persona = makePersona(name: "To delete")
        try await store.insertPersona(persona)
        try await store.deletePersona(persona.id)

        let fetched = try await store.fetchPersonas()
        XCTAssertFalse(
            fetched.contains { $0.id == persona.id },
            "Deleted persona must not appear in subsequent fetch",
            file: file, line: line
        )
    }

    /// Asserts that ``deletePersona(_:)`` throws
    /// ``PersonaStoreError/personaNotFound(_:)`` for an unknown ID.
    public func assertPersonaStore_deleteUnknownIDThrowsNotFound(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makePersonaStore()
        let unknownID = UUID()
        do {
            try await store.deletePersona(unknownID)
            XCTFail("delete of unknown id must throw", file: file, line: line)
        } catch PersonaStoreError.personaNotFound(let id) {
            XCTAssertEqual(id, unknownID, file: file, line: line)
        } catch {
            XCTFail("Expected PersonaStoreError.personaNotFound, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Multiple personas

    /// Asserts that inserting multiple personas and fetching all returns all of them.
    public func assertPersonaStore_multiplePersonasAllReturned(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makePersonaStore()
        let personas = [
            makePersona(name: "Coding Assistant"),
            makePersona(name: "Creative Writer"),
            makePersona(name: "Socratic Tutor"),
        ]
        for p in personas {
            try await store.insertPersona(p)
        }

        let fetched = try await store.fetchPersonas()
        XCTAssertEqual(fetched.count, 3, "All inserted personas must be returned", file: file, line: line)
        let fetchedIDs = Set(fetched.map(\.id))
        let insertedIDs = Set(personas.map(\.id))
        XCTAssertEqual(fetchedIDs, insertedIDs, file: file, line: line)
    }
}
