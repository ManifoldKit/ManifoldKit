@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport

/// Coverage for ``GenerationHook`` — post-generation turn callbacks registered
/// on ``ConversationRuntime``.
///
/// Uses the same in-memory store and mock backend shapes as
/// `ConversationRuntimeTests` so both fixtures stay independent.
@MainActor
/// Integration coverage uses real SwiftData; existing lower-level cases stay in this suite.
final class GenerationHookIntegrationTests: XCTestCase {

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

    /// A controllable hook that observes the runtime's cancellation signal but
    /// deliberately remains pending until the test releases it. This models
    /// arbitrary hook code that does not cooperate by returning promptly.
    actor CancellationIgnoringHook: GenerationHook {
        private let messageStore: any MessageStore
        private var didStart = false
        private var didObserveCancellation = false
        private var didComplete = false
        private var releaseRequested = false
        private var didPersistMarker = false
        private var didFailPersistMarker = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        private var completionWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(messageStore: any MessageStore) {
            self.messageStore = messageStore
        }

        func postGeneration(_ turn: CompletedTurn) async {
            didStart = true
            let starters = startWaiters
            startWaiters.removeAll()
            for waiter in starters { waiter.resume() }

            while !Task.isCancelled && !releaseRequested {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    // The loop condition observes cancellation on the next pass.
                }
            }
            if Task.isCancelled {
                didObserveCancellation = true
                let cancellationObservers = cancellationWaiters
                cancellationWaiters.removeAll()
                for waiter in cancellationObservers { waiter.resume() }
            }

            if !releaseRequested {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            do {
                try await messageStore.insertMessage(ChatMessage(
                    role: .assistant,
                    content: "hook marker",
                    sessionID: turn.sessionID
                ))
                didPersistMarker = true
            } catch {
                didFailPersistMarker = true
            }
            didComplete = true
            let completions = completionWaiters
            completionWaiters.removeAll()
            for waiter in completions { waiter.resume() }
        }

        func awaitStarted() async {
            if didStart { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func awaitCancellationObserved() async {
            if didObserveCancellation { return }
            await withCheckedContinuation { cancellationWaiters.append($0) }
        }

        func awaitCompletion() async {
            if didComplete { return }
            await withCheckedContinuation { completionWaiters.append($0) }
        }

        func release() {
            releaseRequested = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        var persistedMarker: Bool { didPersistMarker }
        var failedToPersistMarker: Bool { didFailPersistMarker }
    }

    actor CancellationResponsiveHook: GenerationHook {
        private var didStart = false
        private var didObserveCancellation = false
        private var didComplete = false
        private var releaseRequested = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        private var completionWaiters: [CheckedContinuation<Void, Never>] = []

        func postGeneration(_ turn: CompletedTurn) async {
            didStart = true
            let starters = startWaiters
            startWaiters.removeAll()
            for waiter in starters { waiter.resume() }
            while !Task.isCancelled && !releaseRequested {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    // The loop condition distinguishes cancellation from release.
                }
            }
            if Task.isCancelled {
                didObserveCancellation = true
                let cancellationObservers = cancellationWaiters
                cancellationWaiters.removeAll()
                for waiter in cancellationObservers { waiter.resume() }
            }
            didComplete = true
            let completions = completionWaiters
            completionWaiters.removeAll()
            for waiter in completions { waiter.resume() }
        }

        func awaitStarted() async {
            if didStart { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func awaitCancellationObserved() async {
            if didObserveCancellation { return }
            await withCheckedContinuation { cancellationWaiters.append($0) }
        }

        func awaitCompletion() async {
            if didComplete { return }
            await withCheckedContinuation { completionWaiters.append($0) }
        }

        func release() { releaseRequested = true }
    }

    actor OutcomeRecorder {
        private var value: ConversationTurnOutcome?
        func record(_ outcome: ConversationTurnOutcome) { value = outcome }
        var isSettled: Bool { value != nil }
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

    // MARK: - Test 4: cancellation request is cooperative

    func test_hook_deadlineRequestsCancellation_butOutcomeWaitsForDirectHookAndStoreSettlement() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        mock.isModelLoaded = true

        let inference = InferenceService(backend: mock, name: "Mock")
        let persistence = try InMemoryPersistenceHarness.make()
        let hook = CancellationIgnoringHook(messageStore: persistence.provider)
        let followingHook = RecordingHook()
        let runtime = ConversationRuntime(
            messageStore: persistence.provider,
            sessionStore: persistence.provider,
            inferenceService: inference,
            emptyResponseObserver: nil,
            generationHooks: [hook, followingHook],
            compressionPolicy: nil,
            hookTimeout: .milliseconds(25)
        )

        let sessionID = UUID()
        let maybeHandle = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        let handle = try XCTUnwrap(maybeHandle)
        let outcomeRecorder = OutcomeRecorder()
        let outcomeTask = Task {
            let outcome = await handle.outcome
            await outcomeRecorder.record(outcome)
            return outcome
        }

        do {
            try await withTimeout(.seconds(5)) { await hook.awaitStarted() }
            try await withTimeout(.seconds(5)) { await hook.awaitCancellationObserved() }

            // This is the demonstrated-red boundary: changing the old test's
            // proxy (`afterGeneration`) to the awaited outcome makes its claimed
            // hard deadline fail here. The timeout only requested cancellation;
            // the direct hook remains part of the runtime settlement boundary.
            let settledBeforeRelease = await outcomeRecorder.isSettled
            XCTAssertFalse(settledBeforeRelease)
            let followingBeforeRelease = await followingHook.receivedTurns
            XCTAssertTrue(followingBeforeRelease.isEmpty)
            let outcomeSettledWhileHeld: Bool
            do {
                _ = try await withTimeout(.milliseconds(100)) { await handle.outcome }
                outcomeSettledWhileHeld = true
            } catch {
                // The awaited outcome is non-throwing; this is the external
                // test deadline proving it remains pending while held.
                outcomeSettledWhileHeld = false
            }
            XCTAssertFalse(outcomeSettledWhileHeld, "A cancellation request must not settle the outcome before the direct hook returns")
            let messageCountBeforeRelease = try await persistence.provider.fetchMessages(for: sessionID).count
            XCTAssertEqual(messageCountBeforeRelease, 2)
        } catch {
            // Release is latched, so this also cleans up a handler that has not
            // reached its continuation yet when a bounded observation fails.
            await hook.release()
            throw error
        }

        // Controlled cleanup: the test owns this intentionally noncooperative
        // hook and releases it before waiting for its externally bounded join.
        await hook.release()
        let outcome = try await withTimeout(.seconds(5)) { await outcomeTask.value }
        XCTAssertEqual(outcome.reason, .stop)
        let settledAfterRelease = await outcomeRecorder.isSettled
        XCTAssertTrue(settledAfterRelease)
        let persistedMarker = await hook.persistedMarker
        let failedToPersistMarker = await hook.failedToPersistMarker
        XCTAssertTrue(persistedMarker)
        XCTAssertFalse(failedToPersistMarker)

        let deliveredTurns = await followingHook.receivedTurns
        XCTAssertEqual(deliveredTurns.count, 1, "Following hook runs after the cancellation-responsive hook settles")
        XCTAssertEqual(deliveredTurns.first?.sessionID, sessionID)
        let messageCountAfterRelease = try await persistence.provider.fetchMessages(for: sessionID).count
        XCTAssertEqual(messageCountAfterRelease, 3)
        let messagesAfterRelease = try await persistence.provider.fetchMessages(for: sessionID)
        XCTAssertTrue(messagesAfterRelease.contains { $0.content == "hook marker" })
    }

    func test_cancellationResponsiveHook_runsFollowingHook_andSettlesOutcome() async throws {
        let responsiveHook = CancellationResponsiveHook()
        let followingHook = RecordingHook()
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        mock.isModelLoaded = true

        let inference = InferenceService(backend: mock, name: "Mock")
        let persistence = try InMemoryPersistenceHarness.make()
        let runtime = ConversationRuntime(
            messageStore: persistence.provider,
            sessionStore: persistence.provider,
            inferenceService: inference,
            emptyResponseObserver: nil,
            generationHooks: [responsiveHook, followingHook],
            hookTimeout: .milliseconds(25)
        )
        let sessionID = UUID()
        let maybeHandle = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        let handle = try XCTUnwrap(maybeHandle)

        let outcome: ConversationTurnOutcome
        do {
            try await withTimeout(.seconds(5)) { await responsiveHook.awaitStarted() }
            try await withTimeout(.seconds(5)) { await responsiveHook.awaitCancellationObserved() }
            try await withTimeout(.seconds(5)) { await responsiveHook.awaitCompletion() }
            outcome = try await withTimeout(.seconds(5)) { await handle.outcome }
        } catch {
            await responsiveHook.release()
            throw error
        }

        XCTAssertEqual(outcome.reason, .stop)
        let deliveredTurns = await followingHook.receivedTurns
        XCTAssertEqual(deliveredTurns.count, 1)
        XCTAssertEqual(deliveredTurns.first?.sessionID, sessionID)
        let messageCount = try await persistence.provider.fetchMessages(for: sessionID).count
        XCTAssertEqual(messageCount, 2)
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

}
