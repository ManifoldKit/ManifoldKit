import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldPersistenceTestSupport

/// Exercises message-search result resolution through the public session-list
/// adapter and the real in-memory SwiftData provider.
@MainActor
final class SessionManagerMessageSearchIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var persistence: SwiftDataPersistenceProvider!
    private var viewModel: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        persistence = SwiftDataPersistenceProvider(modelContext: container.mainContext)
        viewModel = SessionManagerViewModel()
        viewModel.configure(persistence: persistence, autoLoad: false)
    }

    override func tearDown() async throws {
        viewModel = nil
        persistence = nil
        container = nil
        try await super.tearDown()
    }

    func test_messageSearch_resolvesOldestHitBeyondTenThousandSessions() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        var oldestSessionID: UUID?
        for index in 0...10_000 {
            let session = PersistedChatSession(title: "Session \(index)")
            let timestamp = base.addingTimeInterval(Double(index))
            session.createdAt = timestamp
            session.updatedAt = timestamp
            container.mainContext.insert(session)
            if index == 0 {
                oldestSessionID = session.id
            }
        }
        try container.mainContext.save()
        let oldestID = try XCTUnwrap(oldestSessionID)
        try await persistence.insertMessage(ChatMessage(
            role: .user,
            content: "needle in the oldest session",
            sessionID: oldestID
        ))

        await viewModel.runMessageSearch("needle")

        XCTAssertEqual(viewModel.messageMatchSessions.map(\.id), [oldestID])
        XCTAssertEqual(viewModel.messageHitsBySession[oldestID]?.count, 1)
    }

    func test_messageSearch_deduplicatesSessionsAndPreservesFirstHitOrder() async throws {
        let first = try await insertSession(title: "First")
        let second = try await insertSession(title: "Second")
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        try await persistence.performMessageMutations([
            .insert(ChatMessage(
                role: .user,
                content: "needle newest",
                timestamp: base.addingTimeInterval(30),
                sessionID: first.id
            )),
            .insert(ChatMessage(
                role: .user,
                content: "needle middle",
                timestamp: base.addingTimeInterval(20),
                sessionID: second.id
            )),
            .insert(ChatMessage(
                role: .user,
                content: "needle oldest",
                timestamp: base.addingTimeInterval(10),
                sessionID: first.id
            ))
        ])

        await viewModel.runMessageSearch("needle")

        XCTAssertEqual(viewModel.messageMatchSessions.map(\.id), [first.id, second.id])
        XCTAssertEqual(viewModel.messageHitsBySession[first.id]?.count, 2)
        XCTAssertEqual(viewModel.messageHitsBySession[second.id]?.count, 1)
    }

    func test_messageSearch_keepsHitForMissingSessionWithoutSurfacingSessionRow() async throws {
        let missingSessionID = UUID()
        try await persistence.insertMessage(ChatMessage(
            role: .user,
            content: "needle without a session",
            sessionID: missingSessionID
        ))

        await viewModel.runMessageSearch("needle")

        XCTAssertEqual(viewModel.messageHitsBySession[missingSessionID]?.count, 1)
        XCTAssertTrue(viewModel.messageMatchSessions.isEmpty)
    }

    private func insertSession(title: String) async throws -> ChatSession {
        let session = ChatSession(title: title)
        try await persistence.insertSession(session)
        return session
    }
}
