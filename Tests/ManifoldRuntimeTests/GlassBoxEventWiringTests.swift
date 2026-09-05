@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport

// MARK: - File-scope helpers (kept out of the @MainActor test class so they
// can satisfy `Sendable` / actor-isolated protocol requirements honestly).

private func isHistoryCompressed(_ e: ConversationEvent) -> Bool {
    if case .historyCompressed = e { return true }; return false
}

private func isStreamFinished(_ e: ConversationEvent) -> Bool {
    if case .streamFinished = e { return true }; return false
}

/// Timeout clock for the late-result dispatch test. It yields once so the
/// handler starts, then deterministically wins the timeout race.
private struct ImmediateHookClock: Clock {
    struct Instant: InstantProtocol {
        let rawValue: Int = 0
        func advanced(by duration: Duration) -> Instant { self }
        func duration(to other: Instant) -> Duration { .zero }
        static func < (lhs: Instant, rhs: Instant) -> Bool { false }
        static func == (lhs: Instant, rhs: Instant) -> Bool { true }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await Task.yield()
    }
}

/// Wraps ``MockInferenceBackend`` and appends a `.usage` event after the inner
/// stream drains so the runtime's compression gate and usage recording both
/// activate.
private final class UsageReportingBackend: InferenceBackend, @unchecked Sendable {
    let inner: MockInferenceBackend
    let promptTokens: Int
    let completionTokens: Int

    init(inner: MockInferenceBackend, promptTokens: Int = 50, completionTokens: Int = 10) {
        self.inner = inner
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

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
        let prompt = promptTokens
        let completion = completionTokens
        return GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                do {
                    for try await event in innerStream.events {
                        continuation.yield(event)
                    }
                    continuation.yield(.usage(TokenUsage(promptTokens: prompt, completionTokens: completion)))
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

/// Minimal endpoint-style backend: no network. Conforms to
/// ``EndpointBackendURLModelConfigurable`` so the Ollama load path in
/// ``ModelLifecycleCoordinator`` accepts it. Emits one token plus a `.usage`
/// event so the runtime records a `TurnUsage`.
private final class FakeEndpointBackend: InferenceBackend, EndpointBackendURLModelConfigurable, @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    let capabilities = BackendCapabilities(
        supportedParameters: [],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func configure(baseURL: URL, modelName: String) {}

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.token("hi"))
            continuation.yield(.usage(TokenUsage(promptTokens: 12, completionTokens: 3)))
            continuation.finish()
        })
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}

/// Captures every ``TurnUsage`` handed to the store. `UsageStore` is a
/// `@MainActor` port, so this fake mirrors that isolation rather than being an
/// actor.
@MainActor
private final class CapturingUsageStore: UsageStore {
    private(set) var records: [TurnUsage] = []

    func record(_ record: TurnUsage) async throws { records.append(record) }
    func summary(sinceDays: Int) async throws -> UsageSummary {
        UsageSummary(totalPromptTokens: 0, totalCompletionTokens: 0, totalCachedInputTokens: 0, totalCacheWriteTokens: 0, turnCount: 0)
    }
    func summary(forEndpoint endpointID: UUID, sinceDays: Int) async throws -> UsageSummary {
        UsageSummary(totalPromptTokens: 0, totalCompletionTokens: 0, totalCachedInputTokens: 0, totalCacheWriteTokens: 0, turnCount: 0)
    }
    func recentRecords(limit: Int) async throws -> [TurnUsage] { records }
}

/// Compression policy returning one brand-new summary record. The new record's
/// identity differs from any input, so every prior record counts as "removed".
private struct SummaryReplacingPolicy: CompressionPolicy {
    let summaryContent: String
    func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
        contextSize > 0
    }
    func compress(
        history: [ChatMessage],
        sessionID: UUID,
        systemPrompt: String?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        [ChatMessage(role: .assistant, content: summaryContent, sessionID: sessionID)]
    }
}

private struct SummaryReplacingPreTurnPolicy: PreTurnCompressionPolicy {
    let summaryContent: String
    func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool { true }
    func compressBeforeTurn(
        history: [ChatMessage],
        sessionID: UUID,
        systemPrompt: String?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        [ChatMessage(role: .assistant, content: summaryContent, sessionID: sessionID, kind: .memory("summary"))]
    }
}

