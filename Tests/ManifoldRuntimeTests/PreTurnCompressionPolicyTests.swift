@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Coverage for ``PreTurnCompressionPolicy`` — history compression triggered
/// by ``ConversationRuntime`` before the user message is appended on `.send`
/// turns.
@MainActor
final class PreTurnCompressionPolicyTests: XCTestCase {

    // MARK: - In-memory MessageStore (shared with CompressionPolicyTests)

    @MainActor
    final class RuntimeMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]

        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
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

        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    // MARK: - Call counter

    actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // MARK: - Policy implementations

    struct AlwaysPreCompressPolicy: PreTurnCompressionPolicy {
        let summaryContent: String
        let counter: CallCounter

        init(summaryContent: String = "PreTurnSummary") {
            self.summaryContent = summaryContent
            self.counter = CallCounter()
        }

        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
            true
        }

        func compressBeforeTurn(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            await counter.increment()
            return [ChatMessageRecord(
                role: .assistant,
                content: summaryContent,
                sessionID: sessionID,
                kind: .memory("summary")
            )]
        }
    }

    struct NeverPreCompressPolicy: PreTurnCompressionPolicy {
        let counter: CallCounter

        init() { self.counter = CallCounter() }

        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
            false
        }

        func compressBeforeTurn(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            await counter.increment()
            return history
        }
    }

    struct FailingPreCompressPolicy: PreTurnCompressionPolicy {
        struct PolicyError: Error, LocalizedError {
            var errorDescription: String? { "Simulated compress failure" }
        }

        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool { true }

        func compressBeforeTurn(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            throw PolicyError()
        }
    }

    struct EmptyReturnPreCompressPolicy: PreTurnCompressionPolicy {
        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool { true }

        func compressBeforeTurn(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            return []
        }
    }

    /// Records which sessionID and insertedRecords were passed to postCompressBeforeTurn.
    actor PostCompressObserver {
        var calledWith: (sessionID: UUID, insertedRecords: [ChatMessageRecord])?
        func record(sessionID: UUID, insertedRecords: [ChatMessageRecord]) {
            calledWith = (sessionID, insertedRecords)
        }
    }

    struct ObservingPreCompressPolicy: PreTurnCompressionPolicy {
        let observer: PostCompressObserver
        let summaryContent: String

        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool { true }

        func compressBeforeTurn(
            history: [ChatMessageRecord],
            sessionID: UUID,
            generate: @Sendable ([ChatMessageRecord]) async throws -> String
        ) async throws -> [ChatMessageRecord] {
            return [ChatMessageRecord(
                role: .assistant,
                content: summaryContent,
                sessionID: sessionID,
                kind: .memory("summary")
            )]
        }

        func postCompressBeforeTurn(sessionID: UUID, insertedRecords: [ChatMessageRecord]) async {
            await observer.record(sessionID: sessionID, insertedRecords: insertedRecords)
        }
    }

    // MARK: - Helpers

    private func makeMock(tokensToYield: [String] = ["ok"]) -> MockInferenceBackend {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 1024,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        ))
        backend.tokensToYield = tokensToYield
        backend.isModelLoaded = true
        return backend
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
        return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw XCTestError(.timeoutWhileWaiting)
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
    }

    // MARK: - Test 1: compress called when shouldCompress returns true

    func test_compressCalled_whenShouldReturnTrue() async throws {
        let backend = makeMock()
        let policy = AlwaysPreCompressPolicy()
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            preTurnCompressionPolicy: policy
        )

        let sessionID = UUID()
        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)

        let callCount = await policy.counter.count
        XCTAssertEqual(callCount, 1, "compressBeforeTurn should be called once")
    }

    // MARK: - Test 2: compress not called when shouldCompress returns false

    func test_compressNotCalled_whenShouldReturnFalse() async throws {
        let backend = makeMock()
        let policy = NeverPreCompressPolicy()
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            preTurnCompressionPolicy: policy
        )

        let sessionID = UUID()
        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)

        let callCount = await policy.counter.count
        XCTAssertEqual(callCount, 0, "compressBeforeTurn must not be called when shouldCompress returns false")
    }

    // MARK: - Test 3: user message falls outside compressed segment

    func test_userMessageOutsideCompressedSegment() async throws {
        // Seed the session with a prior exchange so there's history to compress.
        let backend = makeMock(tokensToYield: ["prior response"])
        let store = RuntimeMessageStore()
        let sessionID = UUID()
        let inference = InferenceService(backend: backend, name: "Mock")

        // First turn without compression to establish history.
        let seedRuntime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference
        )
        try await seedRuntime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "seed message"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: seedRuntime)

        // Now configure a runtime with pre-turn compression.
        backend.tokensToYield = ["assistant reply"]
        let summaryContent = "CompressedSummary"
        let policy = AlwaysPreCompressPolicy(summaryContent: summaryContent)
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            preTurnCompressionPolicy: policy
        )

        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "new user message"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)

        // Fetch the final persisted history.
        let finalMessages = try await store.fetchMessages(for: sessionID)

        // The summary record must be present.
        XCTAssertTrue(
            finalMessages.contains { $0.content == summaryContent },
            "Compressed summary must be present in history"
        )

        // The new user message must appear AFTER the summary — outside the compressed segment.
        guard let summaryIndex = finalMessages.firstIndex(where: { $0.content == summaryContent }),
              let userIndex = finalMessages.firstIndex(where: { $0.role == .user && $0.content == "new user message" }) else {
            XCTFail("Expected summary and new user message in history")
            return
        }
        XCTAssertLessThan(
            summaryIndex,
            userIndex,
            "Summary must precede the new user message (user action outside compressed segment)"
        )
    }

    // MARK: - Test 4: historyCompressed event emitted before messageInserted(user)

    func test_historyCompressedBeforeUserMessageInserted() async throws {
        let backend = makeMock()
        let policy = AlwaysPreCompressPolicy()
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            preTurnCompressionPolicy: policy
        )

        let sessionID = UUID()
        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi"),
            config: TurnConfig()
        ))
        let events = try await drainUntilStreamFinished(from: runtime)

        let compressedIdx = events.firstIndex { if case .historyCompressed = $0 { return true }; return false }
        let userInsertedIdx = events.firstIndex { event in
            if case .messageInserted(let msg) = event { return msg.role == .user }
            return false
        }

        guard let ci = compressedIdx, let ui = userInsertedIdx else {
            XCTFail("Expected both historyCompressed and user messageInserted events")
            return
        }
        XCTAssertLessThan(ci, ui, "historyCompressed must precede user messageInserted")
    }

    // MARK: - Test 5: failure throws preTurnCompressionFailed to caller

    func test_failingPolicy_throwsPreTurnCompressionFailed() async throws {
        let backend = makeMock()
        let policy = FailingPreCompressPolicy()
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            preTurnCompressionPolicy: policy
        )

        let sessionID = UUID()
        do {
            try await runtime.processTurn(TurnInput(
                sessionID: sessionID,
                kind: .send(text: "Hi"),
                config: TurnConfig()
            ))
            XCTFail("Expected preTurnCompressionFailed to be thrown")
        } catch let error as ConversationError {
            if case .preTurnCompressionFailed = error {
                // correct
            } else {
                XCTFail("Expected .preTurnCompressionFailed, got \(error)")
            }
        }
    }

    // MARK: - Test 6: failure preserves existing history

    func test_failingPolicy_preservesExistingHistory() async throws {
        // Seed two prior messages.
        let backend = makeMock(tokensToYield: ["seed reply"])
        let store = RuntimeMessageStore()
        let sessionID = UUID()
        let inference = InferenceService(backend: backend, name: "Mock")

        let seedRuntime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference
        )
        try await seedRuntime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "seed"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: seedRuntime)

        let historyBeforeFailure = try await store.fetchMessages(for: sessionID)

        // Attach a failing pre-turn policy.
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            preTurnCompressionPolicy: FailingPreCompressPolicy()
        )

        _ = try? await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "new message"),
            config: TurnConfig()
        ))

        let historyAfterFailure = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(
            historyBeforeFailure.map(\.id),
            historyAfterFailure.map(\.id),
            "Existing history must be intact when pre-turn compression fails"
        )
    }

    // MARK: - Test 7: empty-return policy throws and preserves history

    func test_emptyReturnPolicy_throwsAndPreservesHistory() async throws {
        let backend = makeMock()
        let policy = EmptyReturnPreCompressPolicy()
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            preTurnCompressionPolicy: policy
        )

        let sessionID = UUID()
        do {
            try await runtime.processTurn(TurnInput(
                sessionID: sessionID,
                kind: .send(text: "Hi"),
                config: TurnConfig()
            ))
            XCTFail("Expected preTurnCompressionFailed to be thrown")
        } catch let error as ConversationError {
            if case .preTurnCompressionFailed = error {
                // correct
            } else {
                XCTFail("Expected .preTurnCompressionFailed, got \(error)")
            }
        }

        // Nothing should be in the store — the user message was never inserted.
        let finalMessages = try await store.fetchMessages(for: sessionID)
        XCTAssertTrue(finalMessages.isEmpty, "No messages should exist when pre-turn compression fails before user insert")
    }

    // MARK: - Test 8: postCompressBeforeTurn called after compression, before user insert

    func test_postCompressBeforeTurn_calledWithInsertedRecords() async throws {
        let backend = makeMock()
        let observer = PostCompressObserver()
        let summaryContent = "PostCompressContent"
        let policy = ObservingPreCompressPolicy(observer: observer, summaryContent: summaryContent)
        let store = RuntimeMessageStore()
        let sessionID = UUID()

        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            preTurnCompressionPolicy: policy
        )

        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)

        let observed = await observer.calledWith
        XCTAssertNotNil(observed, "postCompressBeforeTurn should be called")
        XCTAssertEqual(observed?.sessionID, sessionID)
        XCTAssertEqual(
            observed?.insertedRecords.first?.content, summaryContent,
            "postCompressBeforeTurn should receive the inserted records"
        )
    }

    // MARK: - Test 9: pre-turn compression does not run for regenerate turns

    func test_preTurnCompression_notCalledOnRegenerate() async throws {
        // Seed a prior exchange so regenerate has something to work with.
        let backend = makeMock(tokensToYield: ["seed", "regen"])
        let store = RuntimeMessageStore()
        let sessionID = UUID()
        let inference = InferenceService(backend: backend, name: "Mock")

        let seedRuntime = ConversationRuntime(messageStore: store, inferenceService: inference)
        try await seedRuntime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "seed"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: seedRuntime)

        let policy = AlwaysPreCompressPolicy()
        backend.tokensToYield = ["regen reply"]
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            preTurnCompressionPolicy: policy
        )

        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .regenerate,
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)

        let callCount = await policy.counter.count
        XCTAssertEqual(callCount, 0, "compressBeforeTurn must not be called on regenerate turns")
    }

    // MARK: - Test 10: messageCount and lastPromptTokens forwarded to shouldCompress

    func test_shouldCompressReceivesCorrectArgs() async throws {
        actor ArgCapture {
            var messageCount: Int?
            var lastPromptTokens: Int??
            func record(messageCount: Int, lastPromptTokens: Int?) {
                self.messageCount = messageCount
                self.lastPromptTokens = lastPromptTokens
            }
        }

        final class CapturingPolicy: PreTurnCompressionPolicy, @unchecked Sendable {
            let capture: ArgCapture
            init(_ capture: ArgCapture) { self.capture = capture }

            func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
                Task { await self.capture.record(messageCount: messageCount, lastPromptTokens: lastPromptTokens) }
                return false
            }
            func compressBeforeTurn(
                history: [ChatMessageRecord],
                sessionID: UUID,
                generate: @Sendable ([ChatMessageRecord]) async throws -> String
            ) async throws -> [ChatMessageRecord] { history }
        }

        let backend = makeMock(tokensToYield: ["seed reply"])
        let store = RuntimeMessageStore()
        let sessionID = UUID()
        let inference = InferenceService(backend: backend, name: "Mock")

        // Seed one exchange first to get a non-empty history.
        let seedRuntime = ConversationRuntime(messageStore: store, inferenceService: inference)
        try await seedRuntime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "seed"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: seedRuntime)

        let capture = ArgCapture()
        backend.tokensToYield = ["second reply"]
        let policy = CapturingPolicy(capture)
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            preTurnCompressionPolicy: policy
        )

        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "second"),
            config: TurnConfig()
        ))
        _ = try await drainUntilStreamFinished(from: runtime)

        // Brief settle for the async Task inside shouldCompressBeforeTurn.
        try await Task.sleep(for: .milliseconds(50))

        let count = await capture.messageCount
        XCTAssertNotNil(count, "shouldCompressBeforeTurn must be called with message count")
        XCTAssertGreaterThan(count ?? 0, 0, "messageCount should reflect the seeded history")
    }
}
