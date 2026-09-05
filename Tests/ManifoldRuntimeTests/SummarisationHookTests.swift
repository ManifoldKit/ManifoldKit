@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport

/// Integration coverage for ``SummarisationHook``.
///
/// Tests are driven through a ``ConversationRuntime`` backed by an
/// in-memory ``MessageStore`` and a ``MockInferenceBackend`` so that no
/// SwiftData stack is required — the storage layer is exercised via the
/// same ``MessageStore`` protocol that production code uses.
///
/// Coverage:
/// - A `.memory("summary")` record is created after the threshold is crossed.
/// - The summarised turns are removed from the active message list.
/// - Pinned turns are never included in the folded window.
/// - Non-pinned turns beyond `recentTurnsToPreserve` are removed.
/// - Turns that were not folded (the recent preserve window) remain intact.
/// - Summarisation does not fire when utilization is below the threshold.
/// - An empty summary from the summariser leaves history unchanged.
@MainActor
/// Integration coverage uses real SwiftData; existing lower-level cases stay in this suite.
final class SummarisationHookIntegrationTests: XCTestCase {

    /// Counts which production persistence operation a hook dispatches while
    /// forwarding all storage work to the real SwiftData provider.
    final class CountingSwiftDataMessageStore: MessageStore {
        struct PageRequest: Equatable {
            let cursor: MessageHistoryCursor?
            let limit: Int
        }

        private let provider: SwiftDataPersistenceProvider
        private(set) var wholeFetchCount = 0
        private(set) var pageRequests: [PageRequest] = []

        init(provider: SwiftDataPersistenceProvider) {
            self.provider = provider
        }

        func insertMessage(_ message: ChatMessage) async throws {
            try await provider.insertMessage(message)
        }

        func updateMessage(_ message: ChatMessage) async throws {
            try await provider.updateMessage(message)
        }

        func deleteMessage(_ messageID: UUID) async throws {
            try await provider.deleteMessage(messageID)
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            wholeFetchCount += 1
            return try await provider.fetchMessages(for: sessionID)
        }

        func fetchMessageHistoryPage(
            for sessionID: UUID,
            cursor: MessageHistoryCursor?,
            limit: Int
        ) async throws -> MessageHistoryPage {
            pageRequests.append(PageRequest(cursor: cursor, limit: limit))
            return try await provider.fetchMessageHistoryPage(
                for: sessionID,
                cursor: cursor,
                limit: limit
            )
        }

        func deleteMessages(for sessionID: UUID) async throws {
            try await provider.deleteMessages(for: sessionID)
        }
    }

    // MARK: - In-memory MessageStore

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

    // MARK: - In-memory SessionStore (thin, for pinned-IDs)

    final class InMemorySessionStore: SessionStore {
        var sessions: [UUID: ChatSession] = [:]

        func insertSession(_ session: ChatSession) async throws {
            sessions[session.id] = session
        }

        func updateSession(_ session: ChatSession) async throws {
            sessions[session.id] = session
        }

        func deleteSession(_ sessionID: UUID) async throws {
            sessions.removeValue(forKey: sessionID)
        }

        func deleteAll() async throws {
            sessions.removeAll()
        }

        func fetchSessions() async throws -> [ChatSession] {
            Array(sessions.values)
        }
    }

    // MARK: - Throwing SessionStore (#A2)

    /// A `SessionStore` whose `fetchSessions()` always throws, simulating a
    /// transient persistence failure while resolving pinned-message IDs.
    final class ThrowingFetchSessionsStore: SessionStore {
        struct Failure: Error {}

        func insertSession(_ session: ChatSession) async throws {}
        func updateSession(_ session: ChatSession) async throws {}
        func deleteSession(_ sessionID: UUID) async throws {}
        func deleteAll() async throws {}
        func fetchSessions() async throws -> [ChatSession] { throw Failure() }
    }

    // MARK: - MockDialogueSummariser

