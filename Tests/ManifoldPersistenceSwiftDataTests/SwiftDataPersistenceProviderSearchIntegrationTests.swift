import Foundation
import XCTest
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldPersistenceTestSupport
import ManifoldRuntime

/// Real-SwiftData coverage for the complete, bounded candidate scan used by
/// ``SwiftDataPersistenceProvider/searchMessages(query:limit:)``.
@MainActor
final class SwiftDataPersistenceProviderSearchIntegrationTests: XCTestCase {

    private enum SearchTestError: Error {
        case firstPageDeadlineElapsed
    }

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

    func test_searchMessages_findsCompleteMatchPastFormerCandidateCap() async throws {
        let session = try await makeSession(title: "Past candidate cap")
        let timestamp = Date(timeIntervalSince1970: 1_000)
        var records = (0..<10).map { index in
            message(
                content: "dragon distractor \(index)",
                timestamp: timestamp.addingTimeInterval(Double(index + 1)),
                sessionID: session.id
            )
        }
        let expected = message(
            content: "dragon with hidden treasure",
            timestamp: timestamp,
            sessionID: session.id
        )
        records.append(expected)
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let hits = try await provider.searchMessages(query: "dragon treasure", limit: 1)

        XCTAssertEqual(hits.map(\.messageID), [expected.id])
    }

    func test_searchMessages_scansExactCandidatePagesUntilExhaustion() async throws {
        let session = try await makeSession(title: "Candidate pages")
        let probe = CandidatePageProbe()
        provider.searchCandidatePageObserver = { page in await probe.record(page) }
        let base = Date(timeIntervalSince1970: 2_000)
        var records = (0..<100).map { index in
            message(
                content: "dragon distractor \(index)",
                timestamp: base.addingTimeInterval(Double(index + 1)),
                sessionID: session.id
            )
        }
        let expected = message(
            content: "dragon and treasure beyond the page",
            timestamp: base,
            sessionID: session.id
        )
        records.append(expected)
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let hits = try await provider.searchMessages(query: "dragon treasure", limit: 2)
        let fetchedPages = await probe.pages()

        XCTAssertEqual(hits.map(\.messageID), [expected.id])
        XCTAssertEqual(fetchedPages, [1, 2], "One full candidate page and one short exhaustion page should be fetched")
    }

