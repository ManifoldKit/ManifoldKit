@preconcurrency import XCTest
import Foundation
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

// MARK: - ChatViewModel ↔ ConversationRuntime adapter tests
//
// Post-cutover (#947) `ConversationRuntime` is the single turn loop. These
// tests verify the @Observable state mapping that ChatViewModel performs on
// top of the runtime's event stream:
//
//  1. `test_sendMessage_delegatesToRuntime` — `sendMessage()` routes through
//     the constructor-injected runtime and the event drain maps
//     ConversationEvent values back to `messages`.
//
//  2. `test_stopGeneration_cancelsHandle` — `stopGeneration()` calls
//     `runtime.cancel(handle)` which drives the stream to a `cancelled`
//     finish reason via the drain task.

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

    /// Builds a `ChatViewModel` backed by a `MockInferenceBackend` (model pre-loaded)
    /// and a `ConversationRuntime` wired to the same backend + a fresh in-memory store.
    /// Returns the view model along with the store so tests can assert persisted state.
    private func makeVMWithRuntime(
        mock: MockInferenceBackend
    ) throws -> (vm: ChatViewModel, store: RuntimeMessageStore) {
        mock.isModelLoaded = true
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference
        )
        let modelsDir = makeIsolatedModelsDirectory()
        let suiteName = "BaseChatKitTests-RuntimeAdapter-\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            throw TestFactoryError.userDefaultsSuiteAllocationFailed(suiteName)
        }
        let vm = ChatViewModel(
            inferenceService: inference,
            modelStorage: ModelStorageService(baseDirectory: modelsDir),
            memoryPressure: MemoryPressureHandler(),
            userDefaults: testDefaults,
            conversationRuntime: runtime
        )
        vm.activeSession = ChatSessionRecord(title: "Adapter Test")
        // Track teardown via a lightweight harness wrapper.
        harnesses.append(TestChatViewModelHarness(
            vm: vm,
            mock: mock,
            container: nil,
            userDefaults: testDefaults,
            userDefaultsSuiteName: suiteName,
            ownsUserDefaults: true,
            modelsDirectory: modelsDir,
            ownsModelsDirectory: true
        ))
        return (vm, store)
    }

    // MARK: - Test 1: sendMessage delegates to runtime and drains events to messages

    func test_sendMessage_delegatesToRuntime() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " from", " runtime"]

        let (vm, store) = try makeVMWithRuntime(mock: mock)

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

    // MARK: - Test 2: stopGeneration cancels the in-flight handle

    func test_stopGeneration_cancelsHandle() async throws {
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
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference
        )
        let vm = ChatViewModel(
            inferenceService: inference,
            modelStorage: ModelStorageService(baseDirectory: modelsDir),
            memoryPressure: MemoryPressureHandler(),
            userDefaults: testDefaults,
            conversationRuntime: runtime
        )
        vm.activeSession = ChatSessionRecord(title: "Cancel Test")

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

    // MARK: - Test: the runtime drain task does not leak the view model
    //
    // Regression test for the retain cycle that existed when `[weak self]` plus
    // an outside-the-loop `guard let self else { return }` upgraded `self` to a
    // strong capture for the lifetime of the drain task. Re-checking `self` per
    // iteration keeps `self` weak across the suspended `for-await`, so the VM
    // can deallocate when nothing else holds it.
    //
    // Sabotage check (verified manually): hoisting `guard let self` outside the
    // `for-await` loop in the drain task makes `weakVM` survive past
    // `harnesses.removeAll()` and the assertion fails.

    func test_runtimeDrainTask_doesNotRetainViewModel() async throws {
        let mock = MockInferenceBackend()

        weak var weakVM: ChatViewModel?
        do {
            let (vm, _) = try makeVMWithRuntime(mock: mock)
            weakVM = vm
            XCTAssertNotNil(weakVM, "VM is alive while strongly held by harness")

            // Let the drain task actually start running and suspend on the
            // `for await` — only then does the closure's captured-`self`
            // lifetime extend across the suspension point. Without this
            // wait, the task may not have started, so the test wouldn't
            // catch the cycle either way.
            try await Task.sleep(for: .milliseconds(30))
        }

        // Drop the harness; nothing else should retain the VM externally.
        for h in harnesses { h.cleanup() }
        harnesses.removeAll()

        // Yield several times and sleep so any deferred ARC release settles.
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertNil(weakVM, "VM must be deallocated once external strong refs drop — drain task must not retain self across the for-await suspension")
    }
}