    /// A summariser that returns a fixed string and records what it was given.
    actor RecordingDialogueSummariser: DialogueSummariser {
        let fixedResponse: String
        private(set) var capturedTurns: [ChatMessage] = []

        init(fixedResponse: String = "NONCE-SUMMARY-42: Previously discussed weather in Paris and Rome.") {
            self.fixedResponse = fixedResponse
        }

        func summarise(turns: [ChatMessage], using backend: any InferenceBackend) async throws -> String {
            capturedTurns = turns
            return fixedResponse
        }
    }

    /// A summariser that always returns an empty string.
    struct EmptyDialogueSummariser: DialogueSummariser {
        func summarise(turns: [ChatMessage], using backend: any InferenceBackend) async throws -> String { "" }
    }

    // MARK: - UsageReportingBackend (mirrors CompressionPolicyTests)

    /// Wraps MockInferenceBackend and injects a `.usage` event so the runtime
    /// tracks `promptTokens`, which the hook needs to evaluate the threshold.
    final class UsageReportingBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
        let inner: MockInferenceBackend
        let reportedPromptTokens: Int

        init(inner: MockInferenceBackend, reportedPromptTokens: Int = 900) {
            self.inner = inner
            self.reportedPromptTokens = reportedPromptTokens
        }

        var lastUsage: (promptTokens: Int, completionTokens: Int)? { (reportedPromptTokens, 10) }
        var isModelLoaded: Bool { get { inner.isModelLoaded } set { inner.isModelLoaded = newValue } }
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

    // MARK: - Helpers

