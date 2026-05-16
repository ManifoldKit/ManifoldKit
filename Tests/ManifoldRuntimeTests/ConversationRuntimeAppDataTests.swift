@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration tests for the `turnContextProvider` / `appData` payload
/// added in #1243.
///
/// Verifies that:
///  - `TurnContext.appData` is `nil` by default.
///  - A provider registered on `ConversationRuntime` surfaces its return value
///    in `CompletedTurn.appData` delivered to a `GenerationHook`.
///  - When no provider is registered, `CompletedTurn.appData` is `nil`.
///
/// Uses an in-memory `MessageStore` (no SwiftData required) and
/// `MockInferenceBackend` from `ManifoldTestSupport`.
@MainActor
final class ConversationRuntimeAppDataTests: XCTestCase {

    // MARK: - In-memory MessageStore

    @MainActor
    final class InMemoryMessageStore: MessageStore {
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

    // MARK: - Recording hook

    /// Hook that records every `CompletedTurn` it receives and signals
    /// waiters so tests can await delivery deterministically.
    actor RecordingHook: GenerationHook {
        private(set) var receivedTurns: [CompletedTurn] = []
        private var continuations: [CheckedContinuation<CompletedTurn, Never>] = []

        func postGeneration(_ turn: CompletedTurn) async {
            receivedTurns.append(turn)
            for c in continuations { c.resume(returning: turn) }
            continuations.removeAll()
        }

        func awaitNextTurn() async -> CompletedTurn {
            await withCheckedContinuation { continuations.append($0) }
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        mock: MockInferenceBackend? = nil,
        generationHooks: [any GenerationHook] = [],
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil
    ) -> (runtime: ConversationRuntime, store: InMemoryMessageStore, mock: MockInferenceBackend) {
        let backend = mock ?? MockInferenceBackend()
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: generationHooks,
            turnContextProvider: turnContextProvider
        )
        return (runtime, store, backend)
    }

    enum TestError: Error { case deadlineElapsed }

    private func awaitHookDelivery(
        hook: RecordingHook,
        deadline: Duration = .seconds(5)
    ) async throws -> CompletedTurn {
        try await withThrowingTaskGroup(of: CompletedTurn.self) { group in
            group.addTask { await hook.awaitNextTurn() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw TestError.deadlineElapsed
            }
            let turn = try await group.next()!
            group.cancelAll()
            return turn
        }
    }

    // MARK: - Test 1: TurnContext.appData is nil by default

    func test_turnContext_appData_isNilByDefault() {
        let ctx = TurnContext(
            sessionID: UUID(),
            messageCount: 0
        )
        XCTAssertNil(ctx.appData, "appData must be nil when not supplied")
    }

    // MARK: - Test 2: appData roundtrips through init

    func test_turnContext_appData_roundtrips() {
        let payload = "hello"
        let ctx = TurnContext(
            sessionID: UUID(),
            messageCount: 1,
            appData: payload
        )
        XCTAssertEqual(ctx.appData as? String, payload)
    }

    // MARK: - Test 3: CompletedTurn.appData reflects provider return value

    func test_completedTurn_appData_reflectsProvider() async throws {
        let hook = RecordingHook()
        let sessionID = UUID()
        let expectedPayload = "per-session-data"

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello"]

        let provider: @Sendable (UUID) -> (any Sendable)? = { id in
            // Return different payloads per session so the test is not trivially true.
            id == sessionID ? expectedPayload : nil
        }

        let (runtime, _, _) = makeRuntime(
            mock: mock,
            generationHooks: [hook],
            turnContextProvider: provider
        )

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        let deliveredTurn = try await awaitHookDelivery(hook: hook)

        XCTAssertEqual(
            deliveredTurn.appData as? String,
            expectedPayload,
            "CompletedTurn.appData must equal the provider's return value"
        )
    }

    // MARK: - Test 4: CompletedTurn.appData is nil when no provider is set

    func test_completedTurn_appData_isNilWithoutProvider() async throws {
        let hook = RecordingHook()

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["World"]

        // No turnContextProvider — appData should be nil.
        let (runtime, _, _) = makeRuntime(mock: mock, generationHooks: [hook])

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        let deliveredTurn = try await awaitHookDelivery(hook: hook)

        XCTAssertNil(
            deliveredTurn.appData,
            "CompletedTurn.appData must be nil when no turnContextProvider is registered"
        )
    }

    // MARK: - Test 5: provider returning nil yields nil appData

    func test_completedTurn_appData_isNilWhenProviderReturnsNil() async throws {
        let hook = RecordingHook()

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]

        // Provider always returns nil.
        let provider: @Sendable (UUID) -> (any Sendable)? = { _ in nil }

        let (runtime, _, _) = makeRuntime(
            mock: mock,
            generationHooks: [hook],
            turnContextProvider: provider
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        let deliveredTurn = try await awaitHookDelivery(hook: hook)

        XCTAssertNil(
            deliveredTurn.appData,
            "CompletedTurn.appData must be nil when the provider returns nil"
        )
    }
}
