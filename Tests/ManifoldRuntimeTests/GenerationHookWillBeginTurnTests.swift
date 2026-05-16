@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration tests for the ``GenerationHook/willBeginTurn(sessionID:)`` pre-turn hook.
///
/// These tests verify ordering guarantees: `willBeginTurn` fires at the very start
/// of a turn (before history fetch / context assembly), and always before
/// `postGeneration(_:)` when a turn completes.
@MainActor
final class GenerationHookWillBeginTurnTests: XCTestCase {

    // MARK: - In-memory MessageStore (shared with GenerationHookTests shape)

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

    // MARK: - Recording hook that tracks both willBeginTurn and postGeneration

    /// Tracks the order in which `willBeginTurn` and `postGeneration` fire.
    /// Uses an actor so it is safe to call from the detached task context.
    actor OrderedCallRecordingHook: GenerationHook {
        enum Call: Equatable {
            case willBeginTurn(UUID)
            case postGeneration(UUID)
        }

        private(set) var calls: [Call] = []
        private var willBeginContinuations: [CheckedContinuation<UUID, Never>] = []
        private var postGenContinuations: [CheckedContinuation<CompletedTurn, Never>] = []

        func willBeginTurn(sessionID: UUID) async {
            calls.append(.willBeginTurn(sessionID))
            for continuation in willBeginContinuations {
                continuation.resume(returning: sessionID)
            }
            willBeginContinuations.removeAll()
        }

        func postGeneration(_ turn: CompletedTurn) async {
            calls.append(.postGeneration(turn.sessionID))
            for continuation in postGenContinuations {
                continuation.resume(returning: turn)
            }
            postGenContinuations.removeAll()
        }

        func awaitNextWillBeginTurn() async -> UUID {
            await withCheckedContinuation { willBeginContinuations.append($0) }
        }

        func awaitNextPostGeneration() async -> CompletedTurn {
            await withCheckedContinuation { postGenContinuations.append($0) }
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        mock: MockInferenceBackend? = nil,
        hooks: [any GenerationHook] = []
    ) -> (runtime: ConversationRuntime, store: RuntimeMessageStore, mock: MockInferenceBackend) {
        let backend = mock ?? MockInferenceBackend()
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: hooks
        )
        return (runtime, store, backend)
    }

    enum TestError: Error { case deadlineElapsed }

    private func withDeadline<T: Sendable>(
        _ deadline: Duration = .seconds(5),
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw TestError.deadlineElapsed
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
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
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        return result
    }

    // MARK: - Test 1: willBeginTurn fires before postGeneration on a successful turn

    func test_willBeginTurn_firesBeforePostGeneration() async throws {
        let hook = OrderedCallRecordingHook()
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " world"]

        let (runtime, _, _) = makeRuntime(mock: mock, hooks: [hook])
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        // Await postGeneration — implies willBeginTurn already fired before it.
        _ = try await withDeadline { await hook.awaitNextPostGeneration() }

        let calls = await hook.calls
        XCTAssertEqual(calls.count, 2, "Both willBeginTurn and postGeneration must fire")
        XCTAssertEqual(calls[0], .willBeginTurn(sessionID), "willBeginTurn must fire first")
        XCTAssertEqual(calls[1], .postGeneration(sessionID), "postGeneration must fire second")
    }

    // MARK: - Test 2: willBeginTurn sessionID matches the turn's sessionID

    func test_willBeginTurn_sessionIDMatchesTurn() async throws {
        let hook = OrderedCallRecordingHook()
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]

        let (runtime, _, _) = makeRuntime(mock: mock, hooks: [hook])
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        let receivedSessionID = try await withDeadline { await hook.awaitNextWillBeginTurn() }

        XCTAssertEqual(receivedSessionID, sessionID, "willBeginTurn must receive the correct sessionID")
    }

    // MARK: - Test 3: willBeginTurn fires even when postGeneration would not (regenerate flow)

    func test_willBeginTurn_firesOnRegenerateFlow() async throws {
        let hook = OrderedCallRecordingHook()
        let mock = MockInferenceBackend()
        // First turn yields content; second (regenerate) also yields content.
        mock.tokensToYield = ["first response"]

        let (runtime, _, _) = makeRuntime(mock: mock, hooks: [hook])
        let sessionID = UUID()

        // First turn — send.
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await collectUntilAfterGeneration(from: runtime)

        // Reset mock for the regenerate turn.
        mock.tokensToYield = ["regenerated response"]

        // Second turn — regenerate.
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .regenerate,
            config: TurnConfig()
        ))

        // Wait for the second willBeginTurn to arrive — it fires at the start
        // of the regenerate flow's detached task, before history fetch.
        let callsBefore = await hook.calls
        let priorWillBeginCount = callsBefore.filter {
            if case .willBeginTurn = $0 { return true }
            return false
        }.count

        // Wait for the second willBeginTurn (regenerate flow).
        _ = try await withDeadline { await hook.awaitNextWillBeginTurn() }

        let calls = await hook.calls
        let willBeginCalls = calls.filter {
            if case .willBeginTurn(let id) = $0 { return id == sessionID }
            return false
        }
        XCTAssertGreaterThan(
            willBeginCalls.count,
            priorWillBeginCount,
            "willBeginTurn must fire again on the regenerate flow"
        )
    }

    // MARK: - Test 4: default no-op extension compiles and does not affect runtime

    func test_defaultNoOpExtension_doesNotAffectTurn() async throws {
        // A hook that only implements postGeneration — willBeginTurn uses the
        // default no-op. If the default extension is missing or non-public this
        // test won't compile.
        struct PostOnlyHook: GenerationHook {
            let onPost: @Sendable (CompletedTurn) -> Void
            func postGeneration(_ turn: CompletedTurn) async {
                onPost(turn)
            }
            // willBeginTurn intentionally omitted — uses default no-op.
        }

        actor Recorder {
            private(set) var receivedTurns: [CompletedTurn] = []
            func record(_ turn: CompletedTurn) { receivedTurns.append(turn) }
        }

        let recorder = Recorder()
        let hook = PostOnlyHook { turn in
            Task { await recorder.record(turn) }
        }

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["hello"]
        let (runtime, _, _) = makeRuntime(mock: mock, hooks: [hook])
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await collectUntilAfterGeneration(from: runtime)

        // Give the async record call a moment to land.
        try await Task.sleep(for: .milliseconds(200))

        let turns = await recorder.receivedTurns
        XCTAssertEqual(turns.count, 1, "Post-only hook must still receive postGeneration after default willBeginTurn no-op")
        XCTAssertEqual(turns.first?.sessionID, sessionID)
    }
}