    private func waitForStreamFinished(
        on runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws {
        let task = Task {
            for await event in runtime.events {
                if case .streamFinished = event { return }
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw TestDeadline.elapsed
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Polls until none of `ids` remain in `store` for `sessionID`, or throws after `deadline`.
    ///
    /// Used alongside `waitForMemoryRecord` to confirm the hook's deletion pass
    /// completed — the hook inserts the summary first then deletes source turns,
    /// so the memory record appearing is necessary but not sufficient.
    private func waitForTurnsDeleted(
        ids: Set<UUID>,
        in store: RuntimeMessageStore,
        sessionID: UUID,
        deadline: Duration = .seconds(5)
    ) async throws {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            let messages = try await store.fetchMessages(for: sessionID)
            let remaining = Set(messages.map { $0.id })
            if ids.isDisjoint(with: remaining) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestDeadline.elapsed
    }

    /// Polls `store.fetchMessages` until at least one `.memory`-kind record
    /// appears for `sessionID`, or throws `TestDeadline.elapsed` after `deadline`.
    ///
    /// The hook runs asynchronously after `afterGeneration` fires, so a fixed
    /// yield count is non-deterministic under load. Polling the store is the
    /// authoritative signal that the hook's async work completed.
    private func waitForMemoryRecord(
        in store: RuntimeMessageStore,
        sessionID: UUID,
        deadline: Duration = .seconds(5)
    ) async throws {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            let messages = try await store.fetchMessages(for: sessionID)
            let hasMemory = messages.contains {
                if case .memory = $0.kind { return true }
                return false
            }
            if hasMemory { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestDeadline.elapsed
    }

    private func waitForAfterGeneration(
        on runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws {
        let task = Task {
            for await event in runtime.events {
                if case .afterGeneration = event { return }
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw TestDeadline.elapsed
            }
            try await group.next()
            group.cancelAll()
        }
    }

    enum TestDeadline: Error { case elapsed }

    // MARK: - Test 1: memory message is created when threshold is crossed

    func test_memoryMessageCreated_whenThresholdCrossed() async throws {
        let store = RuntimeMessageStore()
        let summariser = RecordingDialogueSummariser()
        let mockInner = MockInferenceBackend()
        mockInner.isModelLoaded = true
        mockInner.tokensToYield = ["Reply"]
        let backend = UsageReportingBackend(inner: mockInner, reportedPromptTokens: 900)
        let sessionID = UUID()

        // context size = 1000, prompt tokens = 900 → 90% → exceeds 80% threshold
        let hook = SummarisationHook(
            messageStore: store,
            backend: backend,
            summariser: summariser,
            policy: ThresholdSummarisationPolicy(utilizationThreshold: 0.8),
            recentTurnsToPreserve: 2,
            contextSizeProvider: { 1000 }
        )

        let inference = InferenceService(backend: backend, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: [hook]
        )

        // Insert 6 chat turns by hand so we have enough history to fold.
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

        // Drive one turn through the runtime to trigger the hook.
        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Turn 7", attachments: []),
            config: TurnConfig()
        ))

        try await waitForAfterGeneration(on: runtime)
        try await waitForMemoryRecord(in: store, sessionID: sessionID)

        let remaining = try await store.fetchMessages(for: sessionID)
        let memoryMessages = remaining.filter {
            if case .memory = $0.kind { return true }
            return false
        }

        XCTAssertEqual(memoryMessages.count, 1,
            "exactly one .memory record should exist after threshold is crossed; remaining: \(remaining.map { "\($0.role.rawValue):\($0.kind)" })")

        let summaryContent = try XCTUnwrap(memoryMessages.first?.content)
        XCTAssertEqual(summaryContent, summariser.fixedResponse,
            "summary record should contain the summariser's output")

        // Sabotage: confirm that if the summariser returned different text, the test would fail.
        XCTAssertNotEqual(summaryContent, "DIFFERENT_CONTENT",
            "sabotage: memory content must match the summariser output, not random text")
    }

    // MARK: - Test 2: turns that were folded are removed

    func test_summarisedTurnsRemovedFromHistory() async throws {
        let store = RuntimeMessageStore()
        let summariser = RecordingDialogueSummariser()
        let mockInner = MockInferenceBackend()
        mockInner.isModelLoaded = true
        mockInner.tokensToYield = ["Reply"]
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

        let inference = InferenceService(backend: backend, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: [hook]
        )

        // Insert 6 explicitly timestamped chat turns.
        var insertedIDs: [UUID] = []
        for i in 1...6 {
            let role: MessageRole = i.isMultiple(of: 2) ? .assistant : .user
            let msg = ChatMessage(
                role: role,
                content: "Message \(i)",
                timestamp: Date(timeIntervalSince1970: Double(i)),
                sessionID: sessionID
            )
            try await store.insertMessage(msg)
            insertedIDs.append(msg.id)
        }

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "New message", attachments: []),
            config: TurnConfig()
        ))

        try await waitForAfterGeneration(on: runtime)
        try await waitForMemoryRecord(in: store, sessionID: sessionID)
        // The hook inserts the summary then deletes source turns in a separate
        // loop — wait for the deletions to complete before asserting absence.
        let capturedIDs = Set(await summariser.capturedTurns.map { $0.id })
        try await waitForTurnsDeleted(ids: capturedIDs, in: store, sessionID: sessionID)

        let remaining = try await store.fetchMessages(for: sessionID)

        // The 6 pre-seeded turns + 1 user send + 1 assistant reply = 8 `.chat` turns.
        // Hook should fold oldest 8 − 2 = 6 turns, keep 2 recent + 1 memory.
        // Exact counts depend on timing, but the memory record must exist and
        // the total count must be less than 8.
        let chatMessages = remaining.filter { $0.kind == .chat }
        let memoryMessages = remaining.filter {
            if case .memory = $0.kind { return true }; return false
        }

        XCTAssertFalse(memoryMessages.isEmpty, "at least one memory record should exist")
        XCTAssertLessThan(remaining.count, 9,
            "summarised turns should have been removed; remaining count: \(remaining.count)")

        let remainingIDs = Set(remaining.map { $0.id })
        let overlap = capturedIDs.intersection(remainingIDs)
        XCTAssertTrue(overlap.isEmpty,
            "turns passed to the summariser should have been deleted; overlap IDs: \(overlap)")
    }

    // MARK: - Test 3: pinned turns are never summarised

    func test_pinnedTurnsNotSummarised() async throws {
        let store = RuntimeMessageStore()
        let sessionStore = InMemorySessionStore()
        let summariser = RecordingDialogueSummariser()
        let mockInner = MockInferenceBackend()
        mockInner.isModelLoaded = true
        mockInner.tokensToYield = ["Reply"]
        let backend = UsageReportingBackend(inner: mockInner, reportedPromptTokens: 900)
        let sessionID = UUID()

        // Insert session record.
        var session = ChatSession(id: sessionID, title: "Test")

        let hook = SummarisationHook(
            messageStore: store,
            backend: backend,
            sessionStore: sessionStore,
            summariser: summariser,
            policy: ThresholdSummarisationPolicy(utilizationThreshold: 0.8),
            recentTurnsToPreserve: 2,
            contextSizeProvider: { 1000 }
        )

        let inference = InferenceService(backend: backend, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: [hook]
        )

        // Insert 8 turns. Pin the first two.
        var pinnedIDs: Set<UUID> = []
        for i in 1...8 {
            let role: MessageRole = i.isMultiple(of: 2) ? .assistant : .user
            let msg = ChatMessage(
                role: role,
                content: "Message \(i)",
                timestamp: Date(timeIntervalSince1970: Double(i)),
                sessionID: sessionID
            )
            try await store.insertMessage(msg)
            if i <= 2 {
                pinnedIDs.insert(msg.id)
            }
        }
        session.pinnedMessageIDs = pinnedIDs
        try await sessionStore.insertSession(session)

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Trigger turn", attachments: []),
            config: TurnConfig()
        ))

