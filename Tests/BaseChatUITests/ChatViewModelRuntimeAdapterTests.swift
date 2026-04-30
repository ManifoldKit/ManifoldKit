@preconcurrency import XCTest
import Foundation
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

// MARK: - Phase 1.2.5 PR-D: ChatViewModel ↔ ConversationRuntime adapter tests
//
// These tests verify the three new behaviours introduced by the adapter layer:
//
//  1. `test_sendMessage_withRuntime_delegatesToRuntime` — when a runtime is
//     configured, `sendMessage()` routes through it and the event drain maps
//     ConversationEvent back to `messages`.
//
//  2. `test_stopGeneration_withRuntime_cancelsHandle` — `stopGeneration()` on
//     the runtime path calls `runtime.cancel(handle)` which drives the stream
//     to a `cancelled` finish reason via the drain task.
//
//  3. `test_sendMessage_withoutRuntime_usesExistingPath` — no runtime
//     configured; the existing GenerationCoordinator path runs unchanged.

@MainActor
final class ChatViewModelRuntimeAdapterTests: XCTestCase {

    // MARK: - In-memory stores (copied shape from ConversationRuntimeTests)

    /// Minimal in-memory MessageStore used by the runtime in these tests.
    final class RuntimeMessageStore: MessageStore, @unchecked Sendable {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
            for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
        }
        func updateMessage(_ message: ChatMessageRecord) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
            for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
        }
        func deleteMessage(_ messageID: UUID) async throws {
            guard messages.removeValue(forKey: messageID) != nil else {
                throw ChatPersistenceError.messageNotFound(messageID)
            }
        }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
            hooks.append(hook)
        }
    }

    // MARK: - Helpers

    private var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for h in harnesses { h.cleanup() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    /// Builds a `ChatViewModel` backed by a `MockInferenceBackend` (model pre-loaded).
    private func makeVM(mock: MockInferenceBackend) throws -> ChatViewModel {
        let h = try makeTestChatViewModel(
            mock: mock,
            activateSession: true
        )
        harnesses.append(h)
        return h.vm
    }

    /// Builds a `ConversationRuntime` wired to `mock` and a fresh in-memory store.
    private func makeRuntime(
        mock: MockInferenceBackend,
        store: RuntimeMessageStore = RuntimeMessageStore()
    ) -> ConversationRuntime {
        let inference = InferenceService(backend: mock, name: "Mock")
        mock.isModelLoaded = true
        return ConversationRuntime(
            messageStore: store,
            inferenceService: inference
        )
    }

    // MARK: - Test 1: sendMessage with runtime delegates and drains events to messages

    func test_sendMessage_withRuntime_delegatesToRuntime() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", " from", " runtime"]

        let vm = try makeVM(mock: mock)
        let store = RuntimeMessageStore()
        let runtime = makeRuntime(mock: mock, store: store)

        // Wire the runtime to the view model.
        vm.configure(conversationRuntime: runtime)

        guard let sessionID = vm.activeSessionID else {
            XCTFail("activeSession must be set")
            return
        }

        // Launch sendMessage on a Task so we can interleave await points.
        // The runtime path returns immediately after kicking off the detached
        // generation task, so we cannot simply `await sendMessage()` and then
        // check results — we must wait for the drain to finish.
        vm.inputText = "Hello runtime"
        let sendTask = Task { @MainActor in
            await vm.sendMessage()
        }

        // Wait for the stream to start (streamStarted event drives .waitingForFirstToken).
        await vm.awaitGenerating(true)
        // Wait for the stream to finish (streamFinished event drives .idle).
        await vm.awaitGenerating(false)
        await sendTask.value

        // The runtime's event drain should have inserted both the user message
        // and the assistant message into vm.messages.
        let userMessages = vm.messages.filter { $0.role == .user }
        let assistantMessages = vm.messages.filter { $0.role == .assistant }

        XCTAssertEqual(userMessages.count, 1, "Should have one user message from runtime send")
        XCTAssertEqual(userMessages.first?.content, "Hello runtime", "User message content must match input")

        // The runtime persists the assistant message and emits .messageInserted.
        XCTAssertEqual(assistantMessages.count, 1, "Should have one assistant message from runtime drain")
        XCTAssertEqual(
            assistantMessages.first?.content, "Hello from runtime",
            "Assistant content should be the concatenated token stream"
        )

        // The runtime should have persisted both messages to the store.
        let stored = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(stored.count, 2, "Runtime store should hold user + assistant messages")
        XCTAssertTrue(stored.contains(where: { $0.role == .assistant && $0.content == "Hello from runtime" }),
                      "Persisted assistant message should contain streamed tokens")
    }

    // Sabotage check: if configure(conversationRuntime:) were never called, the runtime
    // path would not run. This is validated by test 3 below.

    // MARK: - Test 2: stopGeneration with runtime cancels the in-flight handle

    func test_stopGeneration_withRuntime_cancelsHandle() async throws {
        let slowBackend = SlowMockBackend()
        slowBackend.tokensToYield = (0..<20).map { "tok\($0) " }
        slowBackend.delayPerToken = .milliseconds(30)

        let suiteName = "BaseChatKitTests-RuntimeAdapter-Cancel-\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to allocate UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let modelsDir = makeIsolatedModelsDirectory()
        defer { try? FileManager.default.removeItem(at: modelsDir) }

        let inference = InferenceService(backend: slowBackend, name: "SlowMock")
        let vm = ChatViewModel(
            inferenceService: inference,
            modelStorage: ModelStorageService(baseDirectory: modelsDir),
            memoryPressure: MemoryPressureHandler(),
            userDefaults: testDefaults
        )
        vm.activeSession = ChatSessionRecord(title: "Cancel Test")

        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference
        )

        vm.configure(conversationRuntime: runtime)

        vm.inputText = "Tell me something slow"
        let sendTask = Task { @MainActor in
            await vm.sendMessage()
        }

        // Wait until the stream is flowing (streamStarted drives .waitingForFirstToken).
        await vm.awaitGenerating(true)
        // Give at least one token time to land so partial content exists.
        try? await Task.sleep(for: .milliseconds(80))

        // Cancel via stopGeneration — runtime path must be chosen.
        vm.stopGeneration()

        await sendTask.value

        // Wait for the drain task to process the cancelled stream's terminal events.
        await vm.awaitGenerating(false)

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stopGeneration")

        // The runtime path does not produce error UI for user-initiated cancellation.
        XCTAssertNil(vm.errorMessage, "No error message should be surfaced for user-initiated cancel")

        // At most user + partial assistant (the user message is inserted by the runtime
        // before the stream task fires; the partial assistant arrives on cancel if
        // any tokens landed).
        XCTAssertLessThanOrEqual(vm.messages.count, 2, "Should have at most user + partial assistant")
    }

    // MARK: - Test 3: sendMessage without runtime uses GenerationCoordinator (existing path)

    func test_sendMessage_withoutRuntime_usesExistingPath() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["GenerationCoordinator", " path"]

        let vm = try makeVM(mock: mock)

        // No configure(conversationRuntime:) call — runtime stays nil.
        XCTAssertNil(vm.conversationRuntime, "Precondition: no runtime configured")

        vm.inputText = "Hello from coordinator path"
        await vm.sendMessage()

        // GenerationCoordinator path: messages are built locally and streamed in.
        let userMessages = vm.messages.filter { $0.role == .user }
        let assistantMessages = vm.messages.filter { $0.role == .assistant }

        XCTAssertEqual(userMessages.count, 1, "Should have one user message")
        XCTAssertEqual(userMessages.first?.content, "Hello from coordinator path")
        XCTAssertEqual(assistantMessages.count, 1, "Should have one assistant message")
        XCTAssertEqual(
            assistantMessages.first?.content, "GenerationCoordinator path",
            "Assistant content should match mock tokens (coordinator path)"
        )
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after completion")
    }
}