private struct FixedDecisionGate: ToolApprovalGate {
    let decision: ToolApprovalDecision
    func approve(_ call: ToolCall) async -> ToolApprovalDecision { decision }
}

private final class CountingExecutor: ToolExecutor, @unchecked Sendable {
    let definition: ToolDefinition
    let requiresApproval: Bool
    private let resultContent: String
    private let countLock = NSLock()
    private var storedCallCount = 0

    var callCount: Int {
        countLock.withLock { storedCallCount }
    }

    init(name: String, resultContent: String, requiresApproval: Bool = false) {
        self.definition = ToolDefinition(name: name, description: "test \(name)", parameters: .object([:]))
        self.resultContent = resultContent
        self.requiresApproval = requiresApproval
    }

    nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        countLock.withLock { storedCallCount += 1 }
        return ToolResult(callId: "", content: resultContent, errorKind: nil)
    }
}

/// Coverage for the Glass Box event-wiring slice:
///   - `.compressionTriggered` brackets `.historyCompressed` on both the
///     pre-turn and post-turn compression paths.
///   - `.toolCallApproved` fires between `.toolCallRequested` and
///     `.toolCallCompleted` only when a call genuinely clears approval.
///   - `endpointID` is threaded into the `TurnUsage` written to the
///     `UsageStore` for endpoint-backed turns (#1207).
@MainActor
final class GlassBoxEventWiringTests: XCTestCase {

    // MARK: - In-memory MessageStore

