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
        private(set) var messages: [UUID: ChatMessage] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
            for hook in hooks {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func updateMessage(_ message: ChatMessage) async throws {
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

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
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

    /// Hook that records every completed turn it receives and signals each
    /// completion so tests can await it deterministically instead of sleeping.
    actor RecordingHook: GenerationHook {
        private(set) var receivedTurns: [CompletedTurn] = []
        private var continuations: [CheckedContinuation<CompletedTurn, Never>] = []

        func postGeneration(_ turn: CompletedTurn) async {
            receivedTurns.append(turn)
            for continuation in continuations {
                continuation.resume(returning: turn)
            }
            continuations.removeAll()
        }

        /// Suspends until the next `postGeneration(_:)` call completes and
        /// returns the `CompletedTurn` that was delivered.
        func awaitNextTurn() async -> CompletedTurn {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
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

        // Await the hook's own completion signal — deterministic, no sleep needed.
        // withThrowingTaskGroup bounds the wait so a broken hook doesn't hang CI.
        let deliveredTurn = try await withThrowingTaskGroup(of: CompletedTurn.self) { group in
            group.addTask { await hook.awaitNextTurn() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TestError.deadlineElapsed
            }
            let turn = try await group.next()!
            group.cancelAll()
            return turn
        }

        let turns = await hook.receivedTurns
        XCTAssertEqual(turns.count, 1, "Hook should fire exactly once per successful turn")
        XCTAssertEqual(deliveredTurn.sessionID, sessionID)
        XCTAssertEqual(deliveredTurn.assistantMessage.role, .assistant)
        XCTAssertEqual(deliveredTurn.assistantMessage.content, "Hello world")
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
        // Actor collects labels and signals when the expected count is reached.
        actor OrderRecorder {
            private(set) var labels: [String] = []
            private var continuations: [CheckedContinuation<[String], Never>] = []
            private let expectedCount: Int

            init(expectedCount: Int) { self.expectedCount = expectedCount }

            func record(_ label: String) {
                labels.append(label)
                if labels.count >= expectedCount {
                    for c in continuations { c.resume(returning: labels) }
                    continuations.removeAll()
                }
            }

            /// Suspends until `expectedCount` labels have been recorded.
            func awaitAllLabels() async -> [String] {
                if labels.count >= expectedCount { return labels }
                return await withCheckedContinuation { continuations.append($0) }
            }
        }

        let recorder = OrderRecorder(expectedCount: 2)

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

        // Await the recorder's deterministic completion signal.
        let labels = try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask { await recorder.awaitAllLabels() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TestError.deadlineElapsed
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        XCTAssertEqual(labels, ["A", "B"], "Hooks must fire in registration order")
    }

    // MARK: - Test 6: first hook passes, second times out — turn still completes

    func test_hooks_secondTimeoutDoesNotPreventTurnCompletion() async throws {
        // hookA completes immediately; hookB hangs forever. With a short timeout
        // the runtime must cancel hookB and still complete the turn — hookA's
        // delivery and the persisted assistant message must be unaffected.
        let hookA = RecordingHook()

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        mock.isModelLoaded = true

        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            emptyResponseObserver: nil,
            generationHooks: [hookA, HangingHook()],
            compressionPolicy: nil,
            hookTimeout: .seconds(1)
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        // hookA must fire; bound the wait with a deadline.
        _ = try await withThrowingTaskGroup(of: CompletedTurn.self) { group in
            group.addTask { await hookA.awaitNextTurn() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TestError.deadlineElapsed
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let turns = await hookA.receivedTurns
        XCTAssertEqual(turns.count, 1, "hookA must still receive the turn even when hookB times out")

        // The assistant message must have been persisted before hooks ran.
        let messages = try await store.fetchMessages(for: sessionID)
        let assistantMessages = messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Assistant message must be persisted regardless of hook timeout")
    }
}
