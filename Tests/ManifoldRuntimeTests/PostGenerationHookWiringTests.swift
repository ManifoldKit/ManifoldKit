@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Liveness proof for the B.2 unified hook seam: verifies
/// ``ConversationTurnExecutor`` actually fires ``HookEvent/postGeneration``
/// on the ``HookRegistry`` for real turns driven through
/// ``ConversationRuntime/processTurn(_:)`` — a hook event nothing emits is
/// dead code (AGENTS.md principle 10).
///
/// Mirrors the shape of `PreCompactWiringTests` (the same registry-wiring
/// pattern for `.preCompact`) and `GenerationHookTests` (the `CompletedTurn`
/// call-not-called contract for cancel / empty-response paths).
@MainActor
final class PostGenerationHookWiringTests: XCTestCase {

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

    // MARK: - Recorder

    /// Collects every `.postGeneration` `HookInput` delivered. Tests await
    /// the runtime's `.hookFired` event (a cancellation-safe stream) rather
    /// than a bare continuation here — the executor emits `.hookFired` only
    /// AFTER `HookRegistry.run` returns, so once the event is observed the
    /// recorder is guaranteed populated. (A `withCheckedContinuation`-based
    /// awaitNext deadlocks the deadline task group when the hook never fires,
    /// e.g. under sabotage — continuations aren't cancellation-responsive.)
    actor PostGenerationRecorder {
        private(set) var received: [HookInput] = []
        func record(_ input: HookInput) { received.append(input) }
    }