    @MainActor
    final class InMemoryMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
            for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
        }

        func updateMessage(_ message: ChatMessage) async throws {
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

    // MARK: - Helpers

    private func makeBackend(maxContextTokens: Int32 = 1024) -> MockInferenceBackend {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: maxContextTokens,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        ))
        backend.isModelLoaded = true
        return backend
    }

    private func makeToolCapableBackend() -> MockInferenceBackend {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true
        ))
        backend.isModelLoaded = true
        return backend
    }

    /// Drains events until `predicate` matches a collected event or the
    /// deadline elapses, returning everything collected so far.
    private func drain(
        from runtime: ConversationRuntime,
        until predicate: @escaping @Sendable (ConversationEvent) -> Bool,
        deadline: Duration = .seconds(8)
    ) async -> [ConversationEvent] {
        let task = Task { @MainActor in
            var collected: [ConversationEvent] = []
            for await event in runtime.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        return await withTaskGroup(of: [ConversationEvent]?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: deadline)
                task.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    /// Polls for the first captured usage record instead of sleeping a fixed
    /// interval. Usage recording runs *after* the terminal stream event (the
    /// runtime emits `.streamFinished`/`.afterGeneration` before the
    /// `UsageStore.record` write), so draining to `.streamFinished` does not
    /// guarantee the record exists yet — a single load-bearing `Task.sleep`
    /// here is a known CI-flake source.
    private func awaitUsageRecord(
        in store: CapturingUsageStore,
        deadline: Duration = .seconds(5)
    ) async {
        let start = ContinuousClock.now
        while store.records.isEmpty {
            if ContinuousClock.now - start > deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Task A: post-turn compressionTriggered brackets historyCompressed

    func test_postTurnCompression_triggeredPrecedesHistoryCompressed() async throws {
        let backend = UsageReportingBackend(inner: makeBackend())
        backend.inner.tokensToYield = ["ok"]
        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            compressionPolicy: SummaryReplacingPolicy(summaryContent: "post-summary")
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hello", attachments: []),
            config: TurnConfig()
        ))
        let events = await drain(from: runtime, until: isHistoryCompressed)

        guard let triggeredIdx = events.firstIndex(where: {
            if case .compressionTriggered = $0 { return true }; return false
        }) else {
            return XCTFail("Expected .compressionTriggered to be emitted")
        }
        guard let compressedIdx = events.firstIndex(where: isHistoryCompressed) else {
            return XCTFail("Expected .historyCompressed to be emitted")
        }
        XCTAssertLessThan(triggeredIdx, compressedIdx, ".compressionTriggered must precede .historyCompressed")

        guard case .compressionTriggered(let removed, let reason) = events[triggeredIdx],
              case .historyCompressed(_, let inserted) = events[compressedIdx] else {
            return XCTFail("Unexpected event payload shapes")
        }
        XCTAssertEqual(reason, CompressionReason.contextWindowExceeded, "Runtime-driven compression is context-window driven")
        // The user "Hello" + assistant "ok" both predate the new summary record.
        XCTAssertEqual(removed.count, 2, "Both pre-compression records must be reported as removed")
        let insertedIDs = Set(inserted.map(\.id))
        XCTAssertTrue(removed.allSatisfy { !insertedIDs.contains($0) },
                      "Removed IDs must be disjoint from the inserted replacement set")
    }

    // MARK: - Task A: pre-turn compressionTriggered brackets historyCompressed

    func test_preTurnCompression_triggeredPrecedesHistoryCompressed() async throws {
        let backend = makeBackend()
        backend.tokensToYield = ["seed reply"]
        let store = InMemoryMessageStore()
        let sessionID = UUID()
        let inference = InferenceService(backend: backend, name: "Mock")

        // Seed a prior exchange so there is real history to drop.
        let seedRuntime = ConversationRuntime(messageStore: store, inferenceService: inference)
        _ = try await seedRuntime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "seed", attachments: []),
            config: TurnConfig()
        ))
        _ = await drain(from: seedRuntime, until: isStreamFinished)

        let seededIDs = Set(try await store.fetchMessages(for: sessionID).map(\.id))
        XCTAssertEqual(seededIDs.count, 2, "Seed turn should persist user + assistant")

        backend.tokensToYield = ["assistant reply"]
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            preTurnCompressionPolicy: SummaryReplacingPreTurnPolicy(summaryContent: "pre-summary")
        )
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "new message", attachments: []),
            config: TurnConfig()
        ))
        let events = await drain(from: runtime, until: isStreamFinished)

        guard let triggeredIdx = events.firstIndex(where: {
            if case .compressionTriggered = $0 { return true }; return false
        }) else {
            return XCTFail("Expected .compressionTriggered on the pre-turn path")
        }
        guard let compressedIdx = events.firstIndex(where: isHistoryCompressed) else {
            return XCTFail("Expected .historyCompressed on the pre-turn path")
        }
        XCTAssertLessThan(triggeredIdx, compressedIdx, ".compressionTriggered must precede .historyCompressed")

        guard case .compressionTriggered(let removed, let reason) = events[triggeredIdx] else {
            return XCTFail("Unexpected payload")
        }
        XCTAssertEqual(reason, CompressionReason.contextWindowExceeded)
        XCTAssertEqual(Set(removed), seededIDs,
                       "Removed IDs must be exactly the seeded records the pre-turn policy dropped")
    }

    // MARK: - Task B: toolCallApproved (auto-approve)

    func test_toolCallApproved_appearsBetweenRequestedAndCompleted_autoApprove() async throws {
        let backend = makeToolCapableBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "call-A", toolName: "toolA", arguments: "{}")],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let executor = CountingExecutor(name: "toolA", resultContent: "resA")
        let registry = ToolRegistry(tools: [executor])
        let inference = InferenceService(backend: backend, name: "Mock", toolRegistry: registry)
        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)

        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use the tool"),
            config: TurnConfig(
                streamingUpdateInterval: .zero,
                streamingBatchCharacterLimit: 1
            )
        ))
        let events = await drain(from: runtime, until: isStreamFinished)

        let requestedIdx = events.firstIndex { if case .toolCallRequested(let c) = $0 { return c.id == "call-A" }; return false }
        let approvedIdx = events.firstIndex { if case .toolCallApproved(let id) = $0 { return id == "call-A" }; return false }
        let completedIdx = events.firstIndex { if case .toolCallCompleted(let id, _) = $0 { return id == "call-A" }; return false }

        guard let r = requestedIdx, let a = approvedIdx, let c = completedIdx else {
            return XCTFail("Expected requested, approved, and completed events for call-A. Got: \(events.map { $0.kind })")
        }
        XCTAssertLessThan(r, a, ".toolCallApproved must follow .toolCallRequested")
        XCTAssertLessThan(a, c, ".toolCallApproved must precede .toolCallCompleted")
    }

    // MARK: - Task B: toolCallApproved (explicit gate .approved)

    func test_toolCallApproved_appearsWhenGateApproves() async throws {
        let backend = makeToolCapableBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "call-G", toolName: "gated", arguments: "{}")],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let registry = ToolRegistry(tools: [CountingExecutor(name: "gated", resultContent: "ok", requiresApproval: true)])
        let inference = InferenceService(
            backend: backend,
            name: "Mock",
            toolRegistry: registry,
            toolApprovalGate: FixedDecisionGate(decision: .approved)
        )
        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)

        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use the gated tool"),
            config: TurnConfig(
                streamingUpdateInterval: .zero,
                streamingBatchCharacterLimit: 1
            )
        ))
        let events = await drain(from: runtime, until: isStreamFinished)

        XCTAssertTrue(
            events.contains { if case .toolCallApproved(let id) = $0 { return id == "call-G" }; return false },
            ".toolCallApproved must fire when the approval gate returns .approved"
        )
    }

    // MARK: - Task B: no toolCallApproved on gate denial

    func test_toolCallApproved_absentWhenGateDenies() async throws {
        let backend = makeToolCapableBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "call-D", toolName: "gated", arguments: "{}")],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let registry = ToolRegistry(tools: [CountingExecutor(name: "gated", resultContent: "ok", requiresApproval: true)])
        let inference = InferenceService(
            backend: backend,
            name: "Mock",
            toolRegistry: registry,
            toolApprovalGate: FixedDecisionGate(decision: .denied(reason: "nope"))
        )
        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)

        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use the gated tool"),
            config: TurnConfig(
                streamingUpdateInterval: .zero,
                streamingBatchCharacterLimit: 1
            )
        ))
        let events = await drain(from: runtime, until: isStreamFinished)

        XCTAssertFalse(
            events.contains { if case .toolCallApproved = $0 { return true }; return false },
            ".toolCallApproved must NOT fire on a denied call"
        )
        // The denied call still surfaces a completion carrying the synthesized result.
        XCTAssertTrue(
            events.contains { if case .toolCallCompleted(let id, _) = $0 { return id == "call-D" }; return false },
            "A denied call must still surface .toolCallCompleted"
        )
    }

    // MARK: - Task B: no toolCallApproved when a preToolUse hook blocks

    /// A `preToolUse` hook returning `.block` short-circuits the dispatch loop
    /// before the approval gate is consulted, so no `.toolCallApproved` may fire.
    /// This locks the second non-emission path (the gate-denial test covers the
    /// other); the two together pin both early returns that precede approval.
    func test_toolCallApproved_absentWhenPreToolUseHookBlocks() async throws {
        let backend = makeToolCapableBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "call-H", toolName: "toolA", arguments: "{}")],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let executor = CountingExecutor(name: "toolA", resultContent: "resA")
        let registry = ToolRegistry(tools: [executor])
        let inference = InferenceService(backend: backend, name: "Mock", toolRegistry: registry)
        let persistence = try InMemoryPersistenceHarness.make()

        // The runtime owns the pre-tool-use hook (it re-installs its own
        // adapter over the InferenceService on every turn), so the blocking
        // hook must be registered through the runtime's HookRegistry.
        let hooks = HookRegistry()
        await hooks.register(.preToolUse) { _ in
            HookOutput(block: true, denyReason: "policy:denied")
        }
        let runtime = ConversationRuntime(
            messageStore: persistence.provider,
            inferenceService: inference,
            hookRegistry: hooks
        )

        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use the tool"),
            config: TurnConfig(
                streamingUpdateInterval: .zero,
                streamingBatchCharacterLimit: 1
            )
        ))
        let events = await drain(from: runtime, until: isStreamFinished)

        XCTAssertFalse(
            events.contains { if case .toolCallApproved = $0 { return true }; return false },
            ".toolCallApproved must NOT fire when a preToolUse hook blocks the call before approval"
        )
        XCTAssertEqual(executor.callCount, 0, "A successful block must prevent actual tool execution")
        let deniedResult = events.compactMap { event -> ToolResult? in
            if case .toolCallCompleted(let id, let result) = event, id == "call-H" { return result }
            return nil
        }.first
        XCTAssertEqual(deniedResult?.errorKind, .permissionDenied, "Blocked calls must return a typed denial rather than silently disappearing")
    }

    func test_preToolUseTimeout_ignoresLateBlock_runsFollowingHandler_andDispatchesTool() async throws {
        actor Trace {
            private var values: [String] = []
            func append(_ value: String) { values.append(value) }
            func snapshot() -> [String] { values }
        }

        let backend = makeToolCapableBackend()
        backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "call-timeout", toolName: "toolA", arguments: "{}")],
            [],
        ]
        backend.tokensToYieldPerTurn = [[], ["done"]]

        let executor = CountingExecutor(name: "toolA", resultContent: "executed")
        let toolRegistry = ToolRegistry(tools: [executor])
        let inference = InferenceService(backend: backend, name: "Mock", toolRegistry: toolRegistry)
        let trace = Trace()
        let hooks = HookRegistry(clock: ImmediateHookClock(), timeout: .milliseconds(1))
        await hooks.register(.preToolUse) { _ in
            await trace.append("entered")
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                await trace.append("cancelled")
                return HookOutput(block: true, denyReason: "late block")
            }
            return HookOutput(block: true, denyReason: "unexpected")
        }
        await hooks.register(.preToolUse) { _ in
            await trace.append("following")
            return .passthrough
        }

        let persistence = try InMemoryPersistenceHarness.make()
        let runtime = ConversationRuntime(
            messageStore: persistence.provider,
            inferenceService: inference,
            hookRegistry: hooks
        )
        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "use the tool"),
            config: TurnConfig(streamingUpdateInterval: .zero, streamingBatchCharacterLimit: 1)
        ))
        let events = await drain(from: runtime, until: isStreamFinished)

        let traceValues = await trace.snapshot()
        XCTAssertEqual(traceValues, ["entered", "cancelled", "following"])
        XCTAssertEqual(executor.callCount, 1, "Timeout-as-passthrough must dispatch the real tool after the late block is ignored")
        let completion = events.compactMap { event -> ToolResult? in
            if case .toolCallCompleted(let id, let result) = event, id == "call-timeout" { return result }
            return nil
        }.first
        XCTAssertNil(completion?.errorKind)
        XCTAssertEqual(completion?.content, "executed")
        // Sabotage-evidence: returning the late block after the handler
        // finally exits makes `callCount` zero and produces a denied result.
    }

    // MARK: - Task D: endpointID threaded into TurnUsage

    func test_endpointID_populatedInUsageRecord_forEndpointBackend() async throws {
        let service = InferenceService()
        service.registerEndpointBackendFactory { _ in FakeEndpointBackend() }

        let endpoint = APIEndpointRecord(
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "test-model"
        )
        try await service.loadEndpointBackend(from: endpoint)
        XCTAssertEqual(service.activeEndpointID, endpoint.id,
                       "InferenceService must expose the loaded endpoint's id")

        let store = InMemoryMessageStore()
        let usageStore = CapturingUsageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: service,
            usageStore: usageStore
        )

        _ = try await runtime.processTurn(TurnInput(
            sessionID: UUID(),
            kind: .send(text: "hi"),
            config: TurnConfig(
                streamingUpdateInterval: .zero,
                streamingBatchCharacterLimit: 1
            )
        ))
        _ = await drain(from: runtime, until: isStreamFinished)
        await awaitUsageRecord(in: usageStore)

        let records = usageStore.records
        XCTAssertEqual(records.count, 1, "Exactly one usage record should be written for the turn")
        XCTAssertEqual(records.first?.endpointID, endpoint.id,
                       "TurnUsage.endpointID must carry the active endpoint id (#1207)")
    }

    // MARK: - Task D: endpointID is nil for on-disk (local) backends

    func test_endpointID_nilForLocalBackend() async throws {
        let backend = UsageReportingBackend(inner: makeBackend(maxContextTokens: 4096))
        backend.inner.tokensToYield = ["ok"]
        let store = InMemoryMessageStore()
        let usageStore = CapturingUsageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            usageStore: usageStore
        )

        _ = try await runtime.processTurn(TurnInput(sessionID: UUID(), kind: .send(text: "hi")))
        _ = await drain(from: runtime, until: isStreamFinished)
        await awaitUsageRecord(in: usageStore)

        let records = usageStore.records
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.endpointID,
                     "On-disk backends have no endpoint record, so endpointID stays nil")
    }
}
