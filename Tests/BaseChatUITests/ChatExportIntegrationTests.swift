@preconcurrency import XCTest
import SwiftData
@testable import BaseChatCore
@testable import BaseChatInference
@testable import BaseChatUI
import BaseChatTestSupport

/// Integration test: generates real conversation turns via ChatViewModel,
/// then exports through ChatExportService and verifies the output format.
@MainActor
final class ChatExportIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sessionManager: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence)
    }

    override func tearDown() async throws {
        sessionManager = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeMockBackend(tokens: [String]) -> MockInferenceBackend {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = tokens
        return backend
    }

    private func makeViewModel(backend: MockInferenceBackend) -> ChatViewModel {
        let service = InferenceService(backend: backend, name: "ExportTest")
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)
        return vm
    }

    @discardableResult
    private func createAndActivateSession(
        vm: ChatViewModel,
        title: String = "Test Chat"
    ) async throws -> ChatSessionRecord {
        let session = try await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    // MARK: - Multi-turn markdown export

    func test_multiTurnConversation_markdownExport_containsAllTurns() async throws {
        let backend = makeMockBackend(tokens: ["Hello", " there!"])
        let vm = await makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm, title: "Story Time")

        // Turn 1
        vm.inputText = "Hi"
        await vm.sendMessage()

        // Turn 2
        backend.tokensToYield = ["Sure,", " here", " you go."]
        vm.inputText = "Tell me a story"
        await vm.sendMessage()

        let markdown = ChatExportService.export(
            messages: vm.messages,
            sessionTitle: "Story Time",
            format: .markdown
        )

        // Title as H1
        XCTAssertTrue(markdown.hasPrefix("# Story Time"), "Markdown should start with H1 title")

        // Horizontal rule
        XCTAssertTrue(markdown.contains("---"), "Markdown should contain a horizontal rule")

        // Role labels
        XCTAssertTrue(markdown.contains("**User:**"), "Markdown should contain bold User label")
        XCTAssertTrue(markdown.contains("**Assistant:**"), "Markdown should contain bold Assistant label")

        // User messages in order
        XCTAssertTrue(markdown.contains("Hi"), "First user message should appear")
        XCTAssertTrue(markdown.contains("Tell me a story"), "Second user message should appear")

        // Assistant messages
        XCTAssertTrue(markdown.contains("Hello there!"), "First assistant reply should appear")
        XCTAssertTrue(markdown.contains("Sure, here you go."), "Second assistant reply should appear")

        // Verify ordering: first user turn appears before second
        let hiRange = try XCTUnwrap(markdown.range(of: "\nHi\n"), "First user message not found in markdown")
        let storyRange = try XCTUnwrap(markdown.range(of: "Tell me a story"), "Second user message not found in markdown")
        XCTAssertTrue(hiRange.lowerBound < storyRange.lowerBound,
                      "First user message should precede the second")
    }

    // MARK: - Multi-turn plaintext export

    func test_multiTurnConversation_plaintextExport_containsAllTurns() async throws {
        let backend = makeMockBackend(tokens: ["I'm", " fine."])
        let vm = await makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm, title: "Casual Chat")

        // Turn 1
        vm.inputText = "How are you?"
        await vm.sendMessage()

        // Turn 2
        backend.tokensToYield = ["Goodbye!"]
        vm.inputText = "See you later"
        await vm.sendMessage()

        let plaintext = ChatExportService.export(
            messages: vm.messages,
            sessionTitle: "Casual Chat",
            format: .plainText
        )

        // Title line
        XCTAssertTrue(plaintext.contains("Chat: Casual Chat"), "Plaintext should include session title")

        // Role-prefixed content
        XCTAssertTrue(plaintext.contains("User: How are you?"), "First user message with role prefix")
        XCTAssertTrue(plaintext.contains("Assistant: I'm fine."), "First assistant reply with role prefix")
        XCTAssertTrue(plaintext.contains("User: See you later"), "Second user message with role prefix")
        XCTAssertTrue(plaintext.contains("Assistant: Goodbye!"), "Second assistant reply with role prefix")

        // No markdown formatting leaked
        XCTAssertFalse(plaintext.contains("**User:**"), "Plaintext should not contain markdown bold")
        XCTAssertFalse(plaintext.contains("# "), "Plaintext should not contain markdown headers")
    }

    // MARK: - Session title in export

    func test_export_sessionTitle_appearsInBothFormats() async throws {
        let backend = makeMockBackend(tokens: ["Noted."])
        let vm = await makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm, title: "Important Discussion")

        vm.inputText = "Remember this"
        await vm.sendMessage()

        let markdown = ChatExportService.export(
            messages: vm.messages,
            sessionTitle: "Important Discussion",
            format: .markdown
        )
        let plaintext = ChatExportService.export(
            messages: vm.messages,
            sessionTitle: "Important Discussion",
            format: .plainText
        )

        XCTAssertTrue(markdown.contains("# Important Discussion"),
                      "Markdown export should include session title as H1")
        XCTAssertTrue(plaintext.contains("Chat: Important Discussion"),
                      "Plaintext export should include session title in header")
    }

    // MARK: - Empty conversation export

    func test_emptyConversation_exportsHeaderOnly() async throws {
        let backend = makeMockBackend(tokens: [])
        let vm = await makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm, title: "Empty Session")

        // No messages sent
        let markdown = ChatExportService.export(
            messages: vm.messages,
            sessionTitle: "Empty Session",
            format: .markdown
        )
        let plaintext = ChatExportService.export(
            messages: vm.messages,
            sessionTitle: "Empty Session",
            format: .plainText
        )

        // Headers present
        XCTAssertTrue(markdown.contains("# Empty Session"))
        XCTAssertTrue(plaintext.contains("Chat: Empty Session"))

        // No role labels
        XCTAssertFalse(markdown.contains("**User:**"), "Empty export should have no user labels")
        XCTAssertFalse(markdown.contains("**Assistant:**"), "Empty export should have no assistant labels")
        XCTAssertFalse(plaintext.contains("User:"), "Empty plaintext should have no user labels")
        XCTAssertFalse(plaintext.contains("Assistant:"), "Empty plaintext should have no assistant labels")
    }
}