    enum TestError: Error { case deadlineElapsed }

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
        return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
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
    }

    /// Drains `runtime.events` until `predicate` matches (inclusive), bounded
    /// by `deadline`. Mirrors `PreCompactWiringTests.drainUntilEvent`.
    private func drainUntilEvent(
        _ predicate: @escaping @Sendable (ConversationEvent) -> Bool,
        from runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        let task = Task {
            var collected: [ConversationEvent] = []
            for await event in runtime.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
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
    }

    // MARK: - Test 1: fires exactly once, with the right payload

    func test_postGeneration_firesOnRealTurn_withCompletedTurnPayload() async throws {
        let recorder = PostGenerationRecorder()
        let registry = HookRegistry()
        await registry.register(.postGeneration) { input in
            await recorder.record(input)
            return .passthrough
        }

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " world"]
        mock.isModelLoaded = true
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            hookRegistry: registry
        )
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        // `.hookFired("postGeneration")` is emitted after the registry chain
        // returns, so observing it guarantees the recorder is populated.
        _ = try await drainUntilEvent({
            if case .hookFired(let name, _) = $0 { return name == "postGeneration" }
            return false
        }, from: runtime)

        let received = await recorder.received
        XCTAssertEqual(received.count, 1, "postGeneration hook must fire exactly once per successful turn")
        let delivered = try XCTUnwrap(received.first)
        XCTAssertEqual(delivered.event, .postGeneration)
        XCTAssertEqual(delivered.sessionID, sessionID)
        let turn = try XCTUnwrap(delivered.completedTurn, "postGeneration input must carry a CompletedTurn payload")
        XCTAssertEqual(turn.sessionID, sessionID)
        XCTAssertEqual(turn.assistantMessage.role, .assistant)
        XCTAssertEqual(turn.assistantMessage.content, "Hello world")
        // Sabotage-evidence (verified locally on 2026-07-14 by disabling the
        // registry callsite in ConversationTurnExecutor):
        // M1: skip the `turnHookRegistry.run(input)` block → no hookFired event; drainUntilEvent throws TestError.deadlineElapsed; test fails.
        // M2: register the recorder on `.preCompact` instead of `.postGeneration` → recorder stays empty; count assertion fails.
        // M3: pass `completedTurn: nil` in the HookInput construction → XCTUnwrap fails.
    }

    // MARK: - Test 2: not fired on cancel or empty response

    func test_postGeneration_notFiredWhenTurnIsCancelled() async throws {
        let recorder = PostGenerationRecorder()
        let registry = HookRegistry()
        await registry.register(.postGeneration) { input in
            await recorder.record(input)
            return .passthrough
        }

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["slow"]
        mock.isModelLoaded = true
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            hookRegistry: registry
        )
        let sessionID = UUID()

        let handle = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))!
        await runtime.cancel(handle)
        _ = try await collectUntilStreamFinished(from: runtime)
        try await Task.sleep(for: .milliseconds(200))

        let received = await recorder.received
        XCTAssertEqual(received.count, 0, "postGeneration must not fire when the turn is cancelled")
    }

    func test_postGeneration_notFiredOnEmptyResponse() async throws {
        let recorder = PostGenerationRecorder()
        let registry = HookRegistry()
        await registry.register(.postGeneration) { input in
            await recorder.record(input)
            return .passthrough
        }

        let mock = MockInferenceBackend()
        mock.tokensToYield = []
        mock.isModelLoaded = true
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            hookRegistry: registry
        )
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await collectUntilStreamFinished(from: runtime)
        try await Task.sleep(for: .milliseconds(200))

        let received = await recorder.received
        XCTAssertEqual(received.count, 0, "postGeneration must not fire on an empty-response turn")
    }

    // MARK: - Test 3: emits the hookFired telemetry event

    func test_postGeneration_emitsHookFiredEvent() async throws {
        let registry = HookRegistry()
        await registry.register(.postGeneration) { _ in .passthrough }

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        mock.isModelLoaded = true
        let inference = InferenceService(backend: mock, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            hookRegistry: registry
        )
        let sessionID = UUID()

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        // postGeneration fires (and emits hookFired) after streamFinished, so
        // drain until the hookFired event itself rather than streamFinished.
        let events = try await drainUntilEvent({
            if case .hookFired(let name, _) = $0 { return name == "postGeneration" }
            return false
        }, from: runtime)

        let fires = events.filter {
            if case .hookFired(let name, _) = $0 { return name == "postGeneration" }
            return false
        }
        XCTAssertEqual(fires.count, 1, "Exactly one postGeneration hookFired event must be emitted")
        // Sabotage-evidence:
        // M1: remove the `emit(.hookFired(event: "postGeneration", ...))` line in ConversationTurnExecutor → drainUntilEvent times out; test fails on TestError.deadlineElapsed.
        // M2: emit with `event: "preCompact"` instead → same timeout failure.
    }

    // MARK: - Test 4: SummarisationHook.makeHookHandler() driven through a real turn

    /// A summariser that returns a fixed string. Mirrors
    /// `SummarisationHookTests.RecordingDialogueSummariser`, duplicated here
    /// (not shared) so this file's fixtures stay independent per convention.
    actor FixedDialogueSummariser: DialogueSummariser {
        let fixedResponse = "NONCE-SUMMARY-B2: folded via registry handler."
        func summarise(turns: [ChatMessage], using backend: any InferenceBackend) async throws -> String {
            fixedResponse
        }
    }

    /// Wraps `MockInferenceBackend` and injects a `.usage` event so the
    /// runtime reports `promptTokens`, which `SummarisationHook` needs to
    /// evaluate its threshold. Mirrors `SummarisationHookTests.UsageReportingBackend`.
    final class UsageReportingBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
        let inner: MockInferenceBackend
        let reportedPromptTokens: Int
        init(inner: MockInferenceBackend, reportedPromptTokens: Int = 900) {
            self.inner = inner
            self.reportedPromptTokens = reportedPromptTokens
        }
        var lastUsage: (promptTokens: Int, completionTokens: Int)? { (reportedPromptTokens, 10) }
        var isModelLoaded: Bool {
            get { inner.isModelLoaded }
            set { inner.isModelLoaded = newValue }
        }
        var isGenerating: Bool { inner.isGenerating }
        var capabilities: BackendCapabilities { inner.capabilities }
        func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
            try await inner.loadModel(from: url, plan: plan)
        }
        func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
            let innerStream = try inner.generate(prompt: prompt, systemPrompt: systemPrompt, config: config)
            let promptTokens = reportedPromptTokens
            return GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { continuation in
                Task {
                    do {
                        for try await event in innerStream.events {
                            continuation.yield(event)
                        }
                        continuation.yield(.usage(TokenUsage(promptTokens: promptTokens, completionTokens: 10)))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            })
        }
        func stopGeneration() { inner.stopGeneration() }
        func unloadModel() { inner.unloadModel() }
    }

    private func waitForMemoryRecord(
        in store: RuntimeMessageStore,
        sessionID: UUID,
        deadline: Duration = .seconds(5)
    ) async throws {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            let messages = try await store.fetchMessages(for: sessionID)
            if messages.contains(where: { if case .memory = $0.kind { return true }; return false }) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError.deadlineElapsed
    }

    func test_summarisationHook_asRegistryHandler_firesThroughRealTurn() async throws {
        let store = RuntimeMessageStore()
        let summariser = FixedDialogueSummariser()
        let mockInner = MockInferenceBackend()
        mockInner.isModelLoaded = true
        mockInner.tokensToYield = ["Reply"]
        // context size = 1000, prompt tokens = 900 → 90% → exceeds 80% threshold
        let backend = UsageReportingBackend(inner: mockInner, reportedPromptTokens: 900)
        let sessionID = UUID()

        let hook = SummarisationHook(
            messageStore: store,
            backend: backend,
            summariser: summariser,
            policy: ThresholdSummarisationPolicy(utilizationThreshold: 0.8),
            recentTurnsToPreserve: 2,
            contextSizeProvider: { 1000 }
        )

        // The only difference from SummarisationHookTests: this hook is
        // registered on the unified HookRegistry via `makeHookHandler()`
        // instead of ConversationRuntime's separate `generationHooks` array.
        let registry = HookRegistry()
        await registry.register(.postGeneration, handler: hook.makeHookHandler())

        let inference = InferenceService(backend: backend, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            hookRegistry: registry
        )

        // Insert 6 chat turns by hand so there's enough history to fold.
        for i in 1...6 {
            let role: MessageRole = i.isMultiple(of: 2) ? .assistant : .user
            let offset = Double(i) * 0.1
            let msg = ChatMessage(
                role: role,
                content: "Turn \(i) content",
                timestamp: Date(timeIntervalSince1970: offset),
                sessionID: sessionID
            )
            try await store.insertMessage(msg)
        }

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Turn 7", attachments: []),
            config: TurnConfig()
        ))
        _ = try await collectUntilStreamFinished(from: runtime)
        try await waitForMemoryRecord(in: store, sessionID: sessionID)

        let remaining = try await store.fetchMessages(for: sessionID)
        let memoryMessages = remaining.filter {
            if case .memory = $0.kind { return true }
            return false
        }
        XCTAssertEqual(memoryMessages.count, 1, "exactly one .memory record should exist after folding via the registry handler")
        let summaryContent = try XCTUnwrap(memoryMessages.first?.content)
        XCTAssertEqual(summaryContent, summariser.fixedResponse, "summary record must contain the summariser's output")
        // Sabotage-evidence:
        // M1: register the handler on `.preToolUse` instead of `.postGeneration` → SummarisationHook never invoked; waitForMemoryRecord times out; test fails.
        // M2: have `makeHookHandler()` return `.passthrough` without calling `self.postGeneration(turn)` → same timeout failure.
    }
}
