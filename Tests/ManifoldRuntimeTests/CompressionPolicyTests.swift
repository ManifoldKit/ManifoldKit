@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport

/// Coverage for ``CompressionPolicy`` — history compression triggered by
/// ``ConversationRuntime`` after successful generation turns.
@MainActor
final class CompressionPolicyTests: XCTestCase {

    private actor CompleteHistoryCapture {
        private(set) var history: [ChatMessage]?

        func record(_ history: [ChatMessage]) {
            self.history = history
        }
    }

    /// Keeps only a replacement derived from the oldest record. This makes a
    /// truncated fetch observable both at policy input and after replacement.
    private struct FullHistoryReplacementPolicy: CompressionPolicy {
        let capture: CompleteHistoryCapture

        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            true
        }

        func compress(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            await capture.record(history)
            let oldestID = history.first?.id.uuidString ?? "missing-oldest"
            return [ChatMessage(
                role: .assistant,
                content: "summary-retaining-oldest-\(oldestID)",
                sessionID: sessionID,
                kind: .memory("summary")
            )]
        }
    }

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

    // MARK: - Backend that reports token usage

    /// Wraps MockInferenceBackend and adds a per-turn token-usage emission.
    /// Compression requires non-nil `usage?.promptTokens`, which the standard
    /// MockInferenceBackend doesn't provide; this shim injects `.usage` events
    /// into the stream so the runtime's token-usage tracking activates.
    ///
    /// `lastUsage` is a computed constant — no state is mutated after init, so
    /// the `@unchecked Sendable` marker is sound (inner is itself @unchecked Sendable
    /// and there is no additional mutable state on this type).
    final class UsageReportingBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
        let inner: MockInferenceBackend

        init(inner: MockInferenceBackend) {
            self.inner = inner
        }

        // TokenUsageProvider — the runtime reads this as a fallback when no
        // in-stream usage event arrived. The injected .usage events below take
        // precedence via `tokenUsage` in the stream consumer, so this value
        // is only a safety net.
        var lastUsage: (promptTokens: Int, completionTokens: Int)? {
            (50, 10)
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
            // Inject a usage event after all content tokens so the runtime's
            // in-stream usage tracking fires (which the compression gate relies on).
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

    // MARK: - Call counter (actor for Sendable safety)

    actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // MARK: - Policy implementations for tests

    /// Policy that always returns `true` from `shouldCompress`.
    struct AlwaysCompressPolicy: CompressionPolicy {
        let summaryContent: String
        let counter: CallCounter

        init(summaryContent: String = "Summary") {
            self.summaryContent = summaryContent
            self.counter = CallCounter()
        }

        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            guard contextSize > 0 else { return false }
            return true
        }

        func compress(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            await counter.increment()
            return [ChatMessage(role: .assistant, content: summaryContent, sessionID: sessionID)]
        }
    }

    /// Policy that always returns `false` from `shouldCompress`.
    struct NeverCompressPolicy: CompressionPolicy {
        let counter: CallCounter

        init() {
            self.counter = CallCounter()
        }

        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            false
        }

        func compress(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            await counter.increment()
            return history
        }
    }

    /// Policy that throws from `compress`.
    struct FailingCompressPolicy: CompressionPolicy {
        struct CompressionError: Error {}

        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            contextSize > 0
        }

        func compress(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            throw CompressionError()
        }
    }

    /// Policy that returns an empty array from `compress` — simulates a policy
    /// that mistakenly returns nothing. The runtime must not delete all messages.
    struct EmptyReturnCompressPolicy: CompressionPolicy {
        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            contextSize > 0
        }

        func compress(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            return []  // Intentionally returns nothing — should be treated as an error.
        }
    }

    // MARK: - Helpers

    private func makeMockWithUsage(
        tokensToYield: [String] = ["ok"],
        contextTokens: Int32 = 1024
    ) -> UsageReportingBackend {
        let inner = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: contextTokens,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        ))
        inner.tokensToYield = tokensToYield
        inner.isModelLoaded = true
        return UsageReportingBackend(inner: inner)
    }

    private func drainUntilStreamFinished(
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

    private func drainUntilHistoryCompressed(
        from runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        var collected: [ConversationEvent] = []
        let task = Task {
            for await event in runtime.events {
                collected.append(event)
                if case .historyCompressed = event { break }
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

    // MARK: - Test 1: policy called when threshold met

    func test_policy_compressCalledWhenShouldCompressReturnsTrue() async throws {
        // UsageReportingBackend always emits 50 prompt tokens; contextSize=1024.
        // AlwaysCompressPolicy.shouldCompress returns true for any contextSize > 0.
        let backend = makeMockWithUsage(tokensToYield: ["ok"])
        // The compression generate() call also hits the backend — seed a second response.
        backend.inner.tokensToYieldPerTurn = [["ok"], ["summary text"]]

        let policy = AlwaysCompressPolicy(summaryContent: "summary text")
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        // Wait for historyCompressed to confirm compression ran.
        let events = try await drainUntilHistoryCompressed(from: runtime)
        let compressed = events.contains { if case .historyCompressed = $0 { return true }; return false }

        let callCount = await policy.counter.count
        XCTAssertEqual(callCount, 1, "compress() should be called when shouldCompress returns true")
        XCTAssertTrue(compressed, "historyCompressed event should be emitted")
    }

    // MARK: - Test 2: policy not called when threshold not met

    func test_policy_compressNotCalledWhenShouldCompressReturnsFalse() async throws {
        let backend = makeMockWithUsage()
        let policy = NeverCompressPolicy()
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)
        // Brief wait to confirm compress() never fires.
        try await Task.sleep(for: .milliseconds(200))

        let callCount = await policy.counter.count
        XCTAssertEqual(callCount, 0, "compress() must not be called when shouldCompress returns false")
    }

    // MARK: - Test 3: compressed messages replace store

    func test_policy_compressedMessagesReplaceStore() async throws {
        let summaryContent = "The summary"
        let backend = makeMockWithUsage(tokensToYield: ["ok"])
        // Second generate() call (from policy's generate closure) returns the summary.
        backend.inner.tokensToYieldPerTurn = [["ok"], [summaryContent]]

        let policy = AlwaysCompressPolicy(summaryContent: summaryContent)
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilHistoryCompressed(from: runtime)
        // Allow time for post-compression persistence.
        try await Task.sleep(for: .milliseconds(300))

        let remaining = try await store.fetchMessages(for: sessionID)
        // After compression: only the summary message should remain.
        XCTAssertEqual(remaining.count, 1, "Store should contain only the compressed summary message")
        XCTAssertEqual(remaining[0].content, summaryContent)
    }

    // MARK: - Test 4: compression failure does not abort turn

    func test_policy_compressionFailureDoesNotAbortTurn() async throws {
        let backend = makeMockWithUsage()
        let policy = FailingCompressPolicy()
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))

        // streamFinished must still arrive despite compression throwing.
        let events = try await drainUntilStreamFinished(from: runtime)
        let streamFinished = events.contains {
            if case .streamFinished(_, let reason) = $0, reason == .stop { return true }
            return false
        }
        XCTAssertTrue(streamFinished, "streamFinished(reason: .stop) must still emit when compression fails")

        // No historyCompressed event — compression threw before completion.
        let compressed = events.contains { if case .historyCompressed = $0 { return true }; return false }
        XCTAssertFalse(compressed, "historyCompressed must not emit when compression throws")
    }

    // MARK: - Test 5 (new): empty compress() result does not delete all messages

    func test_policy_emptyCompressResultPreservesExistingHistory() async throws {
        // If a policy returns an empty array from compress(), the runtime must
        // NOT delete all messages. The conversation history must be preserved
        // and historyCompressed must not fire.
        let backend = makeMockWithUsage(tokensToYield: ["ok"])
        let policy = EmptyReturnCompressPolicy()
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)
        // Give the compression path time to run (or not run).
        try await Task.sleep(for: .milliseconds(300))

        let remaining = try await store.fetchMessages(for: sessionID)
        // The original user + assistant messages must still be in the store.
        XCTAssertGreaterThan(
            remaining.count,
            0,
            "Empty compress() result must not wipe the store; existing history must be preserved"
        )
    }

    // MARK: - Test 7: policy skipped when contextSize is 0

    func test_policy_skippedWhenContextSizeIsZero() async throws {
        // Backend with contextWindowSize = 0.
        let inner = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: Int32(0),
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        ))
        inner.tokensToYield = ["ok"]
        inner.isModelLoaded = true
        let backend = UsageReportingBackend(inner: inner)

        let policy = AlwaysCompressPolicy(summaryContent: "never")
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)
        try await Task.sleep(for: .milliseconds(200))

        let callCount = await policy.counter.count
        XCTAssertEqual(callCount, 0, "compress() must not be called when contextSize is 0")
    }

    // MARK: - Test 8: no-op compression (same history returned) does not clear the store

    func test_policy_noOpCompressionPreservesHistory() async throws {
        // A policy that returns the full history unchanged is a valid no-op.
        // The store must be replaced with the same content — same count, same
        // contents (different record IDs because the runtime re-inserts).
        struct IdentityCompressPolicy: CompressionPolicy {
            func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
                contextSize > 0
            }

            func compress(
                history: [ChatMessage],
                sessionID: UUID,
                systemPrompt: String?,
                generate: @Sendable ([ChatMessage]) async throws -> String
            ) async throws -> [ChatMessage] {
                // Return history with fresh IDs + same sessionID so they can
                // be re-inserted (store rejects duplicates for existing IDs).
                return history.map {
                    ChatMessage(role: $0.role, content: $0.content, sessionID: $0.sessionID)
                }
            }
        }

        let backend = makeMockWithUsage(tokensToYield: ["response"])
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: IdentityCompressPolicy()
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilHistoryCompressed(from: runtime)
        try await Task.sleep(for: .milliseconds(200))

        // The store should still have the compressed history (same count as pre-
        // compression: user + assistant = 2).
        let remaining = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(remaining.count, 2, "No-op compression must preserve message count")
        XCTAssertTrue(remaining.contains { $0.role == .user }, "User message must be preserved")
        XCTAssertTrue(remaining.contains { $0.role == .assistant }, "Assistant message must be preserved")
    }

    // MARK: - Test 9: generate closure receives post-turn history

    func test_policy_generateClosureReceivesPostTurnHistory() async throws {
        // After the turn completes (user + assistant persisted), the runtime
        // fetches fresh history before calling compress(). The history passed
        // to compress() must include the just-inserted assistant message.
        actor HistoryCapture {
            private(set) var capturedHistory: [ChatMessage]?
            func capture(_ history: [ChatMessage]) { capturedHistory = history }
        }

        let capture = HistoryCapture()

        struct CapturingPolicy: CompressionPolicy {
            let capture: HistoryCapture

            func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
                contextSize > 0
            }

            func compress(
                history: [ChatMessage],
                sessionID: UUID,
                systemPrompt: String?,
                generate: @Sendable ([ChatMessage]) async throws -> String
            ) async throws -> [ChatMessage] {
                await capture.capture(history)
                // Return the same history (re-wrapped with fresh IDs).
                return history.map {
                    ChatMessage(role: $0.role, content: $0.content, sessionID: $0.sessionID)
                }
            }
        }

        let backend = makeMockWithUsage(tokensToYield: ["assistant reply"])
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: CapturingPolicy(capture: capture)
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hello there", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilHistoryCompressed(from: runtime)
        try await Task.sleep(for: .milliseconds(200))

        let history = await capture.capturedHistory
        XCTAssertNotNil(history, "compress() must receive history")
        // The history passed to compress() must include the assistant message
        // that was just generated — it is the post-turn snapshot.
        let assistantMessages = history?.filter { $0.role == .assistant } ?? []
        XCTAssertFalse(
            assistantMessages.isEmpty,
            "History passed to compress() must include the assistant message from the completed turn"
        )
        let userMessages = history?.filter { $0.role == .user } ?? []
        XCTAssertFalse(
            userMessages.isEmpty,
            "History passed to compress() must include the user message that triggered the turn"
        )
    }

    // MARK: - Test 6b: executor passes correct contextUtilization value

    func test_shouldCompress_receivesCorrectContextUtilization() async throws {
        // The executor must pass Double(promptTokens) / Double(contextSize) as
        // contextUtilization. A capturing policy records the value so we can
        // assert it matches the backend-reported token counts.
        actor UtilizationCapture {
            private(set) var received: Double?
            func record(_ value: Double) { received = value }
        }
        let capture = UtilizationCapture()

        struct CapturingUtilizationPolicy: CompressionPolicy {
            let capture: UtilizationCapture
            func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
                Task { await capture.record(contextUtilization) }
                return false
            }
            func compress(history: [ChatMessage], sessionID: UUID,
                          systemPrompt: String?,
                          generate: @Sendable ([ChatMessage]) async throws -> String) async throws -> [ChatMessage] { history }
        }

        // UsageReportingBackend emits promptTokens=50, contextSize=1024 (see makeMockWithUsage + UsageReportingBackend.lastUsage).
        let backend = makeMockWithUsage(tokensToYield: ["hi"])
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: CapturingUtilizationPolicy(capture: capture)
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "ping", attachments: []),
            config: TurnConfig()
        ))
        try await Task.sleep(for: .milliseconds(300))

        let utilization = await capture.received
        XCTAssertNotNil(utilization, "shouldCompress must be called with contextUtilization")
        if let u = utilization {
            // promptTokens=50, contextSize=1024 → 50.0/1024.0 ≈ 0.04883
            let expected = 50.0 / 1024.0
            XCTAssertEqual(u, expected, accuracy: 0.001, "contextUtilization must equal promptTokens / contextSize")
        }
    }

    // MARK: - Test 6: memory-kind round-trip through in-memory store

    func test_policy_memoryKindRoundTrips() async throws {
        // Records compressed with kind: .memory("summary") must survive a store
        // insert → fetch cycle with their kind intact.
        let store = RuntimeMessageStore()
        let sessionID = UUID()
        let summary = ChatMessage(
            role: .system,
            content: "A summary of earlier events",
            sessionID: sessionID,
            kind: .memory("summary")
        )
        try await store.insertMessage(summary)
        let fetched = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].kind, .memory("summary"))
        XCTAssertFalse(fetched[0].kind.isUserVisible, "memory kind must not be user-visible")
        XCTAssertTrue(fetched[0].kind.isWireVisible, "memory kind must be wire-visible")
    }

    // MARK: - Test 10: old messages are removed after compression

    func test_policy_oldMessagesRemovedAfterCompression() async throws {
        // After compression, the original user and assistant messages must no
        // longer exist in the store — only the compressed replacement remains.
        let summaryContent = "Compressed summary"
        let backend = makeMockWithUsage(tokensToYield: ["original response"])
        backend.inner.tokensToYieldPerTurn = [["original response"], [summaryContent]]

        let policy = AlwaysCompressPolicy(summaryContent: summaryContent)
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Original user message", attachments: []),
            config: TurnConfig()
        ))
        _ = try await drainUntilHistoryCompressed(from: runtime)
        try await Task.sleep(for: .milliseconds(300))

        let remaining = try await store.fetchMessages(for: sessionID)
        // Old user message must be gone.
        XCTAssertFalse(
            remaining.contains { $0.role == .user },
            "Original user messages must be removed after bulk-replace compression"
        )
        // Only the summary (assistant role) must remain.
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].content, summaryContent)
    }

    // MARK: - Test 11: coordinator threads WIRE systemPrompt (#1957)

    actor PromptCapture {
        private(set) var received: String??
        func capture(_ value: String?) { received = .some(value) }
    }

    final class RuntimeSessionStore: SessionStore {
        var sessions: [UUID: ChatSession] = [:]
        func insertSession(_ session: ChatSession) async throws { sessions[session.id] = session }
        func updateSession(_ session: ChatSession) async throws { sessions[session.id] = session }
        func deleteSession(_ sessionID: UUID) async throws { sessions.removeValue(forKey: sessionID) }
        func deleteAll() async throws { sessions.removeAll() }
        func fetchSessions() async throws -> [ChatSession] {
            sessions.values.sorted { $0.updatedAt > $1.updatedAt }
        }
        func addPostWriteHook(_ hook: any SessionStorePostWriteHook) {}
    }

    struct CapturingSystemPromptPolicy: CompressionPolicy {
        let capture: PromptCapture
        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            contextSize > 0
        }
        func compress(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            await capture.capture(systemPrompt)
            return [ChatMessage(role: .assistant, content: "summary", sessionID: sessionID)]
        }
    }

    /// Live wiring for #1957: post-turn compression must receive
    /// ``TurnConfig/systemPrompt`` (the wire base), NOT a differing
    /// `ChatSession.systemPrompt`. Sabotage: coordinator that only
    /// `fetchSession?.systemPrompt` fails this test.
    func test_policy_coordinatorThreadsTurnConfigSystemPromptOverSession() async throws {
        let capture = PromptCapture()
        let sessionOnlyPrompt = "SESSION_STORE_PROMPT_MUST_NOT_WIN"
        let turnConfigPrompt = "TURN_CONFIG_WIRE_PROMPT"

        let backend = makeMockWithUsage(tokensToYield: ["ok"])
        backend.inner.tokensToYieldPerTurn = [["ok"], ["summary"]]
        let messageStore = RuntimeMessageStore()
        let sessionStore = RuntimeSessionStore()
        let sessionID = UUID()
        try await sessionStore.insertSession(ChatSession(
            id: sessionID,
            title: "wire systemPrompt wiring",
            systemPrompt: sessionOnlyPrompt
        ))

        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            compressionPolicy: CapturingSystemPromptPolicy(capture: capture)
        )

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig(systemPrompt: turnConfigPrompt)
        ))
        _ = try await drainUntilHistoryCompressed(from: runtime)

        let received = await capture.received
        XCTAssertNotNil(received, "compress must be invoked so the systemPrompt argument is observable")
        XCTAssertEqual(
            received!,
            turnConfigPrompt,
            "Post-turn compress must receive TurnConfig.systemPrompt, not ChatSession.systemPrompt (sabotage: session-only fetch)"
        )
        XCTAssertNotEqual(received!, sessionOnlyPrompt)
    }

    /// Post-turn path must pass the **composed** wire prompt (base + slots),
    /// not just TurnConfig / session alone.
    func test_policy_coordinatorThreadsComposedSystemPromptWithSlots() async throws {
        let capture = PromptCapture()
        let basePrompt = "BASE_WIRE_PROMPT"
        let slotContent = "SLOT_CONTEXT_BLOCK_UNIQUE"

        struct StaticProvider: PromptContextProvider {
            let slot: PromptSlot
            func contributeSlots(messageCount: Int) async throws -> [PromptSlot] { [slot] }
        }
        let slot = PromptSlot(
            id: "wire-test-slot",
            content: slotContent,
            position: .systemPreamble,
            label: "Wire test"
        )
        let pipeline = PromptContextPipeline(providers: [StaticProvider(slot: slot)])

        let backend = makeMockWithUsage(tokensToYield: ["ok"])
        backend.inner.tokensToYieldPerTurn = [["ok"], ["summary"]]
        let messageStore = RuntimeMessageStore()
        let sessionStore = RuntimeSessionStore()
        let sessionID = UUID()
        try await sessionStore.insertSession(ChatSession(
            id: sessionID,
            title: "composed wire prompt",
            systemPrompt: "SESSION_MUST_NOT_APPEAR"
        ))

        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            pipeline: pipeline,
            compressionPolicy: CapturingSystemPromptPolicy(capture: capture)
        )

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi", attachments: []),
            config: TurnConfig(systemPrompt: basePrompt)
        ))
        _ = try await drainUntilHistoryCompressed(from: runtime)

        let received = await capture.received
        XCTAssertNotNil(received, "compress must be invoked")
        let prompt = try XCTUnwrap(received!)
        XCTAssertTrue(
            prompt.contains(basePrompt) && prompt.contains(slotContent),
            "Post-turn compress must receive composed wire prompt (base + slots); got: \(prompt)"
        )
        XCTAssertFalse(
            prompt.contains("SESSION_MUST_NOT_APPEAR"),
            "Composed wire prompt must not fall back to ChatSession.systemPrompt"
        )
    }

    /// Integration regression for the post-turn fetch → policy → replace path.
    /// A former 10,000-row whole-history cap dropped the oldest seed record
    /// before the policy saw it, then made compression permanently delete it.
    func test_postTurnCompression_replacesCompleteHistoryBeyondTenThousandRecords() async throws {
        let stack = try InMemoryPersistenceHarness.make()
        let sessionID = UUID()
        let messageCount = 10_001
        let seeded = (0..<messageCount).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "history-\(index)",
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                sessionID: sessionID
            )
        }
        let oldest = try XCTUnwrap(seeded.first)
        let newest = try XCTUnwrap(seeded.last)
        try await stack.provider.performMessageMutations(seeded.map(MessageStoreMutation.insert))

        let capture = CompleteHistoryCapture()
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 1024,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        ))
        let coordinator = TurnCompressionCoordinator(
            persistence: ConversationPersistencePort(messageStore: stack.provider, sessionStore: nil),
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            events: TurnEventEmitter { _ in },
            preTurnPolicy: nil,
            postTurnPolicy: FullHistoryReplacementPolicy(capture: capture)
        )

        await coordinator.compressAfterTurnIfNeeded(
            sessionID: sessionID,
            promptTokens: 1,
            hookRegistry: nil
        )

        let capturedHistory = await capture.history
        let history = try XCTUnwrap(capturedHistory)
        XCTAssertEqual(history.count, messageCount)
        XCTAssertEqual(history.first?.id, oldest.id, "Compression must receive the oldest persisted record")
        XCTAssertEqual(history.last?.id, newest.id, "Compression must receive the newest persisted record")
        XCTAssertEqual(history.map(\.id), seeded.map(\.id), "Policy input must be the complete chronological history")

        let replacement = try await stack.provider.fetchMessages(for: sessionID)
        XCTAssertEqual(replacement.count, 1)
        XCTAssertEqual(replacement.first?.content, "summary-retaining-oldest-\(oldest.id.uuidString)")
        XCTAssertEqual(replacement.first?.kind, .memory("summary"))
    }
}
