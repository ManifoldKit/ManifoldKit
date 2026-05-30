@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class ConversationRuntimeTurnPreparationTests: XCTestCase {
    struct Payload: Sendable, Equatable {
        let id: UUID
    }

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

    actor RecordingHook: GenerationHook {
        private var turns: [CompletedTurn] = []

        func postGeneration(_ turn: CompletedTurn) async {
            turns.append(turn)
        }

        func snapshot() -> [CompletedTurn] {
            turns
        }
    }

    actor RecordingHistoryProvider: HistoryProvider {
        private var payloads: [Payload?] = []

        func contribute(
            history: [ChatMessageRecord],
            context: TurnContext
        ) async throws -> [HistoryContribution] {
            payloads.append(context.appData as? Payload)
            return []
        }

        func snapshot() -> [Payload?] {
            payloads
        }
    }

    actor RecordingBudgetAwareProvider: PromptContextProvider {
        private var usedLegacy = false
        private var usedBudgetAware = false
        private var payloads: [Payload?] = []

        func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
            usedLegacy = true
            return []
        }

        func contributeSlots(
            budget: ProviderBudget,
            context: TurnContext
        ) async throws -> [PromptSlot] {
            usedBudgetAware = true
            payloads.append(context.appData as? Payload)
            return []
        }

        func snapshot() -> (usedLegacy: Bool, usedBudgetAware: Bool, payloads: [Payload?]) {
            (usedLegacy, usedBudgetAware, payloads)
        }
    }

    actor RecordingHostTurnContextProvider: HostTurnContextProvider {
        private let payload: Payload
        private var requests: [TurnContextBuildRequest] = []

        init(payload: Payload) {
            self.payload = payload
        }

        func appData(for request: TurnContextBuildRequest) async throws -> (any Sendable)? {
            requests.append(request)
            return payload
        }

        func snapshot() -> [TurnContextBuildRequest] {
            requests
        }
    }

    actor ThrowingHostTurnContextProvider: HostTurnContextProvider {
        enum TestError: Error {
            case failed
        }

        func appData(for request: TurnContextBuildRequest) async throws -> (any Sendable)? {
            throw TestError.failed
        }
    }

    struct FilteringHistoryShaper: HistoryShaper {
        let blockedMessageID: UUID

        func shape(
            history: [ChatMessageRecord],
            request: HistoryShapingRequest
        ) async throws -> HistoryShapingResult {
            let shaped = history.filter { $0.id != blockedMessageID }
            return HistoryShapingResult(
                promptHistory: shaped,
                diagnostics: [
                    HistoryShapingDiagnostic(
                        messageID: blockedMessageID,
                        kind: .removed,
                        reason: "filtered for prompt visibility"
                    )
                ]
            )
        }
    }

    actor EventRecorder {
        private var historyShapedEvent: ConversationEvent?
        private var continuations: [CheckedContinuation<ConversationEvent, Never>] = []

        func record(_ event: ConversationEvent) {
            guard case .historyShaped = event else { return }
            historyShapedEvent = event
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume(returning: event)
            }
        }

        func awaitHistoryShapedEvent() async -> ConversationEvent {
            if let historyShapedEvent {
                return historyShapedEvent
            }
            return await withCheckedContinuation { continuations.append($0) }
        }
    }

    private func makeRuntime(
        store: InMemoryMessageStore? = nil,
        mock: MockInferenceBackend? = nil,
        pipeline: PromptContextPipeline? = nil,
        generationHooks: [any GenerationHook] = [],
        historyShaper: (any HistoryShaper)? = nil,
        historyProviders: [any HistoryProvider] = [],
        hostTurnContextProvider: (any HostTurnContextProvider)? = nil
    ) -> (runtime: ConversationRuntime, store: InMemoryMessageStore, mock: MockInferenceBackend) {
        let backend = mock ?? MockInferenceBackend()
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let messageStore = store ?? InMemoryMessageStore()
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            inferenceService: inference,
            pipeline: pipeline,
            generationHooks: generationHooks,
            compressionPolicy: nil,
            historyShaper: historyShaper,
            historyProviders: historyProviders,
            hostTurnContextProvider: hostTurnContextProvider
        )
        return (runtime, messageStore, backend)
    }

    private enum TestError: Error {
        case timeout
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration = .seconds(5),
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TestError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func test_hostTurnContextProvider_sharesSingleAppDataAcrossHistoryPipelineAndHook() async throws {
        let payload = Payload(id: UUID())
        let hostProvider = RecordingHostTurnContextProvider(payload: payload)
        let historyProvider = RecordingHistoryProvider()
        let promptProvider = RecordingBudgetAwareProvider()
        let hook = RecordingHook()
        let (runtime, _, _) = makeRuntime(
            pipeline: PromptContextPipeline(providers: [promptProvider]),
            generationHooks: [hook],
            historyProviders: [historyProvider],
            hostTurnContextProvider: hostProvider
        )

        let sessionID = UUID()
        let maybeHandle = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        let handle = try XCTUnwrap(maybeHandle)
        let outcome = await handle.outcome
        XCTAssertNil(outcome.error)

        let requests = await hostProvider.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sessionID, sessionID)
        XCTAssertEqual(requests.first?.messageCount, 1)
        XCTAssertEqual(requests.first?.userInput, "Hi")
        XCTAssertEqual(requests.first?.conversationText, "hi")
        XCTAssertNil(requests.first?.tokenizer)
        guard case let .send(text, attachments)? = requests.first?.turnKind else {
            return XCTFail("Expected send turn metadata")
        }
        XCTAssertEqual(text, "Hi")
        XCTAssertTrue(attachments.isEmpty)

        let historyPayloads = await historyProvider.snapshot()
        XCTAssertEqual(historyPayloads, [payload])

        let promptSnapshot = await promptProvider.snapshot()
        XCTAssertFalse(promptSnapshot.usedLegacy)
        XCTAssertTrue(promptSnapshot.usedBudgetAware)
        XCTAssertEqual(promptSnapshot.payloads, [payload])

        let deliveredTurns = await hook.snapshot()
        XCTAssertEqual(deliveredTurns.count, 1)
        XCTAssertEqual(deliveredTurns.first?.appData as? Payload, payload)
    }

    func test_hostTurnContextProvider_failure_surfacesAsContextAssemblyFailure() async throws {
        let provider = ThrowingHostTurnContextProvider()
        let (runtime, _, _) = makeRuntime(hostTurnContextProvider: provider)

        let maybeHandle = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "Hello", attachments: []),
            config: TurnConfig()
        ))
        let handle = try XCTUnwrap(maybeHandle)
        let outcome = await handle.outcome

        guard case let .contextAssembly(error)? = outcome.error else {
            return XCTFail("Expected context assembly failure, got \(String(describing: outcome.error))")
        }
        XCTAssertTrue(error is ThrowingHostTurnContextProvider.TestError)
        XCTAssertNil(outcome.assistantMessage)
    }

    func test_historyShaper_shapesPromptHistoryWithoutMutatingPersistence_onRegenerate() async throws {
        let store = InMemoryMessageStore()
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["new answer"]

        let sessionID = UUID()
        let base = Date()
        let keep = ChatMessageRecord(role: .user, content: "keep", timestamp: base, sessionID: sessionID)
        let blocked = ChatMessageRecord(
            role: .assistant,
            content: "blocked",
            timestamp: base.addingTimeInterval(1),
            sessionID: sessionID
        )
        let question = ChatMessageRecord(
            role: .user,
            content: "question",
            timestamp: base.addingTimeInterval(2),
            sessionID: sessionID
        )
        let oldAnswer = ChatMessageRecord(
            role: .assistant,
            content: "old answer",
            timestamp: base.addingTimeInterval(3),
            sessionID: sessionID
        )
        try await store.insertMessage(keep)
        try await store.insertMessage(blocked)
        try await store.insertMessage(question)
        try await store.insertMessage(oldAnswer)

        let (runtime, _, backend) = makeRuntime(
            store: store,
            mock: mock,
            historyShaper: FilteringHistoryShaper(blockedMessageID: blocked.id)
        )
        let recorder = EventRecorder()
        let drainTask = Task {
            for await event in runtime.events {
                await recorder.record(event)
            }
        }
        defer { drainTask.cancel() }

        let maybeHandle = try await runtime.processTurnWithOutcome(TurnInput(
            sessionID: sessionID,
            kind: .regenerate,
            config: TurnConfig()
        ))
        let handle = try XCTUnwrap(maybeHandle)
        let outcome = await handle.outcome
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.assistantMessage?.content, "new answer")

        let historyShapedEvent = try await withTimeout {
            await recorder.awaitHistoryShapedEvent()
        }
        guard case let .historyShaped(eventSessionID, diagnostics) = historyShapedEvent else {
            return XCTFail("Expected historyShaped event")
        }
        XCTAssertEqual(eventSessionID, sessionID)
        XCTAssertEqual(
            diagnostics,
            [HistoryShapingDiagnostic(
                messageID: blocked.id,
                kind: .removed,
                reason: "filtered for prompt visibility"
            )]
        )

        XCTAssertEqual(
            backend.lastReceivedStructuredHistory?.map(\.textContent),
            ["keep", "question"]
        )

        let persisted = try await store.fetchMessages(for: sessionID)
        XCTAssertTrue(persisted.contains(where: { $0.id == blocked.id }))
        XCTAssertFalse(persisted.contains(where: { $0.id == oldAnswer.id }))
        XCTAssertTrue(persisted.contains(where: { $0.content == "new answer" }))
    }
}
