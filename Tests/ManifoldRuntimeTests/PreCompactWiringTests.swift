@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Verifies the W2C `preCompact` callsite in
/// ``ConversationTurnExecutor/runGenerationTurn`` fires the HookRegistry
/// before ``CompressionPolicy/compress(history:sessionID:systemPrompt:generate:)`` and
/// honours the documented v1 contract: `block: true` from a preCompact
/// hook **does not** block compression — it just logs a warning.
@MainActor
final class PreCompactWiringTests: XCTestCase {

    // MARK: - Reusable infra borrowed from CompressionPolicyTests shape

    @MainActor
    private final class RuntimeMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
            for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
        }
        func updateMessage(_ message: ChatMessage) async throws {
            guard messages[message.id] != nil else { throw ChatPersistenceError.messageNotFound(message.id) }
            messages[message.id] = message
        }
        func deleteMessage(_ messageID: UUID) async throws {
            guard messages.removeValue(forKey: messageID) != nil else { throw ChatPersistenceError.messageNotFound(messageID) }
        }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) { hooks.append(hook) }
    }

    /// Backend with non-nil promptTokens so the compression branch fires.
    /// Mirrors the shape of CompressionPolicyTests.UsageReportingBackend but
    /// kept private to this file so test classes stay independent.
    private final class UsageReportingBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
        let inner: MockInferenceBackend
        init(inner: MockInferenceBackend) { self.inner = inner }
        var lastUsage: (promptTokens: Int, completionTokens: Int)? { (50, 10) }
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
            return GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { continuation in
                Task {
                    do {
                        for try await event in innerStream.events {
                            continuation.yield(event)
                        }
                        continuation.yield(.usage(TokenUsage(promptTokens: 50, completionTokens: 10)))
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

    /// Records when `compress` ran (for ordering against hook invocations).
    private actor OrderRecorder {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func snapshot() -> [String] { events }
    }

    private struct OrderedCompressPolicy: CompressionPolicy {
        let recorder: OrderRecorder
        let summary: String
        init(recorder: OrderRecorder, summary: String = "compressed-summary") {
            self.recorder = recorder
            self.summary = summary
        }
        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            contextSize > 0
        }
        func compress(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            await recorder.record("compress")
            return [ChatMessage(role: .assistant, content: summary, sessionID: sessionID)]
        }
    }

    private func makeBackend() -> UsageReportingBackend {
        let inner = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 1024,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        ))
        inner.tokensToYield = ["ok"]
        inner.tokensToYieldPerTurn = [["ok"], ["summary"]]
        inner.isModelLoaded = true
        return UsageReportingBackend(inner: inner)
    }

    private enum TestError: Error { case deadlineElapsed }

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

    // MARK: - Tests

    func test_preCompact_firesBeforeCompression() async throws {
        let recorder = OrderRecorder()
        let policy = OrderedCompressPolicy(recorder: recorder)
        let registry = HookRegistry()
        await registry.register(.preCompact) { _ in
            await recorder.record("hook")
            return .passthrough
        }

        let backend = makeBackend()
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy,
            hookRegistry: registry
        )

        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilEvent({
            if case .historyCompressed = $0 { return true }; return false
        }, from: runtime)

        let order = await recorder.snapshot()
        XCTAssertEqual(order, ["hook", "compress"], "preCompact hook must fire BEFORE compression")
        // Sabotage-evidence:
        // M1: move the hook block AFTER `compressionPolicy.compress(...)` in ConversationTurnExecutor → order becomes ["compress","hook"]; test fails.
        // M2: skip the hookRegistry call entirely → order becomes ["compress"]; test fails on count.
        // M3: register the hook on `.preToolUse` instead of `.preCompact` → hook never fires; test fails.
    }

    func test_preCompact_blockTrue_logsWarningAndProceedsAnyway() async throws {
        // v1 contract: preCompact cannot block compression. The hook may
        // return block:true but compression still runs (warning logged).
        let recorder = OrderRecorder()
        let policy = OrderedCompressPolicy(recorder: recorder)
        let registry = HookRegistry()
        await registry.register(.preCompact) { _ in
            await recorder.record("hook-block")
            return HookOutput(block: true, denyReason: "test")
        }

        let backend = makeBackend()
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy,
            hookRegistry: registry
        )

        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilEvent({
            if case .historyCompressed = $0 { return true }; return false
        }, from: runtime)

        let order = await recorder.snapshot()
        XCTAssertEqual(
            order,
            ["hook-block", "compress"],
            "v1 contract: preCompact block:true must NOT prevent compression"
        )
        // Sabotage-evidence:
        // M1: add an `if output.block { return }` guard before compress in ConversationTurnExecutor → compress never runs; order == ["hook-block"]; test fails.
        // M2: swap the order check to compare to ["hook-block"] only → would mask the regression; intentionally NOT what we test for.
        // M3: drop the `await recorder.record("hook-block")` line in this test's hook → order becomes ["compress"]; test fails as written, confirming the recorder/order contract is load-bearing.
    }

    func test_preCompact_emitsHookFiredEvent() async throws {
        let recorder = OrderRecorder()
        let policy = OrderedCompressPolicy(recorder: recorder)
        let registry = HookRegistry()
        // Pass-through hook — the .hookFired event must still emit.
        await registry.register(.preCompact) { _ in .passthrough }

        let backend = makeBackend()
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy,
            hookRegistry: registry
        )

        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "hi", attachments: []),
            config: TurnConfig()
        ))
        let events = try await drainUntilEvent({
            if case .historyCompressed = $0 { return true }; return false
        }, from: runtime)

        let preCompactFires = events.filter {
            if case .hookFired(let name, _) = $0 { return name == "preCompact" }
            return false
        }
        XCTAssertEqual(preCompactFires.count, 1, "Exactly one preCompact hookFired event must be emitted")
        // Sabotage-evidence:
        // M1: remove the `emit(.hookFired(event: "preCompact", ...))` line in ConversationTurnExecutor → count == 0; test fails.
        // M2: emit with `event: "preToolUse"` instead → filter rejects; count == 0; test fails.
        // M3: emit twice → count == 2; test fails.
    }
}
