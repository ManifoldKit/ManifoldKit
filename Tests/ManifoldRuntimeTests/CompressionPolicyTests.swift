@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Coverage for ``CompressionPolicy`` — history compression triggered by
/// ``ConversationRuntime`` after successful generation turns.
@MainActor
final class CompressionPolicyTests: XCTestCase {

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

    // MARK: - Backend that reports token usage

    /// Wraps MockInferenceBackend and adds a per-turn token-usage emission.
    /// Compression requires non-nil `usage?.promptTokens`, which the standard
    /// MockInferenceBackend doesn't provide; this shim injects usage events.
    final class UsageReportingBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
        let inner: MockInferenceBackend
        var lastUsage: (promptTokens: Int, completionTokens: Int)?

        init(inner: MockInferenceBackend) {
            self.inner = inner
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

        func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
            let innerStream = try inner.generate(prompt: prompt, systemPrompt: systemPrompt, config: config)
            // Wrap the inner stream to inject a usage event before finishing.
            return GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
                Task {
                    do {
                        for try await event in innerStream.events {
                            continuation.yield(event)
                        }
                        // Inject usage after all content tokens.
                        let promptTokens = 50
                        let completionTokens = 10
                        continuation.yield(.usage(prompt: promptTokens, completion: completionTokens))
                        self.lastUsage = (promptTokens, completionTokens)
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

        func shouldCompress(promptTokens: Int, contextSize: Int) -> Bool {
            guard contextSize > 0 else { return false }
            return true
        }

        func compress(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            await counter.increment()
            return [ChatMessageRecord(role: .assistant, content: summaryContent, sessionID: sessionID)]
        }
    }

    /// Policy that always returns `false` from `shouldCompress`.
    struct NeverCompressPolicy: CompressionPolicy {
        let counter: CallCounter

        init() {
            self.counter = CallCounter()
        }

        func shouldCompress(promptTokens: Int, contextSize: Int) -> Bool {
            false
        }

        func compress(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            await counter.increment()
            return history
        }
    }

    /// Policy that throws from `compress`.
    struct FailingCompressPolicy: CompressionPolicy {
        struct CompressionError: Error {}

        func shouldCompress(promptTokens: Int, contextSize: Int) -> Bool {
            contextSize > 0
        }

        func compress(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            throw CompressionError()
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

    // MARK: - Test 5: policy skipped when contextSize is 0

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
}
