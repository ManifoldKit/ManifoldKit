import Testing
import SwiftData
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

/// E2E test for loop detection → auto-stop.
///
/// Feeds repeating tokens through a real ChatViewModel pipeline and verifies
/// that RepetitionDetector fires, stops generation early, and preserves
/// partial content.
@Suite("Loop Detection E2E")
@MainActor
struct LoopDetectionE2ETests {

    private let container: ModelContainer
    private let context: ModelContext

    init() throws {
        container = try makeInMemoryContainer()
        context = container.mainContext
    }

    // MARK: - Helpers

    private func makeVM(backend: MockInferenceBackend) async throws -> ChatViewModel {
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "Mock")
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)

        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
        let session = try await sessionManager.createSession(title: "Test")
        sessionManager.activeSession = session
        await vm.switchToSession(session)

        return vm
    }

    // MARK: - Loop detection stops generation early

    @Test func repetitiveTokens_detectedAndStopped() async throws {
        let mock = MockInferenceBackend()
        let repeatedChunk = "The world ended now. "
        let totalChunks = 200
        mock.tokensToYield = Array(repeating: repeatedChunk, count: totalChunks)
        let vm = try await makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        // Generation should have completed (not stuck).
        #expect(!vm.isGenerating)

        // Loop detector should have fired — error message mentions repetition.
        #expect(vm.errorMessage != nil, "Loop detection should set an error message")
        #expect(
            vm.errorMessage?.contains("repeating") == true,
            "Error should mention repetition, got: \(vm.errorMessage ?? "nil")"
        )

        // Assistant message should exist with partial content.
        let assistant = try #require(
            vm.messages.first(where: { $0.role == .assistant }),
            "Partial assistant message should be preserved"
        )
        #expect(
            !assistant.content.isEmpty,
            "Assistant message should have non-empty partial content"
        )

        // Fewer tokens than the full 200 chunks should have been accumulated.
        let fullLength = repeatedChunk.count * totalChunks
        #expect(
            assistant.content.count < fullLength,
            "Content length \(assistant.content.count) should be less than full \(fullLength)"
        )
    }

    // MARK: - Loop detection disabled yields all tokens

    @Test func repetitiveTokens_allYielded_whenDetectionDisabled() async throws {
        let mock = MockInferenceBackend()
        let repeatedChunk = "The world ended now. "
        let totalChunks = 200
        mock.tokensToYield = Array(repeating: repeatedChunk, count: totalChunks)
        let vm = try await makeVM(backend: mock)
        vm.loopDetectionEnabled = false

        vm.inputText = "Hello"
        await vm.sendMessage()

        #expect(!vm.isGenerating)

        let assistant = try #require(vm.messages.first(where: { $0.role == .assistant }))

        let expectedFull = String(repeating: repeatedChunk, count: totalChunks)
        #expect(
            assistant.content == expectedFull,
            "All tokens should be accumulated when loop detection is off"
        )
        #expect(vm.errorMessage == nil, "No error should be set when loop detection is disabled")
    }

    // MARK: - Partial content persists across session reload

    @Test func loopStop_partialContent_survivesSessionReload() async throws {
        let mock = MockInferenceBackend()
        let repeatedChunk = "The world ended now. "
        mock.tokensToYield = Array(repeating: repeatedChunk, count: 200)
        let vm = try await makeVM(backend: mock)
        let session = try #require(vm.activeSession)

        vm.inputText = "Hello"
        await vm.sendMessage()

        let assistant = try #require(vm.messages.first(where: { $0.role == .assistant }))
        let partialContent = assistant.content

        // Reload the session to verify persistence round-trip.
        await vm.switchToSession(session)

        let reloaded = try #require(
            vm.messages.first(where: { $0.role == .assistant }),
            "Assistant message should survive session reload"
        )
        #expect(
            reloaded.content == partialContent,
            "Reloaded content should match partial content from loop stop"
        )
    }
}
