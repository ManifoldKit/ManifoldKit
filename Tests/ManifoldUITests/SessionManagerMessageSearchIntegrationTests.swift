import XCTest
import os
import SwiftData
@testable import ManifoldUI
@testable import ManifoldRuntime
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
        var oldestSessionIDCandidate: UUID?
        for index in 0...10_000 {
            let session = PersistedChatSession(title: "Session \(index)")
            let timestamp = base.addingTimeInterval(Double(index))
            session.createdAt = timestamp
            session.updatedAt = timestamp
            container.mainContext.insert(session)
            if index == 0 {
                oldestSessionIDCandidate = session.id
            }
        }
        try container.mainContext.save()
        let oldestSessionID = try XCTUnwrap(oldestSessionIDCandidate)
        try await persistence.insertMessage(ChatMessage(
            role: .user,
            content: "needle in the oldest session",
            sessionID: oldestSessionID
        ))

        await viewModel.runMessageSearch("needle")

        XCTAssertEqual(viewModel.messageMatchSessions.map(\.id), [oldestSessionID])
        XCTAssertEqual(viewModel.messageHitsBySession[oldestSessionID]?.count, 1)
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

    func test_messageSearch_newerQueryPreventsOlderResultFromOverwritingIt() async throws {
        let old = try await insertSession(title: "Old")
        let new = try await insertSession(title: "New")
        try await persistence.performMessageMutations([
            .insert(ChatMessage(role: .user, content: "old needle", sessionID: old.id)),
            .insert(ChatMessage(role: .user, content: "new needle", sessionID: new.id))
        ])
        let gate = SearchGate()
        let reachedOldSearch = expectation(description: "old search reached observer")
        guard let viewModel else {
            XCTFail("Expected configured session manager")
            return
        }
        let service = try XCTUnwrap(viewModel.service)
        service.messageSearchObserver = { query in
            guard query == "old" else { return }
            reachedOldSearch.fulfill()
            await gate.wait()
        }

        let oldTask = Task { @MainActor [viewModel] in
            await viewModel.runMessageSearch("old")
        }
        await fulfillment(of: [reachedOldSearch], timeout: 2)

        await viewModel.runMessageSearch("new")
        XCTAssertEqual(viewModel.messageMatchSessions.map(\.id), [new.id])

        await gate.release()
        await oldTask.value
        service.messageSearchObserver = nil

        XCTAssertEqual(viewModel.messageMatchSessions.map(\.id), [new.id])
    }

    func test_messageSearch_clearPreventsOlderResultFromOverwritingEmptyState() async throws {
        let session = try await insertSession(title: "Old")
        try await persistence.insertMessage(ChatMessage(role: .user, content: "old needle", sessionID: session.id))
        let gate = SearchGate()
        let reachedOldSearch = expectation(description: "old search reached observer")
        guard let viewModel else {
            XCTFail("Expected configured session manager")
            return
        }
        let service = try XCTUnwrap(viewModel.service)
        service.messageSearchObserver = { query in
            guard query == "old" else { return }
            reachedOldSearch.fulfill()
            await gate.wait()
        }

        let oldTask = Task { @MainActor [viewModel] in
            await viewModel.runMessageSearch("old")
        }
        await fulfillment(of: [reachedOldSearch], timeout: 2)

        viewModel.clearSearch()
        await gate.release()
        await oldTask.value
        service.messageSearchObserver = nil

        XCTAssertTrue(viewModel.messageHitsBySession.isEmpty)
        XCTAssertTrue(viewModel.messageMatchSessions.isEmpty)
    }

    func test_messageSearch_titleScopePreventsOlderResultFromOverwritingIt() async throws {
        let session = try await insertSession(title: "Fresh title")
        try await persistence.insertMessage(ChatMessage(role: .user, content: "old needle", sessionID: session.id))
        await viewModel.loadSessions()
        let gate = SearchGate()
        let reachedOldSearch = expectation(description: "old search reached observer")
        guard let viewModel else {
            XCTFail("Expected configured session manager")
            return
        }
        let service = try XCTUnwrap(viewModel.service)
        service.messageSearchObserver = { query in
            guard query == "old" else { return }
            reachedOldSearch.fulfill()
            await gate.wait()
        }

        let oldTask = Task { @MainActor [viewModel] in
            await viewModel.runMessageSearch("old")
        }
        await fulfillment(of: [reachedOldSearch], timeout: 2)

        viewModel.searchScope = .titles
        viewModel.searchQuery = "fresh"
        viewModel.runTitleSearch("fresh")
        await gate.release()
        await oldTask.value
        service.messageSearchObserver = nil

        XCTAssertEqual(viewModel.titleMatches.map(\.id), [session.id])
        XCTAssertTrue(viewModel.messageHitsBySession.isEmpty)
        XCTAssertTrue(viewModel.messageMatchSessions.isEmpty)
    }

    func test_messageSearch_cancelledSearchDoesNotEmitPersistenceFailure() async throws {
        let session = try await insertSession(title: "Search")
        try await persistence.insertMessage(ChatMessage(role: .user, content: "needle", sessionID: session.id))
        let service = SessionListService(persistence: persistence)
        let collector = EventCollector()
        service.setEventSink(collector.sink)
        service.messageSearchObserver = { _ in throw CancellationError() }

        await service.runMessageSearch("needle")

        XCTAssertFalse(collector.snapshot().containsPersistenceFailure)
    }

    func test_messageSearch_staleObserverFailureDoesNotEmitPersistenceFailure() async throws {
        let session = try await insertSession(title: "Search")
        try await persistence.insertMessage(ChatMessage(role: .user, content: "needle", sessionID: session.id))
        let gate = SearchGate()
        let reachedSearch = expectation(description: "search reached observer")
        let service = SessionListService(persistence: persistence)
        let collector = EventCollector()
        service.setEventSink(collector.sink)
        service.messageSearchObserver = { _ in
            reachedSearch.fulfill()
            await gate.wait()
            throw SearchObserverError.injected
        }

        let task = Task { @MainActor in
            await service.runMessageSearch("needle")
        }
        await fulfillment(of: [reachedSearch], timeout: 2)

        service.invalidateMessageSearch()
        await gate.release()
        await task.value

        XCTAssertFalse(collector.snapshot().containsPersistenceFailure)
    }

    func test_messageSearch_sidebarHelperWaitsForProviderAndCancelsItsScan() async throws {
        let session = try await insertSession(title: "Search")
        try await persistence.insertMessage(ChatMessage(role: .user, content: "needle", sessionID: session.id))
        let gate = SearchGate()
        let reachedProvider = expectation(description: "real provider search reached observer")
        let cancellationReachedProvider = expectation(description: "provider observer receives cancellation")
        let completion = CompletionProbe()
        let viewModel = try XCTUnwrap(viewModel)
        persistence.searchCandidatePageObserver = { _ in
            reachedProvider.fulfill()
            await gate.wait()
            if Task.isCancelled {
                cancellationReachedProvider.fulfill()
            }
        }

        let searchTask = Task { @MainActor [viewModel] in
            await SessionListView.runSearch(query: "needle", scope: .messages, on: viewModel)
            await completion.finish()
        }
        await fulfillment(of: [reachedProvider], timeout: 2)
        let finishedBeforeCancellation = await completion.isFinished()
        XCTAssertFalse(finishedBeforeCancellation)

        searchTask.cancel()
        await gate.release()
        await fulfillment(of: [cancellationReachedProvider], timeout: 2)
        await searchTask.value
        persistence.searchCandidatePageObserver = nil

        let finishedAfterCancellation = await completion.isFinished()
        XCTAssertTrue(finishedAfterCancellation)
        XCTAssertTrue(viewModel.messageMatchSessions.isEmpty)
    }

    private func insertSession(title: String) async throws -> ChatSession {
        let session = ChatSession(title: title)
        try await persistence.insertSession(session)
        return session
    }

    private actor SearchGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private enum SearchObserverError: Error {
        case injected
    }

    private actor CompletionProbe {
        private var finished = false

        func finish() {
            finished = true
        }

        func isFinished() -> Bool {
            finished
        }
    }

    private final class EventCollector: Sendable {
        private let events = OSAllocatedUnfairLock<[SessionListEvent]>(initialState: [])

        var sink: @Sendable (SessionListEvent) -> Void {
            { [events] event in
                events.withLock { $0.append(event) }
            }
        }

        func snapshot() -> [SessionListEvent] {
            events.withLock { $0 }
        }
    }
}

private extension Array where Element == SessionListEvent {
    var containsPersistenceFailure: Bool {
        contains { event in
            if case .persistenceFailure = event {
                return true
            }
            return false
        }
    }
}
