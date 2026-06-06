import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

/// Integration tests for the multi-agent write path (#1495): the
/// `ManifoldInference.ChatSession.agents` registry must survive an insert→fetch and an
/// update→fetch round-trip losslessly, and `activeAgentID` must still resolve
/// against a fetched agent afterwards.
///
/// Classified integration (not unit) per CLAUDE.md: drives a real in-memory
/// SwiftData `ModelContainer` via ``InMemoryPersistenceHarness`` — no mocks.
@MainActor
final class SwiftDataAgentRoundTripTests: XCTestCase {

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

    private func makeAgent(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        description: String = "",
        tools: [String]? = nil
    ) -> ManifoldInference.Agent {
        ManifoldInference.Agent(
            id: id,
            name: name,
            systemPrompt: prompt,
            description: description,
            allowedToolNames: tools
        )
    }

    // MARK: - Insert

    func test_insertSession_persistsAgents() async throws {
        let researcher = makeAgent(name: "Researcher", prompt: "find facts", description: "research role", tools: ["search"])
        let writer = makeAgent(name: "Writer", prompt: "compose prose")
        let record = ManifoldInference.ChatSession(
            title: "Multi-agent",
            agents: [researcher, writer],
            activeAgentID: researcher.id
        )

        try await provider.insertSession(record)

        let sessions = try await provider.fetchSessions()
        let fetched = try XCTUnwrap(sessions.first)
        XCTAssertEqual(Set(fetched.agents.map(\.id)), [researcher.id, writer.id])
        let fetchedResearcher = try XCTUnwrap(fetched.agents.first { $0.id == researcher.id })
        XCTAssertEqual(fetchedResearcher.name, "Researcher")
        XCTAssertEqual(fetchedResearcher.systemPrompt, "find facts")
        XCTAssertEqual(fetchedResearcher.description, "research role")
        XCTAssertEqual(fetchedResearcher.allowedToolNames, ["search"])

        // activeAgentID must still resolve to a fetched agent.
        XCTAssertEqual(fetched.activeAgentID, researcher.id)
        XCTAssertTrue(fetched.agents.contains { $0.id == fetched.activeAgentID })
    }

    // MARK: - Update (add / modify / remove)

    func test_updateSession_reconcilesAgents_add_modify_remove() async throws {
        let keep = makeAgent(name: "Keep", prompt: "v1", tools: ["a"])
        let drop = makeAgent(name: "Drop", prompt: "remove me")
        var record = ManifoldInference.ChatSession(
            title: "Reconcile",
            agents: [keep, drop],
            activeAgentID: keep.id
        )
        try await provider.insertSession(record)

        // Mutate the registry: modify `keep`, remove `drop`, add `added`.
        let modifiedKeep = makeAgent(id: keep.id, name: "Keep v2", prompt: "v2", description: "edited", tools: ["a", "b"])
        let added = makeAgent(name: "Added", prompt: "new agent")
        record.agents = [modifiedKeep, added]
        record.activeAgentID = added.id
        try await provider.updateSession(record)

        let sessions = try await provider.fetchSessions()
        let fetched = try XCTUnwrap(sessions.first)
        XCTAssertEqual(Set(fetched.agents.map(\.id)), [keep.id, added.id], "drop must be deleted, added must be inserted")

        let fetchedKeep = try XCTUnwrap(fetched.agents.first { $0.id == keep.id })
        XCTAssertEqual(fetchedKeep.name, "Keep v2", "modified fields must round-trip")
        XCTAssertEqual(fetchedKeep.systemPrompt, "v2")
        XCTAssertEqual(fetchedKeep.description, "edited")
        XCTAssertEqual(fetchedKeep.allowedToolNames, ["a", "b"])

        // Handoff still resolves after the round-trip.
        XCTAssertEqual(fetched.activeAgentID, added.id)
        XCTAssertTrue(fetched.agents.contains { $0.id == fetched.activeAgentID })
    }

    func test_updateSession_clearingAgents_removesAllRows() async throws {
        let a = makeAgent(name: "A", prompt: "a")
        let b = makeAgent(name: "B", prompt: "b")
        var record = ManifoldInference.ChatSession(title: "Clearable", agents: [a, b])
        try await provider.insertSession(record)

        record.agents = []
        try await provider.updateSession(record)

        let sessions = try await provider.fetchSessions()
        let fetched = try XCTUnwrap(sessions.first)
        XCTAssertTrue(fetched.agents.isEmpty, "emptying the registry must delete every owned Agent row")
    }
}
