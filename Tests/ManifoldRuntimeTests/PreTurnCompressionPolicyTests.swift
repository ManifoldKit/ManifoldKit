@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport

/// Coverage for ``PreTurnCompressionPolicy`` — history compression triggered
/// by ``ConversationRuntime`` before the user message is appended on `.send`
/// turns.
@MainActor
final class PreTurnCompressionPolicyTests: XCTestCase {

    private actor CompleteHistoryCapture {
        private(set) var history: [ChatMessage]?

        func record(_ history: [ChatMessage]) {
            self.history = history
        }
    }

    /// Keeps only a replacement derived from the oldest record. This proves
    /// that a pre-turn replacement is based on the complete persisted history.
    private struct FullHistoryReplacementPolicy: PreTurnCompressionPolicy {
        let capture: CompleteHistoryCapture

        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
            true
        }

        func compressBeforeTurn(
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
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            await counter.increment()
            return [ChatMessage(
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
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
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
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            throw PolicyError()
        }
    }

    struct EmptyReturnPreCompressPolicy: PreTurnCompressionPolicy {
        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool { true }

        func compressBeforeTurn(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            return []
        }
    }

    /// Records which sessionID and insertedRecords were passed to postCompressBeforeTurn.
    actor PostCompressObserver {
        var calledWith: (sessionID: UUID, insertedRecords: [ChatMessage])?
        func record(sessionID: UUID, insertedRecords: [ChatMessage]) {
            calledWith = (sessionID, insertedRecords)
        }
    }

    struct ObservingPreCompressPolicy: PreTurnCompressionPolicy {
        let observer: PostCompressObserver
        let summaryContent: String

        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool { true }

        func compressBeforeTurn(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            return [ChatMessage(
                role: .assistant,
                content: summaryContent,
                sessionID: sessionID,
                kind: .memory("summary")
            )]
        }

        func postCompressBeforeTurn(sessionID: UUID, insertedRecords: [ChatMessage]) async {
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
        let store = InMemoryMessageStore()
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
        let store = InMemoryMessageStore()
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
        let store = InMemoryMessageStore()
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
        let store = InMemoryMessageStore()
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
        let store = InMemoryMessageStore()
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
        let store = InMemoryMessageStore()
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
        let store = InMemoryMessageStore()
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
        let store = InMemoryMessageStore()
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
        let store = InMemoryMessageStore()
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
            private var recorded: (messageCount: Int, lastPromptTokens: Int?)?
            private var waiting: CheckedContinuation<(messageCount: Int, lastPromptTokens: Int?), Never>?

            func record(messageCount: Int, lastPromptTokens: Int?) {
                let value = (messageCount: messageCount, lastPromptTokens: lastPromptTokens)
                recorded = value
                waiting?.resume(returning: value)
                waiting = nil
            }

            func waitForArgs() async -> (messageCount: Int, lastPromptTokens: Int?) {
                if let recorded { return recorded }
                return await withCheckedContinuation { waiting = $0 }
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
                history: [ChatMessage],
                sessionID: UUID,
                systemPrompt: String?,
                generate: @Sendable ([ChatMessage]) async throws -> String
            ) async throws -> [ChatMessage] { history }
        }

        let backend = makeMock(tokensToYield: ["seed reply"])
        let store = InMemoryMessageStore()
        let sessionID = UUID()
        let inference = InferenceService(backend: backend, name: "Mock")

        // Seed one exchange first to get a non-empty history (user + assistant = 2 messages).
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

        let (count, _) = try await withThrowingTaskGroup(of: (Int, Int?).self) { group in
            group.addTask { await capture.waitForArgs() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw XCTestError(.timeoutWhileWaiting)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        XCTAssertEqual(count, 2, "messageCount should reflect the 2 seeded messages (user + assistant)")
    }

    // MARK: - Coordinator threads WIRE systemPrompt (#1957)

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

    struct CapturingSystemPromptPreTurnPolicy: PreTurnCompressionPolicy {
        let capture: PromptCapture
        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool { true }
        func compressBeforeTurn(
            history: [ChatMessage],
            sessionID: UUID,
            systemPrompt: String?,
            generate: @Sendable ([ChatMessage]) async throws -> String
        ) async throws -> [ChatMessage] {
            await capture.capture(systemPrompt)
            return [ChatMessage(
                role: .assistant,
                content: "pre-turn summary",
                sessionID: sessionID,
                kind: .memory("summary")
            )]
        }
    }

    /// Pre-turn compression must receive ``TurnConfig/systemPrompt``, not a
    /// differing `ChatSession.systemPrompt`. Sabotage: session-only fetch fails.
    func test_preTurn_coordinatorThreadsTurnConfigSystemPromptOverSession() async throws {
        let capture = PromptCapture()
        let sessionOnlyPrompt = "SESSION_STORE_PROMPT_MUST_NOT_WIN"
        let turnConfigPrompt = "PRE_TURN_WIRE_PROMPT"

        let backend = makeMock(tokensToYield: ["reply"])
        let messageStore = InMemoryMessageStore()
        let sessionStore = RuntimeSessionStore()
        let sessionID = UUID()
        // Seed one prior turn so pre-turn has history to compress against.
        try await messageStore.insertMessage(ChatMessage(
            role: .user, content: "prior", sessionID: sessionID
        ))
        try await messageStore.insertMessage(ChatMessage(
            role: .assistant, content: "prior reply", sessionID: sessionID, promptTokens: 100
        ))
        try await sessionStore.insertSession(ChatSession(
            id: sessionID,
            title: "pre-turn wire systemPrompt",
            systemPrompt: sessionOnlyPrompt
        ))

        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            preTurnCompressionPolicy: CapturingSystemPromptPreTurnPolicy(capture: capture)
        )

        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi"),
            config: TurnConfig(systemPrompt: turnConfigPrompt)
        ))
        _ = try await drainUntilStreamFinished(from: runtime)

        let received = await capture.received
        XCTAssertNotNil(received, "compressBeforeTurn must be invoked so the systemPrompt argument is observable")
        XCTAssertEqual(
            received!,
            turnConfigPrompt,
            "Pre-turn compress must receive TurnConfig.systemPrompt, not ChatSession.systemPrompt (sabotage: session-only fetch)"
        )
        XCTAssertNotEqual(received!, sessionOnlyPrompt)
    }

