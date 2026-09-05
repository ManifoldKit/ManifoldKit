@preconcurrency import XCTest
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// Tests for message pagination: loadMessages pages, loadOlderMessages prepend,
/// hasOlderMessages heuristic, and guard against concurrent loads.
@MainActor
/// Integration coverage uses real SwiftData; existing lower-level cases stay in this suite.
final class PaginationIntegrationTests: XCTestCase {

    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!
    private var stack: InMemoryPersistenceHarness.Stack!
    private var persistence: ErrorInjectingPersistenceProvider!

    override func setUp() async throws {
        try await super.setUp()

        mock = MockInferenceBackend()
        mock.isModelLoaded = true

        let service = InferenceService(backend: mock, name: "MockPagination")
        vm = ChatViewModel(inferenceService: service)

        stack = try InMemoryPersistenceHarness.make()
        persistence = ErrorInjectingPersistenceProvider(wrapping: stack.provider)
        vm.configure(persistence: persistence)
    }

    override func tearDown() async throws {
        vm = nil
        mock = nil
        persistence = nil
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeSession() async -> ManifoldInference.ChatSession {
        let session = ManifoldInference.ChatSession(title: "Pagination Test")
        try! await persistence.insertSession(session)
        await vm.switchToSession(session)
        return session
    }

    /// Inserts `count` messages with sequential timestamps starting from `baseTime`.
    @discardableResult
    private func insertMessages(
        count: Int,
        sessionID: UUID,
        baseTime: Date = Date(timeIntervalSince1970: 1000)
    ) async -> [ManifoldInference.ChatMessage] {
        var records: [ManifoldInference.ChatMessage] = []
        for i in 0..<count {
            let msg = ManifoldInference.ChatMessage(
                role: i % 2 == 0 ? .user : .assistant,
                content: "Message \(i)",
                timestamp: baseTime.addingTimeInterval(Double(i)),
                sessionID: sessionID
            )
            try! await persistence.insertMessage(msg)
            records.append(msg)
        }
        return records
    }

    private func waitForSnapshotGate(
        _ gate: MessageHistoryPageGate,
        olderTask: Task<UUID?, Never>
    ) async throws {
        do {
            try await withTimeout(.seconds(1)) {
                await gate.waitUntilEntered()
            }
        } catch {
            await gate.release()
            _ = try await withTimeout(.seconds(1)) { await olderTask.value }
            throw error
        }
    }

    private func releaseAndJoin(
        _ gate: MessageHistoryPageGate,
        olderTask: Task<UUID?, Never>
    ) async throws {
        await gate.release()
        _ = try await withTimeout(.seconds(1)) { await olderTask.value }
    }

    // MARK: - loadMessages

    func test_loadMessages_loadsRecentPage() async {
        let session = await makeSession()
        let msgs = await insertMessages(count: 10, sessionID: session.id)

        await vm.loadMessages()

        XCTAssertEqual(vm.messages.count, 10)
        XCTAssertEqual(vm.messages.first?.content, msgs.first?.content)
        XCTAssertEqual(vm.messages.last?.content, msgs.last?.content)
        XCTAssertFalse(vm.hasOlderMessages, "Fewer than pageSize messages means no older messages")
    }

    func test_loadMessages_doesNotGuessOlderMessages_whenExactlyOnePageExists() async {
        let session = await makeSession()
        await insertMessages(count: ChatViewModel.messagePageSize, sessionID: session.id)

        await vm.loadMessages()

        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)
        XCTAssertFalse(vm.hasOlderMessages, "The page continuation is definitive; a full page alone is not evidence of older rows")
    }

