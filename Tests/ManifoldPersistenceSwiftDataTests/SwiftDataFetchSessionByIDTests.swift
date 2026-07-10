import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

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
        let researcher = ManifoldInference.AgentDefinition(name: "Researcher", systemPrompt: "find facts", description: "")
        let writer = ManifoldInference.AgentDefinition(name: "Writer", systemPrompt: "compose", description: "")
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