    /// Pre-turn multi-agent path: active agent's system prompt (not TurnConfig,
    /// not the session field) is what the generation path will put on the wire.
    func test_preTurn_coordinatorThreadsActiveAgentSystemPrompt() async throws {
        let capture = PromptCapture()
        let agentPrompt = "ACTIVE_AGENT_WIRE_PROMPT"
        let turnConfigPrompt = "TURN_CONFIG_MUST_NOT_WIN_WHEN_AGENT_ACTIVE"
        let sessionFieldPrompt = "SESSION_FIELD_MUST_NOT_WIN"

        let backend = makeMock(tokensToYield: ["reply"])
        let messageStore = InMemoryMessageStore()
        let sessionStore = RuntimeSessionStore()
        let sessionID = UUID()
        try await messageStore.insertMessage(ChatMessage(
            role: .user, content: "prior", sessionID: sessionID
        ))
        try await messageStore.insertMessage(ChatMessage(
            role: .assistant, content: "prior reply", sessionID: sessionID, promptTokens: 100
        ))

        let agent = AgentDefinition(name: "Researcher", systemPrompt: agentPrompt, description: "research")
        let session = ChatSession(
            id: sessionID,
            title: "pre-turn agent wire prompt",
            systemPrompt: sessionFieldPrompt,
            agents: [agent],
            activeAgentID: agent.id
        )
        try await sessionStore.insertSession(session)

        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: InferenceService(backend: backend, name: "Mock"),
            preTurnCompressionPolicy: CapturingSystemPromptPreTurnPolicy(capture: capture)
        )

        try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hi"),
            config: TurnConfig(systemPrompt: turnConfigPrompt)
        ))
        _ = try await drainUntilStreamFinished(from: runtime)

        let received = await capture.received
        XCTAssertNotNil(received, "compressBeforeTurn must be invoked")
        let prompt = try XCTUnwrap(received!)
        XCTAssertTrue(
            prompt.contains(agentPrompt),
            "Pre-turn must budget against active agent system prompt; got: \(prompt)"
        )
        XCTAssertFalse(prompt.contains(turnConfigPrompt), "Active agent must win over TurnConfig")
        XCTAssertFalse(prompt.contains(sessionFieldPrompt), "Active agent must win over session field")
    }

    /// Integration regression for the pre-turn fetch → policy → replace path.
    /// A 10,000-row whole-history cap would omit the oldest record before this
    /// policy ran, then delete that omitted history during replacement.
    func test_preTurnCompression_replacesCompleteHistoryBeyondTenThousandRecords() async throws {
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
        let coordinator = TurnCompressionCoordinator(
            persistence: ConversationPersistencePort(messageStore: stack.provider, sessionStore: nil),
            inferenceService: InferenceService(),
            events: TurnEventEmitter { _ in },
            preTurnPolicy: FullHistoryReplacementPolicy(capture: capture),
            postTurnPolicy: nil
        )

        try await coordinator.compressBeforeTurnIfNeeded(sessionID: sessionID)

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
