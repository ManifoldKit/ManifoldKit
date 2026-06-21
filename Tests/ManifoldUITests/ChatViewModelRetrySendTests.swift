@preconcurrency import XCTest
import Foundation
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI

// MARK: - ChatViewModel.retrySend tests
//
// A user message can reach `.failed` status when its send turn faults (the
// runtime calls markMostRecentUserMessageFailed). Before this change there was
// no retry affordance — the user could only edit or delete. These tests pin the
// `retrySend(_:)` re-attempt path that the inline bubble button and the
// "Retry" context-menu item both drive.

@MainActor
final class ChatViewModelRetrySendTests: XCTestCase {

    private struct RetryTestError: LocalizedError {
        var errorDescription: String? { "retry test failure" }
    }

    /// Minimal in-memory MessageStore (same shape as ChatViewModelRuntimeAdapterTests).
    private final class RuntimeMessageStore: MessageStore, @unchecked Sendable {
        private(set) var messages: [UUID: ManifoldInference.ChatMessage] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ManifoldInference.ChatMessage) async throws {
            messages[message.id] = message
            for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
        }
        func updateMessage(_ message: ManifoldInference.ChatMessage) async throws {
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
        func fetchMessages(for sessionID: UUID) async throws -> [ManifoldInference.ChatMessage] {
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

    private var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for h in harnesses { h.cleanup() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeVMWithRuntime(
        mock: MockInferenceBackend
    ) throws -> ChatViewModel {
        mock.isModelLoaded = true
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference
        )
        let modelsDir = makeIsolatedModelsDirectory()
        let suiteName = "ManifoldKitTests-RetrySend-\(UUID().uuidString)"
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
        vm.activeSession = ManifoldInference.ChatSession(title: "Retry Test")
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
        return vm
    }

    // MARK: - retrySend re-attempts a failed user message

    func test_retrySend_reattemptsFailedUserMessage() async throws {
        let mock = MockInferenceBackend()
        // First turn faults during generation, marking the user message failed.
        mock.shouldThrowOnGenerate = RetryTestError()
        let vm = try makeVMWithRuntime(mock: mock)

        vm.inputText = "please answer"
        let sendTask = Task { @MainActor in await vm.sendMessage() }
        await vm.awaitGenerating(false)
        await sendTask.value

        let failedUser = try XCTUnwrap(
            vm.messages.first(where: { $0.role == .user }),
            "Send should have produced a user message"
        )
        XCTAssertEqual(failedUser.status, .failed, "Faulted send must mark the user message failed")
        XCTAssertEqual(
            vm.messages.filter { $0.role == .assistant && $0.hasVisibleContent }.count, 0,
            "No assistant reply should exist after the failed send"
        )

        // Recover the backend so the retry can succeed, then re-attempt.
        mock.shouldThrowOnGenerate = nil
        mock.tokensToYield = ["Here", " you", " go"]

        let retryTask = Task { @MainActor in await vm.retrySend(failedUser.id) }
        await vm.awaitGenerating(false)
        await retryTask.value

        // The streamed assistant content lands via the event drain, which can
        // settle a beat after isGenerating flips false (the SSE/finish lag noted
        // in the codebase). Poll the assistant reply to non-empty rather than
        // assert synchronously.
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              (vm.messages.last(where: { $0.role == .assistant })?.content ?? "").isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        // The user message is no longer failed and an assistant reply now exists.
        let userAfter = vm.messages.first(where: { $0.role == .user })
        XCTAssertNotEqual(userAfter?.status, .failed, "Retry must clear the failed status on success")
        let assistant = vm.messages.last(where: { $0.role == .assistant })
        XCTAssertEqual(
            assistant?.content, "Here you go",
            "Retry must re-run generation and produce the assistant reply"
        )
        XCTAssertGreaterThanOrEqual(
            mock.generateCallCount, 2,
            "Retry must dispatch a second generation attempt"
        )
    }

    // MARK: - retrySend is a no-op outside the failed-user-message case

    func test_retrySend_isNoOpForNonFailedOrAssistantMessage() async throws {
        let mock = MockInferenceBackend()
        let vm = try makeVMWithRuntime(mock: mock)
        let sessionID = try XCTUnwrap(vm.activeSessionID)

        // A non-failed user message: retry should not dispatch a turn.
        let sent = ManifoldInference.ChatMessage(
            role: .user, content: "ok", sessionID: sessionID, status: .sent
        )
        await vm.handle(runtimeEvent: .messageInserted(sent))
        let countBefore = mock.generateCallCount
        await vm.retrySend(sent.id)
        XCTAssertEqual(
            mock.generateCallCount, countBefore,
            "Retry on a non-failed message must be a no-op"
        )

        // An unknown message id is also a no-op.
        await vm.retrySend(UUID())
        XCTAssertEqual(mock.generateCallCount, countBefore, "Retry on a missing id must be a no-op")
    }
}
