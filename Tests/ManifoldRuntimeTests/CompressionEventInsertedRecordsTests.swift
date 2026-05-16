@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration tests for the `insertedRecords` payload on
/// ``ConversationEvent/historyCompressed(sessionID:insertedRecords:)`` and
/// the ``CompressionPolicy/postCompress(sessionID:insertedRecords:)`` hook.
@MainActor
final class CompressionEventInsertedRecordsTests: XCTestCase {

    // MARK: - In-memory MessageStore (reused from CompressionPolicyTests pattern)

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

    // MARK: - Usage-reporting backend (same pattern as CompressionPolicyTests)

    /// Wraps MockInferenceBackend and injects a `.usage` event so the runtime's
    /// compression gate activates (requires non-nil `promptTokens`).
    final class UsageReportingBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
        let inner: MockInferenceBackend

        init(inner: MockInferenceBackend) {
            self.inner = inner
        }

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

        func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
            let innerStream = try inner.generate(prompt: prompt, systemPrompt: systemPrompt, config: config)
            return GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { continuation in
                Task {
                    do {
                        for try await event in innerStream.events {
                            continuation.yield(event)
                        }
                        continuation.yield(.usage(prompt: 50, completion: 10))
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

    // MARK: - Actors for capturing side effects

    actor RecordCapture {
        private(set) var capturedRecords: [ChatMessageRecord]?
        private(set) var capturedSessionID: UUID?

        func record(sessionID: UUID, records: [ChatMessageRecord]) {
            capturedSessionID = sessionID
            capturedRecords = records
        }
    }

    // MARK: - Policy that captures postCompress arguments

    struct CapturingPostCompressPolicy: CompressionPolicy {
        let summaryContent: String
        let capture: RecordCapture

        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            contextSize > 0
        }

        func compress(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            [ChatMessageRecord(role: .assistant, content: summaryContent, sessionID: sessionID)]
        }

        func postCompress(sessionID: UUID, insertedRecords: [ChatMessageRecord]) async {
            await capture.record(sessionID: sessionID, records: insertedRecords)
        }
    }

    // MARK: - Helpers

    private func makeBackend(
        firstTurnTokens: [String] = ["ok"],
        contextTokens: Int32 = 1024
    ) -> UsageReportingBackend {
        let inner = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: contextTokens,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        ))
        inner.isModelLoaded = true
        inner.tokensToYieldPerTurn = [firstTurnTokens, ["summary"]]
        return UsageReportingBackend(inner: inner)
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
                throw DeadlineError()
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
        return result
    }

    struct DeadlineError: Error {}

    // MARK: - Test 1: historyCompressed event carries insertedRecords

    func test_historyCompressedEvent_carriesInsertedRecords() async throws {
        // After compression the event must carry the exact records that were
        // persisted, in the same order as compress() returned them.
        let summaryContent = "Session compressed"
        let capture = RecordCapture()
        let backend = makeBackend()
        let policy = CapturingPostCompressPolicy(summaryContent: summaryContent, capture: capture)
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hello", attachments: []),
            config: TurnConfig()
        ))

        let events = try await drainUntilHistoryCompressed(from: runtime)
        let compressedEvent = events.first {
            if case .historyCompressed = $0 { return true }
            return false
        }

        XCTAssertNotNil(compressedEvent, "historyCompressed event must be emitted")
        guard case .historyCompressed(let eventSessionID, let insertedRecords) = compressedEvent else {
            XCTFail("Expected historyCompressed event")
            return
        }

        XCTAssertEqual(eventSessionID, sessionID, "Event must carry the correct sessionID")
        XCTAssertEqual(insertedRecords.count, 1, "Event must carry the one record returned by compress()")
        XCTAssertEqual(insertedRecords[0].content, summaryContent, "insertedRecords content must match what compress() returned")
        XCTAssertEqual(insertedRecords[0].sessionID, sessionID, "insertedRecords must be scoped to the compressed session")
    }

    // MARK: - Test 2: postCompress is called with the same insertedRecords

    func test_postCompress_calledWithMatchingInsertedRecords() async throws {
        // postCompress must be called after historyCompressed is emitted,
        // with the same records that compress() returned.
        let summaryContent = "Graph-reconcile me"
        let capture = RecordCapture()
        let backend = makeBackend()
        let policy = CapturingPostCompressPolicy(summaryContent: summaryContent, capture: capture)
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hello", attachments: []),
            config: TurnConfig()
        ))

        _ = try await drainUntilHistoryCompressed(from: runtime)
        // Allow postCompress to finish — it runs after emit().
        try await Task.sleep(for: .milliseconds(300))

        let capturedRecords = await capture.capturedRecords
        let capturedSessionID = await capture.capturedSessionID

        XCTAssertNotNil(capturedRecords, "postCompress must be called after compression")
        XCTAssertEqual(capturedSessionID, sessionID, "postCompress must receive the correct sessionID")
        XCTAssertEqual(capturedRecords?.count, 1, "postCompress must receive the one record from compress()")
        XCTAssertEqual(capturedRecords?.first?.content, summaryContent, "postCompress insertedRecords must match compress() return value")
    }

    // MARK: - Test 3: default postCompress is a no-op

    func test_defaultPostCompress_isNoOp() async throws {
        // A policy that does not implement postCompress uses the default no-op.
        // Compression must still complete and emit historyCompressed.
        struct MinimalPolicy: CompressionPolicy {
            let summaryContent: String

            func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
                contextSize > 0
            }

            func compress(
                history: [ChatMessageRecord],
                sessionID: UUID,
                generate: @Sendable ([ChatMessageRecord]) async throws -> String
            ) async throws -> [ChatMessageRecord] {
                [ChatMessageRecord(role: .assistant, content: summaryContent, sessionID: sessionID)]
            }
            // postCompress not implemented — uses default no-op extension.
        }

        let backend = makeBackend()
        let policy = MinimalPolicy(summaryContent: "minimal summary")
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = InMemoryMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            compressionPolicy: policy
        )

        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hello", attachments: []),
            config: TurnConfig()
        ))

        let events = try await drainUntilHistoryCompressed(from: runtime)
        let emitted = events.contains { if case .historyCompressed = $0 { return true }; return false }
        XCTAssertTrue(emitted, "historyCompressed must be emitted even when postCompress is the default no-op")

        // The single compressed record must be in the store.
        try await Task.sleep(for: .milliseconds(200))
        let remaining = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(remaining.count, 1, "Store must contain only the compressed summary after default no-op postCompress")
        XCTAssertEqual(remaining[0].content, "minimal summary")
    }
}
