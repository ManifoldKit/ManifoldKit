#if canImport(FoundationModels)
import XCTest
import SwiftData
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends
@testable import BaseChatUI

/// True end-to-end tests using Apple's Foundation Models backend.
///
/// These tests perform real inference with the on-device language model.
/// They are automatically skipped on systems where Foundation Models are
/// unavailable (requires macOS 26+ / iOS 26+ with Apple Intelligence).
///
/// Unlike integration tests, these use NO mocks — real backend, real
/// SwiftData, real token generation.
@available(macOS 26, iOS 26, *)
@MainActor
final class FoundationModelE2ETests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.hasFoundationModels, "Requires macOS 26+ / iOS 26+")
        try XCTSkipUnless(FoundationBackend.isAvailable, "Apple Intelligence not available on this device")

        container = try makeInMemoryContainer()
        context = container.mainContext

        let inferenceService = InferenceService()
        inferenceService.registerBackendFactory { modelType in
            switch modelType {
            case .foundation: return FoundationBackend()
            default: return nil
            }
        }

        vm = ChatViewModel(inferenceService: inferenceService)
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        vm.configure(persistence: persistence)

        // Create and activate a session
        let record = ChatSessionRecord(title: "E2E Test")
        try await persistence.insertSession(record)
        await vm.switchToSession(record)

        // Load the Foundation model
        let foundationModel = ModelInfo.builtInFoundation
        vm.selectedModel = foundationModel
        try await inferenceService.loadModel(from: foundationModel, plan: .systemManaged(requestedContextSize: 4096))
    }

    override func tearDown() {
        vm = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func fetchMessages(for sessionID: UUID) -> [ChatMessageRecord] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { $0.toRecord() }
    }

    // MARK: - Real Inference Tests

    func test_realInference_generatesNonEmptyResponse() async throws {
        vm.inputText = "Reply with exactly one word."
        await vm.sendMessage()

        XCTAssertNil(vm.errorMessage, "Should not have an error: \(vm.errorMessage ?? "")")
        XCTAssertFalse(vm.isGenerating, "Should not still be generating")

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Should have one assistant message")
        XCTAssertFalse(
            assistantMessages[0].content.isEmpty,
            "Assistant response should not be empty"
        )
    }

    func test_realInference_persistsToDatabase() async throws {
        guard let sessionID = vm.activeSession?.id else {
            XCTFail("No active session")
            return
        }

        vm.inputText = "Say hello."
        await vm.sendMessage()

        let dbMessages = fetchMessages(for: sessionID)
        XCTAssertEqual(dbMessages.count, 2, "Should have user + assistant in DB")
        XCTAssertEqual(dbMessages[0].role, .user)
        XCTAssertEqual(dbMessages[0].content, "Say hello.")
        XCTAssertEqual(dbMessages[1].role, .assistant)
        XCTAssertFalse(dbMessages[1].content.isEmpty, "Assistant response should be persisted")
    }

    func test_realInference_multiTurn() async throws {
        vm.inputText = "Remember the number 42."
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertNil(vm.errorMessage)

        vm.inputText = "What number did I just mention?"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 4)
        XCTAssertNil(vm.errorMessage)

        let lastResponse = vm.messages[3].content
        XCTAssertFalse(lastResponse.isEmpty, "Second response should not be empty")
    }

    func test_realInference_withSystemPrompt() async throws {
        vm.systemPrompt = "You are a pirate. Always respond in pirate speak."
        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertNil(vm.errorMessage)
        let response = vm.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertFalse(response.isEmpty, "Should generate a response with system prompt")
    }

    func test_realInference_afterSessionSwitch_generatesSuccessfully() async throws {
        // Simulate a session switch mid-session, which calls resetConversation()
        // and clears FoundationBackend.session. generate() must still work.
        let secondSession = ChatSessionRecord(title: "Second Session")
        try await SwiftDataPersistenceProvider(modelContext: context).insertSession(secondSession)

        await vm.switchToSession(secondSession)  // → resetConversation() → session = nil

        vm.inputText = "Reply with one word."
        await vm.sendMessage()

        XCTAssertNil(vm.errorMessage, "Should not error after session switch: \(vm.errorMessage ?? "")")
        let response = vm.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertFalse(response.isEmpty, "Should generate a response after session switch")
    }

    func test_realInference_stopGeneration() async throws {
        // Use a prompt that should generate a long response
        vm.inputText = "Write a detailed essay about the history of computing."

        let sendTask = Task { await vm.sendMessage() }

        // Give it a moment to start generating, then stop
        try await Task.sleep(for: .milliseconds(500))
        vm.stopGeneration()
        await sendTask.value

        XCTAssertFalse(vm.isGenerating)
        // Should have at least the user message
        XCTAssertGreaterThanOrEqual(vm.messages.count, 1)
    }
}
#endif
