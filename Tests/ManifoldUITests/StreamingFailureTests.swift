@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

// MARK: - Tests

@MainActor
final class StreamingFailureTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sessionManager: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context), autoLoad: false)
    }

    override func tearDown() async throws {
        sessionManager = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeViewModel(backend: any InferenceBackend, name: String = "MockTest") -> ChatViewModel {
        let service = InferenceService(backend: backend, name: name)
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        return vm
    }

    @discardableResult
    private func createAndActivateSession(vm: ChatViewModel, title: String = "Test Chat") async -> ManifoldInference.ChatSession {
        let session = try! await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    private func fetchMessages(for sessionID: UUID) -> [ManifoldSchemaV9.ChatMessage] {
        let descriptor = FetchDescriptor<ManifoldSchemaV9.ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 1. Mid-stream error preserves partial content

    func test_streamError_midStream_preservesPartialContent() async {
        let backend = MidStreamErrorBackend(
            tokensBeforeError: ["Hello", " world"],
            errorToThrow: InferenceError.inferenceFailure("Simulated mid-stream failure")
        )
        let vm = await makeViewModel(backend: backend)
        let session = await createAndActivateSession(vm: vm)

        vm.inputText = "Say hello"
        await vm.sendMessage()

        // Error message should be set
        XCTAssertNotNil(vm.errorMessage, "Error message should be set after mid-stream failure")

        // Assistant message should preserve partial content
        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Assistant message with partial content should remain")
        XCTAssertEqual(assistantMessages.first?.content, "Hello world", "Partial content should be preserved")

        // User message should still be in the database
        let dbMessages = fetchMessages(for: session.id)
        let userMessages = dbMessages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1, "User message should still be persisted")
        XCTAssertEqual(userMessages.first?.content, "Say hello")
    }

    // MARK: - 2. Mid-stream error sets error message

    func test_streamError_midStream_setsErrorMessage() async {
        let backend = MidStreamErrorBackend(
            tokensBeforeError: ["Hello", " world"],
            errorToThrow: InferenceError.inferenceFailure("Simulated mid-stream failure")
        )
        let vm = await makeViewModel(backend: backend)
        await createAndActivateSession(vm: vm)

        vm.inputText = "Say hello"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNotNil(vm.activeError, "activeError should be set on stream error")
        XCTAssertEqual(vm.activeError?.kind, .generation, "Error kind should be .generation")
        XCTAssertTrue(
            vm.errorMessage?.contains("Simulated mid-stream failure") == true,
            "Error message should contain the underlying error description, got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - 3. Empty stream removes assistant placeholder

    func test_emptyStream_removesAssistantPlaceholder() async {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = []
        let vm = await makeViewModel(backend: backend)
        await createAndActivateSession(vm: vm)

        vm.inputText = "Say something"
        await vm.sendMessage()

        // Only user message should remain
        XCTAssertEqual(vm.messages.count, 1, "Only user message should remain after empty stream")
        XCTAssertEqual(vm.messages.first?.role, .user, "Remaining message should be the user message")
    }

    // MARK: - 4. Single token stream persists correctly

    func test_singleTokenStream_persistsCorrectly() async {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["OK"]
        let vm = await makeViewModel(backend: backend)
        let session = await createAndActivateSession(vm: vm)

        vm.inputText = "Quick question"
        await vm.sendMessage()

        // Check in-memory
        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.content, "OK")

        // Check database
        let dbMessages = fetchMessages(for: session.id)
        let dbAssistant = dbMessages.filter { $0.role == .assistant }
        XCTAssertEqual(dbAssistant.count, 1, "Assistant message should be persisted to DB")
        XCTAssertEqual(dbAssistant.first?.content, "OK")
    }

    // MARK: - 5. Large token count completes successfully

    func test_largeTokenCount_completesSuccessfully() async {
        let tokens = Array(repeating: "t", count: 1000)
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = tokens
        let vm = await makeViewModel(backend: backend)
        vm.loopDetectionEnabled = false
        await createAndActivateSession(vm: vm)

        vm.inputText = "Generate a lot"
        await vm.sendMessage()

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.content.count, 1000, "Should have 1000 characters")
        XCTAssertNil(vm.errorMessage, "No error should occur")
    }

    // MARK: - 6. Unicode tokens are preserved

    func test_streamWithUnicodeTokens_preservesContent() async {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hello ", "\u{1F30D}", " caf\u{00E9}", " na\u{00EF}ve"]
        let vm = await makeViewModel(backend: backend)
        await createAndActivateSession(vm: vm)

        vm.inputText = "Unicode test"
        await vm.sendMessage()

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.content, "Hello \u{1F30D} caf\u{00E9} na\u{00EF}ve")
    }
}