    func test_searchMessages_keysetsAcrossEqualTimestampUUIDBoundary() async throws {
        let session = try await makeSession(title: "Equal timestamp boundary")
        let probe = CandidatePageProbe()
        provider.searchCandidatePageObserver = { page in await probe.record(page) }
        let timestamp = Date(timeIntervalSince1970: 3_000)
        let ids = try (0...100).map { index in
            try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)))
        }
        let records = ids.enumerated().map { index, id in
            message(
                id: id,
                content: index == 0 ? "dragon treasure at UUID boundary" : "dragon distractor \(index)",
                timestamp: timestamp,
                sessionID: session.id
            )
        }
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let hits = try await provider.searchMessages(query: "dragon treasure", limit: 1)
        let fetchedPages = await probe.pages()

        XCTAssertEqual(hits.map(\.messageID), [ids[0]])
        XCTAssertEqual(fetchedPages, [1, 2], "The UUID tie-breaker must advance from the first equal-timestamp page")
    }

    func test_searchMessages_returnsOrderedUniqueEqualTimestampMatchesAcrossPages() async throws {
        let session = try await makeSession(title: "Equal timestamp complete scan")
        let probe = CandidatePageProbe()
        provider.searchCandidatePageObserver = { page in await probe.record(page) }
        let timestamp = Date(timeIntervalSince1970: 3_500)
        let ids = try (0...200).map { index in
            try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)))
        }
        let records = ids.map { id in
            message(
                id: id,
                content: "dragon treasure \(id.uuidString)",
                timestamp: timestamp,
                sessionID: session.id
            )
        }
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let hits = try await provider.searchMessages(query: "dragon treasure", limit: records.count)
        let fetchedPages = await probe.pages()

        XCTAssertEqual(hits.map(\.messageID), Array(ids.reversed()))
        XCTAssertEqual(Set(hits.map(\.messageID)).count, ids.count, "Keyset pages must neither repeat nor drop equal-timestamp rows")
        XCTAssertEqual(fetchedPages, [1, 2, 3])
    }

    func test_searchMessages_exhaustsMultiTermMissAcrossCandidatePages() async throws {
        let session = try await makeSession(title: "Candidate miss exhaustion")
        let probe = CandidatePageProbe()
        provider.searchCandidatePageObserver = { page in await probe.record(page) }
        let base = Date(timeIntervalSince1970: 3_750)
        let records = (0..<101).map { index in
            message(
                content: "dragon distractor \(index)",
                timestamp: base.addingTimeInterval(Double(index)),
                sessionID: session.id
            )
        }
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let hits = try await provider.searchMessages(query: "dragon treasure", limit: 1)
        let fetchedPages = await probe.pages()

        XCTAssertTrue(hits.isEmpty)
        XCTAssertEqual(fetchedPages, [1, 2], "A multi-term miss must keep scanning past a full first-term candidate page")
    }

    func test_searchMessages_respectsResultLimitAndHandlesBoundaryLimits() async throws {
        let session = try await makeSession(title: "Search limits")
        let base = Date(timeIntervalSince1970: 4_000)
        let records = (0..<3).map { index in
            message(
                content: "dragon treasure \(index)",
                timestamp: base.addingTimeInterval(Double(index)),
                sessionID: session.id
            )
        }
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let limited = try await provider.searchMessages(query: "dragon treasure", limit: 2)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(limited.map(\.messageID), [records[2].id, records[1].id])

        let exhausted = try await provider.searchMessages(query: "dragon treasure", limit: 10)
        XCTAssertEqual(exhausted.map(\.messageID), [records[2].id, records[1].id, records[0].id])
        let empty = try await provider.searchMessages(query: "", limit: 1)
        let whitespace = try await provider.searchMessages(query: "   ", limit: 1)
        let negative = try await provider.searchMessages(query: "dragon", limit: -1)
        let zero = try await provider.searchMessages(query: "dragon", limit: 0)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(whitespace.isEmpty)
        XCTAssertTrue(negative.isEmpty)
        XCTAssertTrue(zero.isEmpty)

        let maximum = try await provider.searchMessages(query: "dragon treasure", limit: .max)
        XCTAssertEqual(maximum.map(\.messageID), [records[2].id, records[1].id, records[0].id])
    }

    func test_searchMessages_cancellationStopsBeforeNextCandidateFetch() async throws {
        try await assertCancellationAfterFirstPage(candidateCount: 200)
    }

    func test_searchMessages_cancellationOnFinalPageDoesNotReturnResults() async throws {
        try await assertCancellationAfterFirstPage(candidateCount: 1)
    }

    private func assertCancellationAfterFirstPage(candidateCount: Int) async throws {
        let session = try await makeSession(title: "Search cancellation")
        let gate = CandidatePageGate()
        provider.searchCandidatePageObserver = { page in await gate.observe(page) }
        let base = Date(timeIntervalSince1970: 5_000)
        let records = (0..<candidateCount).map { index in
            message(
                content: "dragon distractor \(index)",
                timestamp: base.addingTimeInterval(Double(index)),
                sessionID: session.id
            )
        }
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let task = Task { @MainActor [provider] in
            try await provider.searchMessages(query: "dragon treasure", limit: 1)
        }

        do {
            try await waitForFirstCandidatePage(from: gate)
            task.cancel()
            await gate.open()

            do {
                _ = try await task.value
                XCTFail("Cancelled searches must throw before returning or fetching another candidate page")
            } catch is CancellationError {
                // Expected: the provider checks cancellation between pages.
            }
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
        let fetchedPages = await gate.pages()
        XCTAssertEqual(fetchedPages, [1], "Cancellation must prevent the next SwiftData candidate fetch")
    }

    private func waitForFirstCandidatePage(from gate: CandidatePageGate) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await gate.waitForFirstPage() }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw SearchTestError.firstPageDeadlineElapsed
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func makeSession(title: String) async throws -> ChatSession {
        let session = ChatSession(title: title)
        try await provider.insertSession(session)
        return session
    }

    private func message(
        id: UUID = UUID(),
        content: String,
        timestamp: Date,
        sessionID: UUID
    ) -> ChatMessage {
        ChatMessage(id: id, role: .user, content: content, timestamp: timestamp, sessionID: sessionID)
    }
}

private actor CandidatePageProbe {
    private var recordedPages: [Int] = []

    func record(_ page: Int) {
        recordedPages.append(page)
    }

    func pages() -> [Int] {
        recordedPages
    }
}

private actor CandidatePageGate {
    private var recordedPages: [Int] = []
    private var firstPageEntered = false
    private var isOpen = false
    private var firstPageWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var parkedContinuation: CheckedContinuation<Void, Never>?

    func observe(_ page: Int) async {
        recordedPages.append(page)
        guard page == 1 else { return }
        firstPageEntered = true
        let waiters = firstPageWaiters.values
        firstPageWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            parkedContinuation = continuation
        }
    }

    func waitForFirstPage() async throws {
        if firstPageEntered { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if firstPageEntered {
                    continuation.resume()
                } else {
                    firstPageWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelFirstPageWaiter(waiterID) }
        }
    }

    func open() {
        isOpen = true
        parkedContinuation?.resume()
        parkedContinuation = nil
    }

    func pages() -> [Int] {
        recordedPages
    }

    private func cancelFirstPageWaiter(_ id: UUID) {
        firstPageWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