    func test_loadMessages_setsHasOlderMessages_whenMoreThanPageSize() async {
        let session = await makeSession()
        let totalCount = ChatViewModel.messagePageSize + 20
        await insertMessages(count: totalCount, sessionID: session.id)

        await vm.loadMessages()

        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)
        XCTAssertTrue(vm.hasOlderMessages)
        // Verify we got the most recent messages, not the oldest.
        XCTAssertEqual(vm.messages.last?.content, "Message \(totalCount - 1)")
    }

    func test_loadMessages_withNoSession_clearsState() async {
        vm.activeSession = nil
        vm.messages = [ManifoldInference.ChatMessage(role: .user, content: "stale", sessionID: UUID())]
        vm.hasOlderMessages = true

        await vm.loadMessages()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.hasOlderMessages)
    }

    // MARK: - loadOlderMessages

    func test_loadOlderMessages_prependsOlderPage() async {
        let session = await makeSession()
        let totalCount = ChatViewModel.messagePageSize + 20
        let msgs = await insertMessages(count: totalCount, sessionID: session.id)

        await vm.loadMessages()
        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)

        let anchorID = await vm.loadOlderMessages()

        XCTAssertEqual(vm.messages.count, totalCount)
        // Anchor should be the first message from the initial page (index 20 overall).
        XCTAssertEqual(anchorID, msgs[20].id, "Anchor should be the message that was first before prepend")
        XCTAssertEqual(vm.messages.first?.content, "Message 0")
    }

    func test_loadOlderMessages_returnsNil_whenNoOlderMessages() async {
        await makeSession()

        let anchorID = await vm.loadOlderMessages()
        XCTAssertNil(anchorID, "Should return nil when hasOlderMessages is false")
    }

    func test_loadOlderMessages_setsHasOlderToFalse_whenPartialPage() async {
        let session = await makeSession()
        let totalCount = ChatViewModel.messagePageSize + 10
        await insertMessages(count: totalCount, sessionID: session.id)

        await vm.loadMessages()
        XCTAssertTrue(vm.hasOlderMessages)

        await vm.loadOlderMessages()

        // Only 10 older messages were loaded, which is less than pageSize.
        XCTAssertFalse(vm.hasOlderMessages, "Partial page means no more older messages")
    }

    func test_loadOlderMessages_setsHasOlderToFalse_whenFetchReturnsEmpty() async {
        let session = await makeSession()
        // Insert exactly messagePageSize. A continuation-aware page reports
        // conclusively that no older record exists.
        await insertMessages(count: ChatViewModel.messagePageSize, sessionID: session.id)

        await vm.loadMessages()
        XCTAssertFalse(vm.hasOlderMessages)

        await vm.loadOlderMessages()

        XCTAssertFalse(vm.hasOlderMessages)
    }

    func test_loadOlderMessages_guardsAgainstConcurrentLoads() async {
        let session = await makeSession()
        let totalCount = ChatViewModel.messagePageSize + 20
        await insertMessages(count: totalCount, sessionID: session.id)

        await vm.loadMessages()

        // Simulate isLoadingOlderMessages being true.
        vm.isLoadingOlderMessages = true
        let anchorID = await vm.loadOlderMessages()
        XCTAssertNil(anchorID, "Should not load while another load is in progress")
        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize, "Message count should not change")

        vm.isLoadingOlderMessages = false
    }

    func test_loadOlderMessages_resetsLoadingFlag() async {
        let session = await makeSession()
        let totalCount = ChatViewModel.messagePageSize + 20
        await insertMessages(count: totalCount, sessionID: session.id)

        await vm.loadMessages()
        await vm.loadOlderMessages()

        XCTAssertFalse(vm.isLoadingOlderMessages, "Loading flag should be cleared after load completes")
    }

    // MARK: - clearChat resets pagination state

    func test_clearChat_resetsHasOlderMessages() async {
        let session = await makeSession()
        await insertMessages(count: ChatViewModel.messagePageSize + 10, sessionID: session.id)

        await vm.loadMessages()
        XCTAssertTrue(vm.hasOlderMessages)

        await vm.clearChat()

        XCTAssertFalse(vm.hasOlderMessages)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    // MARK: - Mock call tracking

    func test_loadMessages_callsHistoryPageRequirement() async {
        let session = await makeSession()
        await insertMessages(count: 5, sessionID: session.id)

        // Reset count after switchToSession's loadMessages call.
        persistence.fetchMessageHistoryPageCallCount = 0

        await vm.loadMessages()

        XCTAssertEqual(persistence.fetchMessageHistoryPageCallCount, 1)
    }

    func test_loadOlderMessages_callsHistoryPageRequirement() async {
        let session = await makeSession()
        await insertMessages(count: ChatViewModel.messagePageSize + 10, sessionID: session.id)

        await vm.loadMessages()
        persistence.fetchMessageHistoryPageCallCount = 0

        await vm.loadOlderMessages()

        XCTAssertEqual(persistence.fetchMessageHistoryPageCallCount, 1)
    }

    func test_loadOlderMessages_keepsEveryEqualTimestampRecordAcrossBoundary() async {
        let session = await makeSession()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let records = (0..<(ChatViewModel.messagePageSize + 8)).map { index in
            ManifoldInference.ChatMessage(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                role: .user,
                content: "equal-\(index)",
                timestamp: timestamp,
                sessionID: session.id
            )
        }
        for record in records {
            try! await persistence.insertMessage(record)
        }

        await vm.loadMessages()
        let anchor = await vm.loadOlderMessages()

        XCTAssertEqual(vm.messages.map(\.id), records.map(\.id))
        XCTAssertEqual(anchor, records[8].id)
        XCTAssertFalse(vm.hasOlderMessages)
    }

    func test_staleOlderPage_doesNotInstallAfterReloadAndSessionABA() async throws {
        let sessionA = await makeSession()
        await insertMessages(count: ChatViewModel.messagePageSize + 10, sessionID: sessionA.id)
        await vm.loadMessages()
        let gate = MessageHistoryPageGate()
        persistence.historyPageGate = gate

        let olderTask = Task { @MainActor in
            await self.vm.loadOlderMessages()
        }
        try await waitForSnapshotGate(gate, olderTask: olderTask)

        let sessionB = ManifoldInference.ChatSession(title: "B")
        try! await persistence.insertSession(sessionB)
        await vm.switchToSession(sessionB)
        await vm.switchToSession(sessionA)
        try await releaseAndJoin(gate, olderTask: olderTask)

        XCTAssertEqual(vm.activeSession?.id, sessionA.id)
        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)
        XCTAssertEqual(vm.messages.first?.content, "Message 10")
        XCTAssertFalse(vm.isLoadingOlderMessages)
    }

    func test_staleOlderPage_doesNotInstallAfterDirectActiveSessionABA() async throws {
        let sessionA = await makeSession()
        await insertMessages(count: ChatViewModel.messagePageSize + 10, sessionID: sessionA.id)
        await vm.loadMessages()
        let gate = MessageHistoryPageGate()
        persistence.historyPageGate = gate
        let olderTask = Task { @MainActor in await self.vm.loadOlderMessages() }
        try await waitForSnapshotGate(gate, olderTask: olderTask)

        let sessionB = ManifoldInference.ChatSession(title: "B")
        try! await persistence.insertSession(sessionB)
        vm.activeSession = sessionB
        vm.activeSession = sessionA
        try await releaseAndJoin(gate, olderTask: olderTask)

        XCTAssertEqual(vm.activeSession?.id, sessionA.id)
        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)
        XCTAssertEqual(vm.messages.first?.content, "Message 10")
        XCTAssertFalse(vm.isLoadingOlderMessages)
    }

    func test_staleOlderPage_doesNotRepopulateClearedSession() async throws {
        let session = await makeSession()
        await insertMessages(count: ChatViewModel.messagePageSize + 10, sessionID: session.id)
        await vm.loadMessages()
        let gate = MessageHistoryPageGate()
        persistence.historyPageGate = gate
        let olderTask = Task { @MainActor in await self.vm.loadOlderMessages() }
        try await waitForSnapshotGate(gate, olderTask: olderTask)

        await vm.clearChat()
        try await releaseAndJoin(gate, olderTask: olderTask)

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.hasOlderMessages)
        XCTAssertFalse(vm.isLoadingOlderMessages)
    }

    func test_staleOlderPage_doesNotInstallAfterExplicitReload() async throws {
        let session = await makeSession()
        await insertMessages(count: ChatViewModel.messagePageSize + 10, sessionID: session.id)
        await vm.loadMessages()
        let gate = MessageHistoryPageGate()
        persistence.historyPageGate = gate
        let olderTask = Task { @MainActor in await self.vm.loadOlderMessages() }
        try await waitForSnapshotGate(gate, olderTask: olderTask)

        await vm.loadMessages()
        try await releaseAndJoin(gate, olderTask: olderTask)

        XCTAssertEqual(vm.messages.count, ChatViewModel.messagePageSize)
        XCTAssertEqual(vm.messages.first?.content, "Message 10")
        XCTAssertFalse(vm.isLoadingOlderMessages)
    }
}
