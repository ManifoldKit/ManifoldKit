@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Coverage for ``GenerationHook`` — post-generation turn callbacks registered
/// on ``ConversationRuntime``.
///
/// Uses the same in-memory store and mock backend shapes as
/// `ConversationRuntimeTests` so both fixtures stay independent.
@MainActor
final class GenerationHookTests: XCTestCase {

    // MARK: - In-memory MessageStore

    @MainActor
    final class RuntimeMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
            for hook in hooks {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func updateMessage(_ message: ChatMessageRecord) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
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

    // MARK: - Hook implementations for tests

    /// Hook that records every completed turn it receives.
    actor RecordingHook: GenerationHook {
        private(set) var receivedTurns: [CompletedTurn] = []

        func postGeneration(_ turn: CompletedTurn) async {
            receivedTurns.append(turn)
        }
    }

    /// Hook that blocks indefinitely — used to verify timeout behaviour.
    struct HangingHook: GenerationHook {
        func postGeneration(_ turn: CompletedTurn) async {
            // Sleep for a very long time; the runtime's timeout will cancel this task.
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        mock: MockInferenceBackend? = nil,
        generationHooks: [any GenerationHook] = [],
        hookTimeout: Duration = .seconds(30)
    ) -> (runtime: ConversationRuntime, store: RuntimeMessageStore, mock: MockInferenceBackend) {
        let backend = mock ?? MockInferenceBackend()
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: generationHooks
        )
        return (runtime, store, backend)
    }

    private func collectUntilAfterGeneration(
        from runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        var collected: [ConversationEvent] = []
        let task = Task {
            for await event in runtime.events {
                collected.append(event)
                if case .afterGeneration = event { break }
            }
            return collected
        }
        let result = try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw TestError.deadlineElapsed
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
        return result
    }

    private func collectUntilStreamFinished(
        from runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        var collected: [ConversationEvent] = []
        let task = Task {
            for await event in runtime.events {
                collected.append(event)
                if case .streamFinished = event { break }
            }
            return collected
        }
        let result = try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw TestError.deadlineElapsed
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
        return result
    }

    enum TestError: Error { case deadlineElapsed }

    // MARK: - Test 1: hook fires on success

    func test_hook_firesAfterSuccessfulTurn() async throws {
        let hook = RecordingHook()
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " world"]

        let (runtime, _, _) = makeRuntime(mock: mock, generationHooks: [hook])
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await collectUntilAfterGeneration(from: runtime)

        // Give the hook time to run (it fires after afterGeneration is emitted).
        try await Task.sleep(for: .milliseconds(200))

        let turns = await hook.receivedTurns
        XCTAssertEqual(turns.count, 1, "Hook should fire exactly once per successful turn")
        XCTAssertEqual(turns[0].sessionID, sessionID)
        XCTAssertEqual(turns[0].assistantMessage.role, .assistant)
        XCTAssertEqual(turns[0].assistantMessage.content, "Hello world")
    }

    // MARK: - Test 2: hook not called on cancel

    func test_hook_notCalledWhenTurnIsCancelled() async throws {
        let hook = RecordingHook()
        let mock = MockInferenceBackend()
        // Slow stream so we have time to cancel mid-turn.
        mock.tokensToYield = ["slow"]

        let (runtime, _, _) = makeRuntime(mock: mock, generationHooks: [hook])
        let sessionID = UUID()

        let handle = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))!

        // Cancel immediately.
        await runtime.cancel(handle)

        _ = try await collectUntilStreamFinished(from: runtime)

        // Brief wait to confirm hook doesn't fire.
        try await Task.sleep(for: .milliseconds(200))

        let turns = await hook.receivedTurns
        XCTAssertEqual(turns.count, 0, "Hook must not fire when turn is cancelled")
    }

    // MARK: - Test 3: hook not called on empty response

    func test_hook_notCalledOnEmptyResponse() async throws {
        let hook = RecordingHook()
        let mock = MockInferenceBackend()
        // Zero tokens yields an empty response — runtime drops the turn.
        mock.tokensToYield = []
        mock.isModelLoaded = true

        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: [hook]
        )
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await collectUntilStreamFinished(from: runtime)
        // Brief wait to confirm hook never fires.
        try await Task.sleep(for: .milliseconds(200))

        let turns = await hook.receivedTurns
        XCTAssertEqual(turns.count, 0, "Hook must not fire when response is empty")
    }

    // MARK: - Test 4: timeout does not hang turn

    func test_hook_timeoutDoesNotHangTurn() async throws {
        let hangingHook = HangingHook()
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        mock.isModelLoaded = true

        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        // Short 1s timeout — turn should complete even though the hook never returns.
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            emptyResponseObserver: nil,
            generationHooks: [hangingHook],
            compressionPolicy: nil,
            hookTimeout: .seconds(1)
        )

        let sessionID = UUID()
        let startTime = ContinuousClock.now

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        // Drain until afterGeneration; the hook fires in the detached task after that.
        // With a 1-second hookTimeout, the turn-completing sequence should finish
        // well under 5 seconds total.
        _ = try await collectUntilAfterGeneration(from: runtime, deadline: .seconds(10))

        let elapsed = ContinuousClock.now - startTime
        // The turn should complete; total time < 5 seconds even with a 1s hook timeout.
        XCTAssertLessThan(
            Double(elapsed.components.seconds),
            5.0,
            "Turn must complete in under 5 seconds even with a hanging hook"
        )
    }

    // MARK: - Test 5: multiple hooks fire in order

    func test_multipleHooks_fireInRegistrationOrder() async throws {
        // Use an actor to collect labels safely across concurrent contexts.
        actor OrderRecorder {
            private(set) var labels: [String] = []
            func record(_ label: String) { labels.append(label) }
        }

        let recorder = OrderRecorder()

        struct LabeledHook: GenerationHook {
            let label: String
            let recorder: OrderRecorder

            func postGeneration(_ turn: CompletedTurn) async {
                await recorder.record(label)
            }
        }

        let hookA = LabeledHook(label: "A", recorder: recorder)
        let hookB = LabeledHook(label: "B", recorder: recorder)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let (runtime, _, _) = makeRuntime(mock: mock, generationHooks: [hookA, hookB])
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await collectUntilAfterGeneration(from: runtime)
        try await Task.sleep(for: .milliseconds(300))

        let labels = await recorder.labels
        XCTAssertEqual(labels, ["A", "B"], "Hooks must fire in registration order")
    }
}
