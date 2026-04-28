@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

// MARK: - Cancellation Tests

@MainActor
final class CancellationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var slowBackend: SlowMockBackend!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        slowBackend = SlowMockBackend()
        slowBackend.tokensToYield = (0..<20).map { "t\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

        let service = InferenceService(backend: slowBackend, name: "SlowMock")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        vm?.stopGeneration()
        vm?.inferenceService.unloadModel()
        vm = nil
        sessionManager = nil
        slowBackend = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Test Chat") async -> ChatSessionRecord {
        let session = try! await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    private func fetchMessages(for sessionID: UUID) -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The full expected output when all 20 tokens are yielded.
    private var fullOutput: String {
        (0..<20).map { "t\($0) " }.joined()
    }

    // MARK: - Helpers

    /// Waits until at least one token has been written into the assistant message,
    /// then stops generation. Guards against the empty-message cleanup path in
    /// generateIntoMessage, which removes the placeholder if content is still empty.
    private func sendAndStopMidStream(input: String = "Hello") async throws {
        vm.inputText = input
        let sendTask = Task { await vm.sendMessage() }
        await vm.awaitFirstToken()
        vm.stopGeneration()
        await sendTask.value
    }

    // MARK: - Tests

    func test_stopGeneration_midStream_stopsTokenFlow() async throws {
        await createAndActivateSession()

        try await sendAndStopMidStream()


        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stopping")
        XCTAssertFalse(vm.inferenceService.hasQueuedRequests, "Queue should be empty after stopGeneration")

        // We should have user + assistant (partial)
        XCTAssertEqual(vm.messages.count, 2, "Should have user message and partial assistant message")
        let assistantContent = vm.messages[1].content
        XCTAssertFalse(assistantContent.isEmpty, "Assistant should have received some tokens")
        XCTAssertNotEqual(assistantContent, fullOutput, "Should not have received all tokens")
    }

    func test_stopGeneration_preservesPartialContent() async throws {
        await createAndActivateSession()

        try await sendAndStopMidStream()

        XCTAssertEqual(vm.messages.count, 2)

        let assistantMessage = vm.messages[1]
        XCTAssertEqual(assistantMessage.role, .assistant)
        XCTAssertFalse(assistantMessage.content.isEmpty, "Partial content should be preserved")
        XCTAssertNotEqual(assistantMessage.content, fullOutput, "Content should differ from full output")
    }

    func test_stopGeneration_thenRegenerate_thenReload_keepsSingleAssistantRow() async throws {
        let session = await createAndActivateSession()

        try await sendAndStopMidStream()

        XCTAssertEqual(vm.messages.count, 2, "Should have user + partial assistant after stop")
        let cancelledAssistant = vm.messages[1]
        let cancelledAssistantID = cancelledAssistant.id

        let cancelledDescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == cancelledAssistantID }
        )
        XCTAssertEqual(
            try context.fetch(cancelledDescriptor).count,
            1,
            "Cancelling should persist exactly one assistant row"
        )

        slowBackend.tokensToYield = ["Regenerated", " reply"]
        slowBackend.delayPerToken = .milliseconds(10)
        await vm.regenerateLastResponse()

        let sessionID = session.id
        let sessionDescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let persisted = try context.fetch(sessionDescriptor)
        XCTAssertEqual(persisted.count, 2, "Regenerate should replace the cancelled assistant row")
        XCTAssertFalse(
            persisted.contains(where: { $0.id == cancelledAssistant.id }),
            "Cancelled assistant row should not survive regeneration"
        )
        XCTAssertEqual(
            persisted.filter { $0.role == .assistant }.count,
            1,
            "Persistence should contain exactly one assistant row after regeneration"
        )

        await vm.switchToSession(session)

        XCTAssertEqual(vm.messages.count, 2, "Reload should restore only the visible user/assistant pair")
        let assistants = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1, "Reload should restore exactly one assistant message")
        XCTAssertEqual(assistants.first?.content, "Regenerated reply")
    }

    func test_stopGeneration_thenSendAgain_works() async throws {
        await createAndActivateSession()

        // First message: stop mid-generation
        try await sendAndStopMidStream(input: "First message")

        XCTAssertEqual(vm.messages.count, 2, "Should have user1 + partial assistant1")
        XCTAssertFalse(vm.isGenerating)

        // Second message: let it complete fully
        slowBackend.tokensToYield = ["Complete", " response"]
        slowBackend.delayPerToken = .milliseconds(10)
        vm.inputText = "Second message"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 4, "Should have user1 + partial_assistant1 + user2 + assistant2")
        XCTAssertEqual(vm.messages[2].role, .user)
        XCTAssertEqual(vm.messages[2].content, "Second message")
        XCTAssertEqual(vm.messages[3].role, .assistant)
        XCTAssertEqual(vm.messages[3].content, "Complete response")
        XCTAssertFalse(vm.isGenerating)
    }

    func test_clearChat_duringGeneration_stopsAndClears() async throws {
        await createAndActivateSession()

        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }
        await vm.awaitGenerating(true)
        await vm.clearChat()
        await sendTask.value

        XCTAssertTrue(vm.messages.isEmpty, "Messages should be empty after clearChat")
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after clearChat")
    }

    func test_unloadModel_duringGeneration_doesNotCrash() async throws {
        await createAndActivateSession()

        slowBackend.tokensToYield = (0..<50).map { "t\($0) " }
        slowBackend.delayPerToken = .milliseconds(30)

        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }
        await vm.awaitGenerating(true)

        // Simulate model switch: unload while generating
        vm.inferenceService.unloadModel()

        await sendTask.value

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after unload")
        XCTAssertFalse(vm.inferenceService.isModelLoaded, "Model should be unloaded")
    }

    func test_switchModel_duringGeneration_doesNotCrash() async throws {
        await createAndActivateSession()

        slowBackend.tokensToYield = (0..<50).map { "t\($0) " }
        slowBackend.delayPerToken = .milliseconds(30)

        vm.inputText = "Hello"
        let sendTask = Task { await vm.sendMessage() }
        await vm.awaitGenerating(true)

        // Unload the old model (simulates switching models)
        vm.inferenceService.unloadModel()

        await sendTask.value

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after model switch")
    }

    func test_isGenerating_falseAfterCompletion() async {
        await createAndActivateSession()

        slowBackend.tokensToYield = ["a", "b", "c"]
        slowBackend.delayPerToken = .milliseconds(10)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after generation completes")
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[1].content, "abc")
    }
}