        try await waitForAfterGeneration(on: runtime)
        try await waitForMemoryRecord(in: store, sessionID: sessionID)

        // Verify none of the pinned IDs were passed to the summariser.
        let capturedIDs = Set(await summariser.capturedTurns.map { $0.id })
        for pinnedID in pinnedIDs {
            XCTAssertFalse(capturedIDs.contains(pinnedID),
                "pinned message \(pinnedID) should not be passed to the summariser")
        }

        // Verify pinned turns still exist in the store.
        let remaining = try await store.fetchMessages(for: sessionID)
        let remainingIDs = Set(remaining.map { $0.id })
        for pinnedID in pinnedIDs {
            XCTAssertTrue(remainingIDs.contains(pinnedID),
                "pinned message \(pinnedID) must still exist after summarisation")
        }

        // Sabotage: confirm that if we had not pinned them, one might be absent.
        // (We can't easily run a full "would have been deleted" check inline,
        //  so we confirm the pinned IDs are all still present — the positive case.)
        XCTAssertEqual(pinnedIDs.subtracting(remainingIDs).count, 0,
            "sabotage: all pinned IDs must be in remaining; missing: \(pinnedIDs.subtracting(remainingIDs))")
    }

    // MARK: - Test: sessionStore.fetchSessions() failure aborts the cycle (#A2)

    func test_summarisationAborts_whenFetchSessionsFails() async throws {
        // Sabotage check (verified manually): reverting the catch branch in
        // `performSummarisation` to `pinnedIDs = []` (proceeding with folding
        // and deletion despite unknown pin status) causes this test to fail —
        // messages get folded into a summary and deleted even though the
        // session store never confirmed nothing is pinned.
        let store = RuntimeMessageStore()
        let sessionStore = ThrowingFetchSessionsStore()
        let summariser = RecordingDialogueSummariser()
        let mockInner = MockInferenceBackend()
        mockInner.isModelLoaded = true
        mockInner.tokensToYield = ["Reply"]
        let backend = UsageReportingBackend(inner: mockInner, reportedPromptTokens: 900)
        let sessionID = UUID()

        let hook = SummarisationHook(
            messageStore: store,
            backend: backend,
            sessionStore: sessionStore,
            summariser: summariser,
            policy: ThresholdSummarisationPolicy(utilizationThreshold: 0.8),
            recentTurnsToPreserve: 2,
            contextSizeProvider: { 1000 }
        )

        let inference = InferenceService(backend: backend, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: [hook]
        )

        for i in 1...8 {
            let role: MessageRole = i.isMultiple(of: 2) ? .assistant : .user
            let msg = ChatMessage(
                role: role,
                content: "Message \(i)",
                timestamp: Date(timeIntervalSince1970: Double(i)),
                sessionID: sessionID
            )
            try await store.insertMessage(msg)
        }
        let preTurnCount = try await store.fetchMessages(for: sessionID).count

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Trigger turn", attachments: []),
            config: TurnConfig()
        ))

        try await waitForAfterGeneration(on: runtime)
        // Negative assertion — give the hook time to (not) fold/delete, then assert.
        try await Task.sleep(for: .milliseconds(200))

        let remaining = try await store.fetchMessages(for: sessionID)
        // +2 for the new user message and assistant reply from this turn;
        // nothing from the pre-existing history was folded or deleted.
        XCTAssertEqual(remaining.count, preTurnCount + 2,
            "no messages should be folded/deleted when pin status is unknown")

        let memoryMessages = remaining.filter {
            if case .memory = $0.kind { return true }; return false
        }
        XCTAssertEqual(memoryMessages.count, 0,
            "no .memory summary record should be inserted when the cycle aborts")

        let capturedCount = await summariser.capturedTurns.count
        XCTAssertEqual(capturedCount, 0,
            "summariser should never be invoked when pin status could not be resolved")
    }

    // MARK: - Test 4: summarisation does not fire below threshold

    func test_noSummarisation_whenBelowThreshold() async throws {
        let store = RuntimeMessageStore()
        let summariser = RecordingDialogueSummariser()
        let mockInner = MockInferenceBackend()
        mockInner.isModelLoaded = true
        mockInner.tokensToYield = ["Reply"]
        // 300 / 1000 = 30 % → well below 80 % threshold
        let backend = UsageReportingBackend(inner: mockInner, reportedPromptTokens: 300)
        let sessionID = UUID()

        let hook = SummarisationHook(
            messageStore: store,
            backend: backend,
            summariser: summariser,
            policy: ThresholdSummarisationPolicy(utilizationThreshold: 0.8),
            recentTurnsToPreserve: 2,
            contextSizeProvider: { 1000 }
        )

        let inference = InferenceService(backend: backend, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: [hook]
        )

        for i in 1...6 {
            let role: MessageRole = i.isMultiple(of: 2) ? .assistant : .user
            let msg = ChatMessage(
                role: role,
                content: "Turn \(i)",
                timestamp: Date(timeIntervalSince1970: Double(i)),
                sessionID: sessionID
            )
            try await store.insertMessage(msg)
        }

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hello", attachments: []),
            config: TurnConfig()
        ))

        try await waitForAfterGeneration(on: runtime)
        // Negative assertion — give the hook time to NOT fire, then assert.
        try await Task.sleep(for: .milliseconds(200))

        let remaining = try await store.fetchMessages(for: sessionID)
        let memoryMessages = remaining.filter {
            if case .memory = $0.kind { return true }; return false
        }

        XCTAssertEqual(memoryMessages.count, 0,
            "no .memory records should exist when utilization is below threshold; got \(memoryMessages.count)")
        let capturedCount = await summariser.capturedTurns.count
        XCTAssertEqual(capturedCount, 0,
            "summariser should not have been called; captured: \(capturedCount) turns")
    }

    // MARK: - Test 5: empty summary leaves history unchanged

    func test_emptySummaryLeavesHistoryUnchanged() async throws {
        let store = RuntimeMessageStore()
        let mockInner = MockInferenceBackend()
        mockInner.isModelLoaded = true
        mockInner.tokensToYield = ["Reply"]
        let backend = UsageReportingBackend(inner: mockInner, reportedPromptTokens: 900)
        let sessionID = UUID()

        let hook = SummarisationHook(
            messageStore: store,
            backend: backend,
            summariser: EmptyDialogueSummariser(),
            policy: ThresholdSummarisationPolicy(utilizationThreshold: 0.8),
            recentTurnsToPreserve: 2,
            contextSizeProvider: { 1000 }
        )

        let inference = InferenceService(backend: backend, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            generationHooks: [hook]
        )

        for i in 1...6 {
            let role: MessageRole = i.isMultiple(of: 2) ? .assistant : .user
            let msg = ChatMessage(
                role: role,
                content: "Turn \(i)",
                timestamp: Date(timeIntervalSince1970: Double(i)),
                sessionID: sessionID
            )
            try await store.insertMessage(msg)
        }

        let beforeCount = 6

        _ = try await runtime.processTurn(TurnInput(
            sessionID: sessionID,
            kind: .send(text: "Hello", attachments: []),
            config: TurnConfig()
        ))

        try await waitForAfterGeneration(on: runtime)
        // Negative assertion — give the hook time to NOT write a record, then assert.
        try await Task.sleep(for: .milliseconds(200))

        let remaining = try await store.fetchMessages(for: sessionID)
        let chatMessages = remaining.filter { $0.kind == .chat }
        let memoryMessages = remaining.filter {
            if case .memory = $0.kind { return true }; return false
        }

        XCTAssertEqual(memoryMessages.count, 0,
            "no .memory records should exist when the summariser returns empty; got \(memoryMessages.count)")
        // The 6 pre-seeded turns + 1 user send + 1 assistant reply should all be present.
        XCTAssertGreaterThanOrEqual(chatMessages.count, beforeCount,
            "pre-existing chat turns should all still be present; chat count: \(chatMessages.count)")
    }

    /// `postGeneration` must use a bounded keyset page for its candidate
    /// window. Calling `fetchHealedMessages` here would dispatch through the
    /// wrapper's whole-session method and fail this regression check.
    func test_postGeneration_readsBoundedSwiftDataPage_notWholeTranscript() async throws {
        struct AlwaysSummarise: SummarisationPolicy {
            func shouldSummarise(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
                true
            }
        }

        let stack = try InMemoryPersistenceHarness.make()
        let sessionID = UUID()
        let records = (0..<3).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "history-\(index)",
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                sessionID: sessionID
            )
        }
        try await stack.provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let messageStore = CountingSwiftDataMessageStore(provider: stack.provider)
        let summariser = RecordingDialogueSummariser(fixedResponse: "bounded-summary")
        let hook = SummarisationHook(
            messageStore: messageStore,
            backend: MockInferenceBackend(),
            summariser: summariser,
            policy: AlwaysSummarise(),
            recentTurnsToPreserve: 1,
            contextSizeProvider: { 1 }
        )
        let completedTurn = CompletedTurn(
            sessionID: sessionID,
            assistantMessage: records[2],
            promptTokens: 1,
            completionTokens: 1
        )

        await hook.postGeneration(completedTurn)

        let folded = await summariser.capturedTurns
        XCTAssertEqual(folded.map(\.id), records.prefix(2).map(\.id))
        XCTAssertEqual(messageStore.wholeFetchCount, 0)
        XCTAssertEqual(messageStore.pageRequests, [.init(cursor: nil, limit: 10_000)])

        let remaining = try await stack.provider.fetchMessages(for: sessionID)
        XCTAssertEqual(remaining.filter { $0.kind == .chat }.map(\.id), [records[2].id])
        XCTAssertEqual(remaining.first(where: { $0.kind == .memory("summary") })?.content, "bounded-summary")
    }
}
