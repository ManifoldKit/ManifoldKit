import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldContractTestSupport

/// Integration coverage for the per-turn single-session read
/// (`perf: fetch sessions by id`). The SwiftData adapter overrides
/// ``SessionStore/fetchSession(id:)`` with a predicate pushdown instead of
/// scanning the whole table. These tests drive a real in-memory
/// `ModelContainer` via ``InMemoryPersistenceHarness`` — no mocks.
@MainActor
final class SwiftDataFetchSessionByIDTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    private var provider: SwiftDataPersistenceProvider { stack.provider }

    func test_fetchSessionByID_returnsMatchingRecord() async throws {
        let plain = ManifoldInference.ChatSession(title: "Plain")
        let pinned = ManifoldInference.ChatSession(
            title: "Pinned",
            isPinned: true,
            pinnedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try await provider.insertSession(plain)
        try await provider.insertSession(pinned)

        let fetchedPlain = try await provider.fetchSession(id: plain.id)
        XCTAssertEqual(fetchedPlain?.id, plain.id)
        XCTAssertEqual(fetchedPlain?.title, "Plain")
        XCTAssertFalse(fetchedPlain?.isPinned ?? true)

        let fetchedPinned = try await provider.fetchSession(id: pinned.id)
        XCTAssertEqual(fetchedPinned?.id, pinned.id)
        XCTAssertTrue(fetchedPinned?.isPinned ?? false)
    }

    func test_fetchSessionByID_absentID_returnsNil() async throws {
        try await provider.insertSession(ManifoldInference.ChatSession(title: "Only"))
        let absent = try await provider.fetchSession(id: UUID())
        XCTAssertNil(absent)
    }

    /// The matched row's `agents` fault is load-bearing — the turn loop reads
    /// agents and `activeAgentID` off the fetched record, so the override must
    /// still materialize them on the single matched row.
    func test_fetchSessionByID_roundTripsAgentsAndActiveAgent() async throws {
        let researcher = ManifoldInference.Agent(name: "Researcher", systemPrompt: "find facts", description: "")
        let writer = ManifoldInference.Agent(name: "Writer", systemPrompt: "compose", description: "")
        let record = ManifoldInference.ChatSession(
            title: "Multi-agent",
            agents: [researcher, writer],
            activeAgentID: researcher.id
        )
        // A second session in the table proves the predicate isolates the match.
        try await provider.insertSession(ManifoldInference.ChatSession(title: "Decoy"))
        try await provider.insertSession(record)

        let fetchedOrNil = try await provider.fetchSession(id: record.id)
        let fetched = try XCTUnwrap(fetchedOrNil)
        XCTAssertEqual(Set(fetched.agents.map(\.id)), [researcher.id, writer.id])
        XCTAssertEqual(fetched.activeAgentID, researcher.id)
        XCTAssertTrue(fetched.agents.contains { $0.id == fetched.activeAgentID })
    }
}

// MARK: - Contract adoption (storage-backed override)

/// Runs the shared ``SessionStoreContract`` against the SwiftData adapter so
/// the predicate-pushdown override is exercised by the same assertions as the
/// in-memory default-impl adopter in `ManifoldRuntimeTests` — proving the two
/// agree on `fetchSession(id:)` behavior.
@MainActor
final class SwiftDataSessionStoreContractTests: XCTestCase, SessionStoreContract {

    // Retains every stack the contract spins up for the test's lifetime. A
    // `ModelContext` does not keep its `ModelContainer` alive on its own, so
    // returning a bare provider from a discarded `Stack` would tear the
    // in-memory container down mid-assertion (delete paths crash). Hold the
    // stacks here and clear them in tearDown.
    private var stacks: [InMemoryPersistenceHarness.Stack] = []

    override func tearDown() async throws {
        stacks.removeAll()
        try await super.tearDown()
    }

    func makeSessionStore() -> any SessionStore {
        do {
            let stack = try InMemoryPersistenceHarness.make()
            stacks.append(stack)
            return stack.provider
        } catch {
            // The harness only fails on a misconfigured schema, which is a
            // programmer error here — surface it loudly rather than masking it.
            fatalError("InMemoryPersistenceHarness.make() failed: \(error)")
        }
    }

    func test_emptyStore_returnsNoSessions() async throws {
        try await assertSessionStore_emptyStoreReturnsNoSessions()
    }

    func test_insert_thenFetch_returnsRecord() async throws {
        try await assertSessionStore_insertThenFetchReturnsRecord()
    }

    func test_fetchByID_returnsMatchOrNil() async throws {
        try await assertSessionStore_fetchByIDReturnsMatchOrNil()
    }

    func test_fetch_ordersByMostRecentlyUpdatedFirst() async throws {
        try await assertSessionStore_fetchOrdersByMostRecentlyUpdatedFirst()
    }

    func test_update_persistsChanges() async throws {
        try await assertSessionStore_updatePersistsChanges()
    }

    func test_update_unknownID_throwsNotFound() async throws {
        try await assertSessionStore_updateUnknownIDThrowsNotFound()
    }

    func test_delete_deletedSessionNotReturned() async throws {
        try await assertSessionStore_deletedSessionNotReturned()
    }

    func test_delete_unknownID_throwsNotFound() async throws {
        try await assertSessionStore_deleteUnknownIDThrowsNotFound()
    }

    func test_deleteAll_removesEverything() async throws {
        try await assertSessionStore_deleteAllRemovesEverything()
    }

    func test_fetchWithPagination_returnsCorrectSlice() async throws {
        try await assertSessionStore_fetchWithPaginationReturnsCorrectSlice()
    }
}
