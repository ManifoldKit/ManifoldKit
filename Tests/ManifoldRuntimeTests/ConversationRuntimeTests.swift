@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

private final class RuntimeUsageBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
    struct Turn: Sendable {
        let tokens: [String]
        let usage: (promptTokens: Int, completionTokens: Int)?
        let streamErrorMessage: String?

        init(
            tokens: [String],
            usage: (promptTokens: Int, completionTokens: Int)?,
            streamErrorMessage: String? = nil
        ) {
            self.tokens = tokens
            self.usage = usage
            self.streamErrorMessage = streamErrorMessage
        }
    }

    var isModelLoaded = true
    var isGenerating = false
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )
    var lastUsage: (promptTokens: Int, completionTokens: Int)?

    private let lock = NSLock()
    private var turns: [Turn]

    init(turns: [Turn]) {
        self.turns = turns
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }
        let turn = nextTurn()
        isGenerating = true

        return GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            Task {
                for token in turn.tokens {
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                if let usage = turn.usage, !Task.isCancelled {
                    continuation.yield(.usage(prompt: usage.promptTokens, completion: usage.completionTokens))
                    self.lastUsage = usage
                }
                self.isGenerating = false
                if let message = turn.streamErrorMessage, !Task.isCancelled {
                    continuation.finish(throwing: InferenceError.inferenceFailure(message))
                } else {
                    continuation.finish()
                }
            }
        })
    }

    func stopGeneration() {
        isGenerating = false
    }

    func unloadModel() {
        isModelLoaded = false
        isGenerating = false
    }

    private func nextTurn() -> Turn {
        lock.lock()
        defer { lock.unlock() }
        if turns.isEmpty {
            return Turn(tokens: [], usage: nil)
        }
        return turns.removeFirst()
    }
}

/// Phase 1.2.5 PR-A — coverage for the new `ConversationRuntime` send sub-flow.
///
/// Send is the only sub-flow PR-A ships. Regenerate / edit / branch are
/// covered by their PRs (PR-B / PR-C). Tests use the in-memory `MessageStore`
/// fake from `MessageStorePostWriteHookTests` shape (re-stated here as
/// `RuntimeMessageStore` to keep the fixture independent — these tests run
/// in `ManifoldCoreTests`, the hook tests live in `ManifoldInferenceTests`).
@MainActor
final class ConversationRuntimeTests: XCTestCase {

    // MARK: - In-memory MessageStore (with hooks)

    @MainActor
    final class RuntimeMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []
        /// When set, the next `deleteMessage` call throws this error instead
        /// of performing the delete. Cleared after the throw so subsequent
        /// deletes succeed normally.
        var deleteError: (any Error)?
        /// When set, the next `updateMessage` call throws this error instead
        /// of performing the update. Cleared after the throw so subsequent
        /// updates succeed normally.
        var updateError: (any Error)?
        /// When set, the next `insertMessage` call throws this error instead
        /// of performing the insert. Cleared after the throw so subsequent
        /// inserts succeed normally.
        var insertError: (any Error)?

        func insertMessage(_ message: ChatMessageRecord) async throws {
            if let error = insertError {
                insertError = nil
                throw error
            }
            messages[message.id] = message
            for hook in hooks {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func updateMessage(_ message: ChatMessageRecord) async throws {
            if let error = updateError {
                updateError = nil
                throw error
            }
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
            for hook in hooks {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func deleteMessage(_ messageID: UUID) async throws {
            if let error = deleteError {
                deleteError = nil
                throw error
            }
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

    /// In-memory `SessionStore` paired with the message fake. Touch-session
    /// behaviour is covered by an explicit test below.
    @MainActor
    final class RuntimeSessionStore: SessionStore {
        private(set) var sessions: [UUID: ChatSessionRecord] = [:]
        private(set) var updateCount: Int = 0
        /// When set, the next `insertSession` call throws this error instead
        /// of performing the insert. Cleared after the throw.
        var insertError: (any Error)?
        /// When set, the next `updateSession` call throws this error instead
        /// of performing the update. Cleared after the throw.
        var updateError: (any Error)?
        /// When set, the next `fetchSessions` call throws this error instead
        /// of returning sessions. Cleared after the throw.
        var fetchError: (any Error)?

        func insertSession(_ session: ChatSessionRecord) async throws {
            if let error = insertError {
                insertError = nil
                throw error
            }
            sessions[session.id] = session
        }

        func updateSession(_ session: ChatSessionRecord) async throws {
            if let error = updateError {
                updateError = nil
                throw error
            }
            guard sessions[session.id] != nil else {
                throw ChatPersistenceError.sessionNotFound(session.id)
            }
            sessions[session.id] = session
            updateCount += 1
        }

        func deleteSession(_ sessionID: UUID) async throws {
            guard sessions.removeValue(forKey: sessionID) != nil else {
                throw ChatPersistenceError.sessionNotFound(sessionID)
            }
        }

        func fetchSessions() async throws -> [ChatSessionRecord] {
            if let error = fetchError {
                fetchError = nil
                throw error
            }
            return sessions.values.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Records every message that the store emits a post-write hook for. Used
    /// to pin the contract that the runtime drives both writes through the
    /// hookable surface (not through some side-channel that bypasses hooks).
    final class HookRecorder: MessageStorePostWriteHook, @unchecked Sendable {
        private let queue = DispatchQueue(label: "HookRecorder.lock")
        private var _records: [(role: MessageRole, sessionID: UUID, content: String)] = []

        func messageDidWrite(_ record: ChatMessageRecord, in sessionID: ChatSessionRecord.ID) async {
            queue.sync {
                _records.append((record.role, sessionID, record.content))
            }
        }

        var records: [(role: MessageRole, sessionID: UUID, content: String)] {
            queue.sync { _records }
        }
    }

    // MARK: - Helpers

    /// Builds a runtime with a mock backend pre-loaded and a fresh in-memory
    /// store. Tests configure `mock.tokensToYield` before calling `send`.
    private func makeRuntime(
        mock: MockInferenceBackend? = nil,
        sessionStore: RuntimeSessionStore? = nil,
        pipeline: PromptContextPipeline? = nil
    ) -> (runtime: ConversationRuntime, store: RuntimeMessageStore, mock: MockInferenceBackend, sessions: RuntimeSessionStore?) {
        let backend = mock ?? MockInferenceBackend()
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: sessionStore,
            inferenceService: inference,
            pipeline: pipeline
        )
        return (runtime, store, backend, sessionStore)
    }

    /// Drains events from the runtime until `predicate` returns `true` for
    /// the most recent event, or the deadline elapses. Returns the captured
    /// transcript — tests assert on the order of events without relying on
    /// exact timing.
    private func collectEvents(
        from runtime: ConversationRuntime,
        until predicate: @escaping @Sendable (ConversationEvent) -> Bool,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        var collected: [ConversationEvent] = []
        let task = Task {
            for await event in runtime.events {
                collected.append(event)
                if predicate(event) { break }
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

    private func waitForEvents(
        from task: Task<[ConversationEvent], Never>,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
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

    private func collectUntilStreamFinished(
        from runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        try await collectEvents(from: runtime, until: { event in
            if case .streamFinished = event { return true }
            return false
        }, deadline: deadline)
    }

    private func drainUntilStreamFinished(from runtime: ConversationRuntime) -> Task<[ConversationEvent], Never> {
        Task { @MainActor [runtime] in
            var events: [ConversationEvent] = []
            for await event in runtime.events {
                events.append(event)
                if case .streamFinished = event { return events }
            }
            return events
        }
    }

    private func streamFinishedReasons(in events: [ConversationEvent]) -> [FinishReason] {
        events.compactMap { event in
            if case let .streamFinished(_, reason) = event { return reason }
            return nil
        }
    }

    enum TestError: Error { case deadlineElapsed }

    // MARK: - RAG citations

    /// In-memory RAG-adjacent fakes mirroring the shapes from `RAGServiceTests`,
    /// re-stated here so this file stays independent of that fixture set.
    @MainActor
    final class CitationDocumentStore: DocumentStore {
        var inserted: [DocumentRecord] = []
        func insertDocument(_ record: DocumentRecord) async throws { inserted.append(record) }
        func fetchDocuments() async throws -> [DocumentRecord] { inserted }
        func fetchDocument(id: UUID) async throws -> DocumentRecord? { inserted.first { $0.id == id } }
        func deleteDocument(id: UUID) async throws { inserted.removeAll { $0.id == id } }
    }

    actor CitationVectorStore: VectorStore {
        var keywordHits: [VectorSearchHit] = []
        func setKeywordHits(_ hits: [VectorSearchHit]) { keywordHits = hits }
        func insert(chunks: [DocumentChunk], documentTitle: String, embeddings: [[Float]]) throws {}
        func search(embedding: [Float], limit: Int) throws -> [VectorSearchHit] { [] }
        func keywordSearch(query: String, limit: Int) throws -> [VectorSearchHit] { keywordHits }
        func delete(documentID: UUID) throws {}
        func deleteAll() throws {}
    }

    func test_send_withRagService_attachesCitationsToAssistantMessage() async throws {
        // Pre-seed the vector store with a keyword hit so RAGService.retrieve()
        // returns one slot + one citation for any non-empty query.
        let vectorStore = CitationVectorStore()
        let docID = UUID()
        let hit = VectorSearchHit(
            chunk: DocumentChunk(documentID: docID, text: "ManifoldKit is a SwiftUI chat framework.", chunkIndex: 0),
            documentTitle: "Overview.txt",
            score: 1.0
        )
        await vectorStore.setKeywordHits([hit])
        let ragService = RAGService(documentStore: CitationDocumentStore(), vectorStore: vectorStore)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let backend = mock
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inference,
            ragService: ragService
        )

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "What is ManifoldKit?"))
        _ = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        let stored = Array(store.messages.values).sorted { $0.timestamp < $1.timestamp }
        let assistant = stored.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistant, "Assistant message persisted")
        let citations = assistant?.citations ?? []
        XCTAssertEqual(citations.count, 1, "One citation per retrieval hit")
        XCTAssertEqual(citations.first?.documentID, docID)
        XCTAssertEqual(citations.first?.documentTitle, "Overview.txt")
        XCTAssertEqual(citations.first?.chunkIndex, 0)
    }

    func test_send_withRagService_noHits_assistantMessageHasNilCitations() async throws {
        // Empty keyword hits → no citations attached. Assistant.citations stays nil
        // so the bubble doesn't render an empty "Sources" disclosure.
        let vectorStore = CitationVectorStore()
        await vectorStore.setKeywordHits([])
        let ragService = RAGService(documentStore: CitationDocumentStore(), vectorStore: vectorStore)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["fine"]
        let backend = mock
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: nil,
            inferenceService: inference,
            ragService: ragService
        )

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "anything"))
        _ = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        let stored = Array(store.messages.values).sorted { $0.timestamp < $1.timestamp }
        let assistant = stored.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistant)
        XCTAssertNil(assistant?.citations, "No retrieval hits → citations stays nil")
    }

    // MARK: - Send happy path

    func test_send_happyPath_persistsBothMessagesAndStreamsTokens() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " runtime"]
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        let input = SendInput(sessionID: sessionID, userText: "hi")
        _ = try await runtime.send(input)

        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        // Persistence: two messages stored — one user, one assistant.
        XCTAssertEqual(store.messages.count, 2, "Both user and assistant messages persisted")
        let stored = Array(store.messages.values).sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(stored[0].role, .user)
        XCTAssertEqual(stored[0].content, "hi")
        XCTAssertEqual(stored[1].role, .assistant)
        XCTAssertEqual(stored[1].content, "Hello runtime")

        // Event ordering: the four load-bearing event categories appear in
        // the expected interleaving.
        let kinds = events.map(eventKind)
        // Exact prefix expected: user-insert, beforeContext, contextAssembled,
        // streamStarted, tokens..., assistant-insert, streamFinished,
        // afterGeneration.
        XCTAssertEqual(kinds.first, "messageInserted-user", "First event is user message insert")
        XCTAssertTrue(kinds.contains("beforeContextAssembly"), "Emits beforeContextAssembly")
        XCTAssertTrue(kinds.contains("contextAssembled"), "Emits contextAssembled")
        XCTAssertTrue(kinds.contains("streamStarted"), "Emits streamStarted")
        // The batcher coalesces tokens so the count may be less than the raw
        // token count; what matters is that at least one tokenEmitted fires
        // and the accumulated text is correct.
        XCTAssertGreaterThanOrEqual(kinds.filter { $0.hasPrefix("tokenEmitted") }.count, 1,
                                    "At least one tokenEmitted event fires")
        XCTAssertTrue(kinds.contains("messageInserted-assistant"),
                      "Emits messageInserted for the assistant message")
        XCTAssertTrue(kinds.contains("streamFinished-stop"), "Stream finishes with .stop")
        XCTAssertTrue(kinds.contains("afterGeneration"), "Emits afterGeneration")

        // Final text matches the streamed tokens.
        if case let .afterGeneration(_, text) = events.last {
            XCTAssertEqual(text, "Hello runtime")
        } else {
            XCTFail("Expected last event to be .afterGeneration")
        }
    }

    func test_send_hooksFireForBothUserAndAssistantWrites() async throws {
        // The store's post-write hook is the contract test: anything the
        // runtime persists must drive that hook. Two writes per turn.
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let (runtime, store, _, _) = makeRuntime(mock: mock)
        let recorder = HookRecorder()
        store.addPostWriteHook(recorder)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "ping"))
        _ = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        XCTAssertEqual(recorder.records.count, 2, "Hook fires for both user and assistant writes")
        XCTAssertEqual(recorder.records[0].role, .user, "First hook is the user write")
        XCTAssertEqual(recorder.records[0].content, "ping")
        XCTAssertEqual(recorder.records[0].sessionID, sessionID)
        XCTAssertEqual(recorder.records[1].role, .assistant, "Second hook is the assistant write")
        XCTAssertEqual(recorder.records[1].content, "ok")
        XCTAssertEqual(recorder.records[1].sessionID, sessionID)
    }

    // MARK: - Empty response

    func test_send_emptyResponse_dropsAssistantMessage() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = []
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "say nothing"))
        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        // Only the user message persists; the assistant message is dropped.
        XCTAssertEqual(store.messages.count, 1, "Empty assistant response is dropped, user persisted")
        XCTAssertEqual(Array(store.messages.values).first?.role, .user)

        // Stream finishes with .empty.
        XCTAssertTrue(events.contains(where: {
            if case .streamFinished(_, .empty) = $0 { return true } else { return false }
        }), "Stream finishes with .empty when no tokens were emitted")
    }

    // MARK: - Finish-state regressions

    func test_finishState_success_emitsSingleStopTerminalAfterAssistantInsert() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["done"]
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "go"))
        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        XCTAssertEqual(streamFinishedReasons(in: events), [.stop],
                       "Successful generation emits exactly one .stop terminal")
        let assistantInsertIndex = events.firstIndex {
            if case let .messageInserted(record) = $0, record.role == .assistant { return true }
            return false
        }
        let finishIndex = events.firstIndex {
            if case .streamFinished = $0 { return true }
            return false
        }
        XCTAssertNotNil(assistantInsertIndex)
        XCTAssertNotNil(finishIndex)
        if let assistantInsertIndex, let finishIndex {
            XCTAssertLessThan(assistantInsertIndex, finishIndex,
                              "Assistant insert precedes the terminal event on success")
        }
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.map(\.content), ["done"])
    }

    func test_finishState_emptyResponse_emitsSingleEmptyTerminalAndDropsAssistant() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = []
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "empty"))
        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        XCTAssertEqual(streamFinishedReasons(in: events), [.empty],
                       "Empty generation emits exactly one .empty terminal")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.count, 0,
                       "Empty assistant response is not persisted")
        guard case let .afterGeneration(_, finalText) = events.last else {
            XCTFail("Expected afterGeneration after empty terminal")
            return
        }
        XCTAssertEqual(finalText, "")
    }

    func test_finishState_cancelBeforeFirstToken_emitsSingleCancelledTerminalAndNoAssistant() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["late"]
        let gate = TokenEmissionGate()
        mock.tokenEmissionGate = gate
        let (runtime, store, _, _) = makeRuntime(mock: mock)
        let drain = drainUntilStreamFinished(from: runtime)

        let handle = try await runtime.send(SendInput(
            sessionID: UUID(),
            userText: "cancel",
            streamingBatchCharacterLimit: 1
        ))
        await runtime.cancel(handle)

        let events = try await waitForEvents(from: drain)
        await gate.release()

        XCTAssertEqual(streamFinishedReasons(in: events), [.cancelled],
                       "Cancel before the first visible token emits exactly one cancelled terminal")
        XCTAssertFalse(events.contains {
            if case .tokenEmitted = $0 { return true }
            return false
        }, "No token event should escape after pre-token cancel")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.count, 0,
                       "Pre-token cancel drops the empty assistant")
    }

    func test_finishState_cancelAfterPartialOutput_persistsPartialAndEmitsSingleCancelledTerminal() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["one", " two"]
        let gate = TokenEmissionGate()
        mock.tokenEmissionGate = gate
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let handle = try await runtime.send(SendInput(
            sessionID: UUID(),
            userText: "cancel partial",
            streamingBatchCharacterLimit: 1
        ))
        let drain = Task { @MainActor [runtime] in
            var events: [ConversationEvent] = []
            var didCancel = false
            for await event in runtime.events {
                events.append(event)
                switch event {
                case .tokenEmitted:
                    if !didCancel {
                        didCancel = true
                        await runtime.cancel(handle)
                        await gate.release()
                    }
                case .streamFinished:
                    return events
                default:
                    break
                }
            }
            return events
        }

        await gate.advance()
        let events = try await waitForEvents(from: drain)

        XCTAssertEqual(streamFinishedReasons(in: events), [.cancelled],
                       "Cancel after partial output emits exactly one cancelled terminal")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.map(\.content), ["one"],
                       "Cancel after partial output persists only the streamed prefix")
    }

    func test_finishState_streamErrorWithoutPartial_emitsErrorBeforeSingleStopTerminalAndNoAssistant() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = []
        mock.shouldThrowInsideStream = InferenceError.inferenceFailure("no partial")
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "fail"))
        let events = try await collectUntilStreamFinished(from: runtime)

        XCTAssertEqual(streamFinishedReasons(in: events), [.stop],
                       "Stream error emits exactly one terminal event")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.count, 0,
                       "No assistant is persisted when the stream errors before visible output")
        let errorIndex = events.firstIndex {
            if case let .errorRaised(error) = $0, case .inference = error { return true }
            return false
        }
        let finishIndex = events.firstIndex {
            if case .streamFinished = $0 { return true }
            return false
        }
        XCTAssertNotNil(errorIndex)
        XCTAssertNotNil(finishIndex)
        if let errorIndex, let finishIndex {
            XCTAssertLessThan(errorIndex, finishIndex,
                              "Inference error is surfaced before the terminal event")
        }
    }

    func test_finishState_streamErrorWithPartial_persistsPartialThenErrorsBeforeSingleStopTerminal() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["partial"]
        mock.shouldThrowInsideStream = InferenceError.inferenceFailure("partial")
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "fail partial"))
        let events = try await collectUntilStreamFinished(from: runtime)

        XCTAssertEqual(streamFinishedReasons(in: events), [.stop],
                       "Partial stream error emits exactly one terminal event")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.map(\.content), ["partial"])
        let assistantInsertIndex = events.firstIndex {
            if case let .messageInserted(record) = $0, record.role == .assistant { return true }
            return false
        }
        let errorIndex = events.firstIndex {
            if case let .errorRaised(error) = $0, case .inference = error { return true }
            return false
        }
        let finishIndex = events.firstIndex {
            if case .streamFinished = $0 { return true }
            return false
        }
        XCTAssertNotNil(assistantInsertIndex)
        XCTAssertNotNil(errorIndex)
        XCTAssertNotNil(finishIndex)
        if let assistantInsertIndex, let errorIndex, let finishIndex {
            XCTAssertLessThan(assistantInsertIndex, errorIndex,
                              "Partial assistant insert precedes the inference error event")
            XCTAssertLessThan(errorIndex, finishIndex,
                              "Inference error precedes the terminal event")
        }
    }

    func test_finishState_thinkingOnlySuccess_finalizesThinkingThenDropsEmptyAssistant() async throws {
        let mock = MockInferenceBackend()
        mock.thinkingBlocksToYield = [["plan"]]
        mock.signaturesPerThinkingBlock = ["sig-thinking"]
        mock.tokensToYield = []
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "think only"))
        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        XCTAssertEqual(streamFinishedReasons(in: events), [.empty],
                       "Thinking-only success currently has no visible assistant text and finishes as empty")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.count, 0,
                       "Thinking-only output must not leave an empty assistant in the transcript")
        let finalized = events.compactMap { event -> (String, String?)? in
            if case let .thinkingFinalized(_, text, signature) = event { return (text, signature) }
            return nil
        }
        XCTAssertEqual(finalized.count, 1)
        XCTAssertEqual(finalized.first?.0, "plan")
        XCTAssertEqual(finalized.first?.1, "sig-thinking")
    }

    func test_finishState_thinkingOnlyError_finalizesThinkingThenErrorsWithoutAssistantInsert() async throws {
        let mock = MockInferenceBackend()
        mock.thinkingBlocksToYield = [["reason"]]
        mock.tokensToYield = []
        mock.shouldThrowInsideStream = InferenceError.inferenceFailure("thinking failed")
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "think fail"))
        let events = try await collectUntilStreamFinished(from: runtime)

        XCTAssertEqual(streamFinishedReasons(in: events), [.stop],
                       "Thinking-only stream error emits exactly one terminal event")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.count, 0,
                       "Thinking-only error without visible text does not persist an assistant")
        let finalizedIndex = events.firstIndex {
            if case .thinkingFinalized = $0 { return true }
            return false
        }
        let errorIndex = events.firstIndex {
            if case let .errorRaised(error) = $0, case .inference = error { return true }
            return false
        }
        XCTAssertNotNil(finalizedIndex)
        XCTAssertNotNil(errorIndex)
        if let finalizedIndex, let errorIndex {
            XCTAssertLessThan(finalizedIndex, errorIndex,
                              "Thinking block is finalized before the inference error is surfaced")
        }
    }

    func test_finishState_assistantInsertFailure_emitsPersistenceErrorBeforeSingleStopTerminal() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["will not persist"]
        let gate = TokenEmissionGate()
        mock.tokenEmissionGate = gate
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let drain = drainUntilStreamFinished(from: runtime)
        _ = try await runtime.send(SendInput(
            sessionID: UUID(),
            userText: "persist fail",
            streamingBatchCharacterLimit: 1
        ))
        store.insertError = ChatPersistenceError.providerNotConfigured
        await gate.advance()

        let events = try await waitForEvents(from: drain)

        XCTAssertEqual(streamFinishedReasons(in: events), [.stop],
                       "Assistant insert failure still emits exactly one terminal event")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.count, 0,
                       "Failed assistant insert must not leave transcript state behind")
        let persistenceErrorIndex = events.firstIndex {
            if case let .errorRaised(error) = $0, case .persistence = error { return true }
            return false
        }
        let finishIndex = events.firstIndex {
            if case .streamFinished = $0 { return true }
            return false
        }
        XCTAssertNotNil(persistenceErrorIndex)
        XCTAssertNotNil(finishIndex)
        if let persistenceErrorIndex, let finishIndex {
            XCTAssertLessThan(persistenceErrorIndex, finishIndex,
                              "Persistence error is surfaced before the terminal event")
        }
        XCTAssertFalse(events.contains {
            if case .afterGeneration = $0 { return true }
            return false
        }, "afterGeneration is skipped when final assistant persistence fails")
    }

    // MARK: - Inference error

    func test_send_inferenceErrorAtStream_emitsErrorRaised() async throws {
        // The enqueue path is queued and async — synchronous-throw paths are
        // hard to hit reliably from a unit test that doesn't drive the full
        // queue. The mid-stream error path is the equivalent contract test
        // for the runtime: a stream-time inference failure must surface as
        // `.errorRaised(.inference)` and the runtime must not crash. The
        // existing mid-stream test already covers persist-partial; this
        // variant exercises the no-token-then-fail path.
        let mock = MockInferenceBackend()
        mock.tokensToYield = []
        mock.shouldThrowInsideStream = InferenceError.inferenceFailure("Connection failed")
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "fail"))
        let events = try await collectEvents(from: runtime) { event in
            if case .streamFinished = event { return true }
            return false
        }

        // User message persisted (the persist happens before generation
        // runs); no assistant message persists because no tokens streamed
        // before the failure.
        let userCount = store.messages.values.filter { $0.role == .user }.count
        XCTAssertEqual(userCount, 1)
        let assistantCount = store.messages.values.filter { $0.role == .assistant }.count
        XCTAssertEqual(assistantCount, 0,
                       "Assistant message is not persisted when stream errors with no tokens")

        // .errorRaised(.inference) fired.
        let isInferenceError: (ConversationEvent) -> Bool = {
            if case let .errorRaised(error) = $0,
               case .inference = error {
                return true
            }
            return false
        }
        XCTAssertTrue(events.contains(where: isInferenceError),
                      "errorRaised(.inference) fires on stream failure")
    }

    func test_send_inferenceErrorMidStream_persistsPartialAndEmitsError() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["partial"]
        // Backend yields one token, then the stream throws.
        mock.shouldThrowInsideStream = InferenceError.inferenceFailure("upstream blew up")
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "partial"))
        let events = try await collectEvents(from: runtime) { event in
            if case .streamFinished = event { return true }
            return false
        }

        // Both user and assistant messages persisted (assistant carries the
        // partial text).
        XCTAssertEqual(store.messages.count, 2)
        let stored = Array(store.messages.values).sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(stored[1].role, .assistant)
        XCTAssertEqual(stored[1].content, "partial",
                       "Partial stream content is persisted on inference failure")

        // Both .errorRaised(.inference) and .streamFinished fire.
        let hasError = events.contains { event in
            if case let .errorRaised(error) = event, case .inference = error { return true }
            return false
        }
        XCTAssertTrue(hasError, "errorRaised(.inference) fires on mid-stream failure")
    }

    // MARK: - Token usage

    func test_send_tokenUsageEventPinsPerStreamUsageAcrossBackToBackSends() async throws {
        let backend = RuntimeUsageBackend(turns: [
            .init(tokens: ["one"], usage: (promptTokens: 11, completionTokens: 1)),
            .init(tokens: ["two"], usage: (promptTokens: 22, completionTokens: 2))
        ])
        let inference = InferenceService(backend: backend, name: "Usage")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)
        let drain = Task { @MainActor [runtime] in
            var events: [ConversationEvent] = []
            var completedTurns = 0
            for await event in runtime.events {
                events.append(event)
                if case .afterGeneration = event {
                    completedTurns += 1
                    if completedTurns == 2 { return events }
                }
            }
            return events
        }

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "first"))
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "second"))

        let events = try await waitForEvents(from: drain)
        let usageEvents = events.compactMap { event -> (messageID: UUID, prompt: Int, completion: Int)? in
            if case let .tokenUsageRecorded(messageID, promptTokens, completionTokens) = event {
                return (messageID, promptTokens, completionTokens)
            }
            return nil
        }

        XCTAssertEqual(usageEvents.map { $0.prompt }, [11, 22],
                       "Each turn emits its own prompt-token usage")
        XCTAssertEqual(usageEvents.map { $0.completion }, [1, 2],
                       "Each turn emits its own completion-token usage")

        // Look assistants up by the per-turn `tokenUsageRecorded` message id
        // rather than sorting by `timestamp`. Two back-to-back sends on a fast
        // runner can produce assistant records with identical `Date()` values,
        // making a timestamp sort non-deterministic. Event order, by contrast,
        // is the order the runtime emits — that's the contract under test.
        let assistants = usageEvents.compactMap { store.messages[$0.messageID] }
        XCTAssertEqual(assistants.count, 2, "Both assistant turns are persisted")
        XCTAssertTrue(assistants.allSatisfy { $0.role == .assistant })
        XCTAssertEqual(assistants.map(\.content), ["one", "two"])
        XCTAssertEqual(assistants.compactMap(\.promptTokens), [11, 22],
                       "Persisted assistant usage is pinned per turn, not overwritten by the next send")
        XCTAssertEqual(assistants.compactMap(\.completionTokens), [1, 2])
    }

    func test_send_tokenUsageSurvivesPartialStreamError() async throws {
        let backend = RuntimeUsageBackend(turns: [
            .init(
                tokens: ["partial"],
                usage: (promptTokens: 31, completionTokens: 4),
                streamErrorMessage: "usage after partial"
            )
        ])
        let inference = InferenceService(backend: backend, name: "Usage")
        let store = RuntimeMessageStore()
        let runtime = ConversationRuntime(messageStore: store, inferenceService: inference)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "fail with usage"))
        let events = try await collectUntilStreamFinished(from: runtime)

        XCTAssertTrue(events.contains {
            if case .tokenUsageRecorded(_, 31, 4) = $0 { return true }
            return false
        }, "Usage is observable even when the stream later errors")
        XCTAssertTrue(events.contains {
            if case let .errorRaised(error) = $0, case .inference = error { return true }
            return false
        }, "The inference error is still surfaced")

        let assistant = store.messages.values.first { $0.role == .assistant }
        XCTAssertEqual(assistant?.content, "partial")
        XCTAssertEqual(assistant?.promptTokens, 31)
        XCTAssertEqual(assistant?.completionTokens, 4)
    }

    // MARK: - Cancellation

    func test_send_cancel_propagatesAndEndsStream() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["one", "two", "three", "four", "five"]
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        // Use a tiny batch limit so tokens flush immediately and the cancel
        // has a chance to fire before the stream drains completely.
        let handle = try await runtime.send(SendInput(
            sessionID: sessionID,
            userText: "long",
            streamingBatchCharacterLimit: 1
        ))

        // Drain events on a background task; cancel as soon as we see the
        // first `.tokenEmitted` to make the timing deterministic without
        // arbitrary sleeps.
        let cancelTask = Task { @MainActor [runtime] in
            for await event in runtime.events {
                if case .tokenEmitted = event {
                    await runtime.cancel(handle)
                    break
                }
            }
        }
        await cancelTask.value

        // Wait for the terminal event.
        var sawCancelled = false
        let waitTask = Task { @MainActor [runtime] in
            for await event in runtime.events {
                if case .streamFinished(_, .cancelled) = event {
                    sawCancelled = true
                    return
                }
                if case .streamFinished = event { return }
            }
        }
        // Bound the wait so a hung test fails fast rather than spinning.
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await waitTask.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                waitTask.cancel()
            }
            try await group.next()
            group.cancelAll()
        }

        XCTAssertTrue(sawCancelled,
                      "Cancel propagates to .streamFinished(reason: .cancelled)")

        // The user message persisted. The assistant message may or may not
        // have persisted (depends on whether any tokens streamed before
        // cancel). Either is fine — the contract is that we don't crash
        // and the user message is saved.
        let userCount = store.messages.values.filter { $0.role == .user }.count
        XCTAssertEqual(userCount, 1)
    }

    func test_cancel_unknownHandle_isNoOp() async {
        let (runtime, _, _, _) = makeRuntime()
        let bogus = ConversationStreamHandle()
        // Cancelling a handle the runtime never issued must not crash or
        // hang. (Sabotaging this would mean making `cancel(_:)` force-
        // unwrap or throw — the test asserts the no-op behaviour.)
        await runtime.cancel(bogus)
    }

    // MARK: - Context pipeline integration

    func test_send_withProviders_emitsContextAssembledWithSlots() async throws {
        struct StaticProvider: PromptContextProvider {
            let slot: PromptSlot
            func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
                [slot]
            }
        }

        let slot = PromptSlot(
            id: "test",
            content: "you are a friendly assistant",
            position: .systemPreamble,
            label: "Test slot"
        )
        let pipeline = PromptContextPipeline(providers: [StaticProvider(slot: slot)])

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let (runtime, _, backend, _) = makeRuntime(mock: mock, pipeline: pipeline)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(
            sessionID: sessionID,
            userText: "hi",
            systemPrompt: "base prompt"
        ))
        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        // contextAssembled carries the provider's slot.
        let assembled = events.first { event in
            if case .contextAssembled = event { return true }
            return false
        }
        guard case let .contextAssembled(slots) = assembled else {
            XCTFail("Expected .contextAssembled event")
            return
        }
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.id, "test")

        // Slot text is appended to the system prompt forwarded to the backend.
        XCTAssertEqual(
            backend.lastSystemPrompt,
            "base prompt\n\nyou are a friendly assistant",
            "Composed system prompt prepends slot text under the caller-supplied prompt"
        )
    }

    // MARK: - Session touch

    func test_send_withSessionStore_touchesSessionTimestamp() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let sessions = RuntimeSessionStore()
        let original = ChatSessionRecord(title: "Test")
        try await sessions.insertSession(original)

        let (runtime, _, _, _) = makeRuntime(mock: mock, sessionStore: sessions)

        _ = try await runtime.send(SendInput(sessionID: original.id, userText: "hi"))
        _ = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        // Touch happens twice per send (once before generation, once after).
        XCTAssertGreaterThanOrEqual(sessions.updateCount, 1,
                                    "Session updatedAt is touched at least once per send")
    }

    func test_send_touchSessionFailureEmitsEventButDoesNotFailTurn() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["ok"]
        let sessions = RuntimeSessionStore()
        let original = ChatSessionRecord(title: "Test")
        try await sessions.insertSession(original)
        sessions.updateError = ChatPersistenceError.sessionNotFound(original.id)

        let (runtime, store, _, _) = makeRuntime(mock: mock, sessionStore: sessions)

        _ = try await runtime.send(SendInput(sessionID: original.id, userText: "hi"))
        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        XCTAssertTrue(events.contains {
            if case let .sessionTouchFailed(id) = $0 { return id == original.id }
            return false
        }, "touchSession failure is observable without becoming a user-turn error")
        XCTAssertFalse(events.contains {
            if case let .errorRaised(error) = $0, case .persistence = error { return true }
            return false
        }, "Sidebar timestamp failures must not surface as turn-failing persistence errors")
        XCTAssertEqual(store.messages.values.filter { $0.role == .assistant }.map(\.content), ["ok"])
    }

    // MARK: - Helpers

    private func eventKind(_ event: ConversationEvent) -> String {
        switch event {
        case let .messageInserted(record):
            return "messageInserted-\(record.role.rawValue)"
        case let .messageRemoved(messageID):
            return "messageRemoved(\(messageID))"
        case let .messageUpdated(record):
            return "messageUpdated-\(record.role.rawValue)"
        case .streamStarted: return "streamStarted"
        case let .tokenEmitted(_, delta): return "tokenEmitted(\(delta))"
        case let .tokenUsageRecorded(_, promptTokens, completionTokens):
            return "tokenUsageRecorded(\(promptTokens),\(completionTokens))"
        case let .streamFinished(_, reason):
            switch reason {
            case .stop: return "streamFinished-stop"
            case .cancelled: return "streamFinished-cancelled"
            case .empty: return "streamFinished-empty"
            case .length: return "streamFinished-length"
            }
        case .errorRaised: return "errorRaised"
        case .sessionTouchFailed: return "sessionTouchFailed"
        case .beforeContextAssembly: return "beforeContextAssembly"
        case .contextAssembled: return "contextAssembled"
        case .afterGeneration: return "afterGeneration"
        case .compressionTriggered: return "compressionTriggered"
        case .toolCallRequested: return "toolCallRequested"
        case .toolCallApproved: return "toolCallApproved"
        case .toolCallCompleted: return "toolCallCompleted"
        case let .sessionBranched(newSessionID, copiedCount):
            return "sessionBranched(\(newSessionID),\(copiedCount))"
        case .thinkingStarted: return "thinkingStarted"
        case .thinkingUpdated: return "thinkingUpdated"
        case .thinkingFinalized: return "thinkingFinalized"
        case .loopDetected: return "loopDetected"
        }
    }

    // MARK: - Regenerate happy path

    func test_regenerate_happyPath_replacesLastAssistantMessage() async throws {
        // Sabotage check (verified manually): if runRegenerateTurn does NOT
        // delete the old message before fetching history, the old assistant
        // content would appear in context and the store would have three
        // messages (user + old assistant + new assistant) instead of two.
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Better", " answer"]
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        // Seed: one user + one assistant message already in the store.
        let userMsg = ChatMessageRecord(role: .user, content: "original question", sessionID: sessionID)
        let assistantMsg = ChatMessageRecord(role: .assistant, content: "old answer", sessionID: sessionID)
        try await store.insertMessage(userMsg)
        try await store.insertMessage(assistantMsg)

        let input = RegenerateInput(sessionID: sessionID)
        _ = try await runtime.regenerate(input)

        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        // Old assistant gone; new one persisted — store has user + new assistant.
        XCTAssertEqual(store.messages.count, 2, "Old assistant removed, new assistant inserted")
        let stored = Array(store.messages.values).sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(stored[0].role, .user, "User message preserved")
        XCTAssertEqual(stored[0].content, "original question")
        XCTAssertEqual(stored[1].role, .assistant, "Fresh assistant message persisted")
        XCTAssertEqual(stored[1].content, "Better answer", "New content from stream")
        XCTAssertNotEqual(stored[1].id, assistantMsg.id, "New assistant has a fresh ID")

        // `.messageRemoved` fires with the old assistant's ID.
        XCTAssertTrue(events.contains(where: {
            if case .messageRemoved(let id) = $0 { return id == assistantMsg.id } else { return false }
        }), "messageRemoved fires with the old assistant message ID")

        // `.beforeContextAssembly` fires with nil prompt.
        XCTAssertTrue(events.contains(where: {
            if case .beforeContextAssembly(let prompt, _) = $0 { return prompt == nil } else { return false }
        }), "beforeContextAssembly fires with nil prompt for regenerate")

        // Standard generation events present.
        let kinds = events.map(eventKind)
        XCTAssertTrue(kinds.contains("contextAssembled"), "contextAssembled fires")
        XCTAssertTrue(kinds.contains("streamStarted"), "streamStarted fires")
        XCTAssertTrue(kinds.contains("messageInserted-assistant"), "New assistant messageInserted fires")
        XCTAssertTrue(kinds.contains("streamFinished-stop"), "streamFinished-stop fires")
        XCTAssertTrue(kinds.contains("afterGeneration"), "afterGeneration fires")

        // `.messageRemoved` must appear before `.streamStarted` — deletion
        // happens synchronously before the detached task launches.
        let removedIndex = kinds.firstIndex { $0.hasPrefix("messageRemoved") }
        let startedIndex = kinds.firstIndex { $0 == "streamStarted" }
        XCTAssertNotNil(removedIndex, "messageRemoved present")
        XCTAssertNotNil(startedIndex, "streamStarted present")
        if let r = removedIndex, let s = startedIndex {
            XCTAssertLessThan(r, s, "messageRemoved precedes streamStarted")
        }
    }

    // MARK: - Regenerate: no assistant message

    func test_regenerate_noAssistantMessage_throws() async throws {
        // Sabotage check (verified manually): removing the guard that checks
        // for a last assistant message causes the test to pass without
        // throwing, failing the XCTAssertThrowsError assertion.
        let (runtime, store, _, _) = makeRuntime()
        let sessionID = UUID()

        // Only a user message — no assistant to replace.
        let userMsg = ChatMessageRecord(role: .user, content: "hello", sessionID: sessionID)
        try await store.insertMessage(userMsg)

        do {
            _ = try await runtime.regenerate(RegenerateInput(sessionID: sessionID))
            XCTFail("Expected ConversationError.noAssistantMessageToRegenerate to be thrown")
        } catch let error as ConversationError {
            if case .noAssistantMessageToRegenerate = error {
                // Expected.
            } else {
                XCTFail("Expected .noAssistantMessageToRegenerate, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Store is untouched — only the original user message.
        XCTAssertEqual(store.messages.count, 1, "Store unchanged when no assistant exists")
    }

    // MARK: - Regenerate: empty session (also no assistant)

    func test_regenerate_emptySession_throws() async throws {
        let (runtime, store, _, _) = makeRuntime()
        let sessionID = UUID()

        do {
            _ = try await runtime.regenerate(RegenerateInput(sessionID: sessionID))
            XCTFail("Expected ConversationError.noAssistantMessageToRegenerate to be thrown")
        } catch let error as ConversationError {
            if case .noAssistantMessageToRegenerate = error {
                // Expected.
            } else {
                XCTFail("Expected .noAssistantMessageToRegenerate, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(store.messages.count, 0, "Store still empty")
    }

    // MARK: - Regenerate: delete persistence failure

    func test_regenerate_deleteFails_throwsBeforeEmittingMessageRemoved() async throws {
        // Sabotage check (verified manually): removing the guard that re-throws
        // the delete error causes `regenerate` to return a handle instead of
        // throwing, failing the XCTAssertThrowsError check and the assertion
        // that no messageRemoved event was emitted.
        let (runtime, store, _, _) = makeRuntime()
        let sessionID = UUID()

        let userMsg = ChatMessageRecord(role: .user, content: "q", sessionID: sessionID)
        let assistantMsg = ChatMessageRecord(role: .assistant, content: "a", sessionID: sessionID)
        try await store.insertMessage(userMsg)
        try await store.insertMessage(assistantMsg)

        // Poison the store's delete so it throws.
        store.deleteError = ChatPersistenceError.messageNotFound(assistantMsg.id)

        do {
            _ = try await runtime.regenerate(RegenerateInput(sessionID: sessionID))
            XCTFail("Expected ConversationError.persistence to be thrown")
        } catch let error as ConversationError {
            if case .persistence = error {
                // Expected.
            } else {
                XCTFail("Expected .persistence, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // `.messageRemoved` must NOT have been emitted — the throw happened
        // before the emit. `runtime.events` is an unbounded AsyncStream; any
        // event emitted before this point is already in the buffer. Start a
        // collector, sleep briefly to let the buffer drain, cancel the
        // collector, then read its partial result and assert it is empty.
        let eventTask = Task { @MainActor [runtime] in
            var seen: [ConversationEvent] = []
            for await event in runtime.events {
                seen.append(event)
            }
            return seen
        }
        try await Task.sleep(for: .milliseconds(50))
        eventTask.cancel()
        // Await the cancelled task — since it's non-throwing, this returns
        // whatever was collected before cancellation propagated.
        let seenEvents = await eventTask.value
        XCTAssertFalse(
            seenEvents.contains(where: { if case .messageRemoved = $0 { return true } else { return false } }),
            "messageRemoved must not be emitted when delete fails before the emit line"
        )
        // Store is untouched — both messages still present.
        XCTAssertEqual(store.messages.count, 2, "Store unchanged on delete failure")
    }

    // MARK: - Edit: happy path (user message)

    func test_edit_userMessage_happyPath_updatesAndRegenerates() async throws {
        // Sabotage check (verified manually): removing the `emit(.messageUpdated(...))`
        // call causes the `messageUpdated-user` assertion to fail. Removing the
        // trailing-deletion loop causes `messageRemoved` count to be 0 and
        // store.messages.count to be 3 instead of 2.
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Edited", " response"]
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        // Seed: user + assistant + a trailing assistant (simulates multi-turn).
        // Explicit timestamps ensure fetchMessages returns them in insertion order
        // regardless of same-millisecond Date() collisions in the in-memory store.
        let t0 = Date()
        let userMsg = ChatMessageRecord(role: .user, content: "original question", timestamp: t0, sessionID: sessionID)
        let assistantMsg1 = ChatMessageRecord(role: .assistant, content: "first answer", timestamp: t0.addingTimeInterval(1), sessionID: sessionID)
        let assistantMsg2 = ChatMessageRecord(role: .assistant, content: "follow-up", timestamp: t0.addingTimeInterval(2), sessionID: sessionID)
        try await store.insertMessage(userMsg)
        try await store.insertMessage(assistantMsg1)
        try await store.insertMessage(assistantMsg2)

        let input = EditInput(sessionID: sessionID, messageID: userMsg.id, newContent: "edited question")
        let handle = try await runtime.edit(input)

        XCTAssertNotNil(handle, "edit of a user message returns a stream handle")

        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        // Store: user message (updated) + new assistant. The two trailing messages
        // (assistantMsg1 + assistantMsg2) were deleted.
        XCTAssertEqual(store.messages.count, 2, "Trailing messages deleted; new assistant inserted")
        guard let updatedUser = store.messages[userMsg.id] else {
            XCTFail("User message missing from store")
            return
        }
        XCTAssertEqual(updatedUser.content, "edited question", "User message content updated in store")

        let assistants = store.messages.values.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1, "Exactly one assistant message after edit")
        XCTAssertEqual(assistants.first?.content, "Edited response", "New assistant content from stream")

        // Event ordering checks.
        let kinds = events.map(eventKind)

        // messageUpdated fires first.
        XCTAssertEqual(kinds.first, "messageUpdated-user",
                       "First event is messageUpdated for the edited user message")

        // Two messageRemoved events (one per trailing assistant message).
        let removedCount = kinds.filter { $0.hasPrefix("messageRemoved") }.count
        XCTAssertEqual(removedCount, 2, "Two trailing messages removed")

        // Generation events present.
        XCTAssertTrue(kinds.contains("beforeContextAssembly"), "beforeContextAssembly fires")
        XCTAssertTrue(kinds.contains("contextAssembled"), "contextAssembled fires")
        XCTAssertTrue(kinds.contains("streamStarted"), "streamStarted fires")
        XCTAssertGreaterThanOrEqual(kinds.filter { $0.hasPrefix("tokenEmitted") }.count, 1,
                                    "At least one tokenEmitted event fires")
        XCTAssertTrue(kinds.contains("messageInserted-assistant"), "New assistant messageInserted fires")
        XCTAssertTrue(kinds.contains("streamFinished-stop"), "streamFinished-stop fires")
        XCTAssertTrue(kinds.contains("afterGeneration"), "afterGeneration fires")

        // messageUpdated precedes streamStarted.
        let updatedIndex = kinds.firstIndex { $0.hasPrefix("messageUpdated") }
        let startedIndex = kinds.firstIndex { $0 == "streamStarted" }
        if let u = updatedIndex, let s = startedIndex {
            XCTAssertLessThan(u, s, "messageUpdated precedes streamStarted")
        } else {
            XCTFail("Expected both messageUpdated and streamStarted events")
        }

        // beforeContextAssembly fires with nil prompt (no new user text in edit).
        XCTAssertTrue(events.contains(where: {
            if case .beforeContextAssembly(let prompt, _) = $0 { return prompt == nil } else { return false }
        }), "beforeContextAssembly fires with nil prompt for edit")
    }

    // MARK: - Edit: assistant message (no generation)

    func test_edit_assistantMessage_updatesAndReturnsNilHandle() async throws {
        // Sabotage check (verified manually): changing the `guard updatedMessage.role == .user`
        // condition to always trigger generation causes the method to return a non-nil
        // handle, failing the XCTAssertNil assertion.
        let (runtime, store, _, _) = makeRuntime()

        let sessionID = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let userMsg = ChatMessageRecord(role: .user, content: "question", timestamp: base, sessionID: sessionID)
        let assistantMsg = ChatMessageRecord(role: .assistant, content: "original answer", timestamp: base.addingTimeInterval(1), sessionID: sessionID)
        try await store.insertMessage(userMsg)
        try await store.insertMessage(assistantMsg)

        let input = EditInput(sessionID: sessionID, messageID: assistantMsg.id, newContent: "corrected answer")
        let handle = try await runtime.edit(input)

        XCTAssertNil(handle, "Editing an assistant message returns nil handle (no generation)")

        // Collect any events that fired synchronously — should have messageUpdated, no generation events.
        let eventTask = Task { @MainActor [runtime] in
            var seen: [ConversationEvent] = []
            for await event in runtime.events {
                seen.append(event)
            }
            return seen
        }
        try await Task.sleep(for: .milliseconds(50))
        eventTask.cancel()

        // Store: user + updated assistant. No deletions (nothing trails the assistant).
        XCTAssertEqual(store.messages.count, 2, "Both messages still in store")
        guard let updatedAssistant = store.messages[assistantMsg.id] else {
            XCTFail("Assistant message missing from store")
            return
        }
        XCTAssertEqual(updatedAssistant.content, "corrected answer", "Assistant content updated in store")
    }

    // MARK: - Edit: message not found

    func test_edit_messageNotFound_throws() async throws {
        // Sabotage check (verified manually): removing the guard that throws
        // `.messageNotFound` causes the method to not throw, failing the
        // XCTAssertThrowsError check and the store-count assertion.
        let (runtime, store, _, _) = makeRuntime()
        let sessionID = UUID()

        let userMsg = ChatMessageRecord(role: .user, content: "hello", sessionID: sessionID)
        try await store.insertMessage(userMsg)

        let bogusID = UUID()
        let input = EditInput(sessionID: sessionID, messageID: bogusID, newContent: "replacement")

        do {
            _ = try await runtime.edit(input)
            XCTFail("Expected ConversationError.messageNotFound to be thrown")
        } catch let error as ConversationError {
            if case .messageNotFound(let id) = error {
                XCTAssertEqual(id, bogusID, "messageNotFound carries the bogus message ID")
            } else {
                XCTFail("Expected .messageNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Store unchanged — only the original user message.
        XCTAssertEqual(store.messages.count, 1, "Store unchanged when message not found")
    }

    // MARK: - Edit: update failure

    func test_edit_updateFails_throwsBeforeAnyDeletionOrGeneration() async throws {
        // Sabotage check (verified manually): removing the persistence re-throw on
        // updateMessage failure causes the method to proceed to deletion, and
        // store.messages.count drops from 2 to 1 — the trailing-message deletion
        // count assertion would fail.
        let (runtime, store, _, _) = makeRuntime()
        let sessionID = UUID()

        let userMsg = ChatMessageRecord(role: .user, content: "q", sessionID: sessionID)
        let assistantMsg = ChatMessageRecord(role: .assistant, content: "a", sessionID: sessionID)
        try await store.insertMessage(userMsg)
        try await store.insertMessage(assistantMsg)

        // Poison the update so it throws.
        store.updateError = ChatPersistenceError.messageNotFound(userMsg.id)

        do {
            _ = try await runtime.edit(EditInput(sessionID: sessionID, messageID: userMsg.id, newContent: "edited"))
            XCTFail("Expected ConversationError.persistence to be thrown")
        } catch let error as ConversationError {
            if case .persistence = error {
                // Expected.
            } else {
                XCTFail("Expected .persistence, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Store untouched — both messages still present.
        XCTAssertEqual(store.messages.count, 2, "Store unchanged when update fails")
    }

    // MARK: - Edit: delete failure on first trailing message

    func test_edit_firstDeleteFails_throwsBeforeAnyTrailingDeletion() async throws {
        // Sabotage check (verified manually): removing the re-throw on deleteMessage
        // failure causes the method to continue deleting and return a handle, failing
        // the XCTAssertThrowsError check.
        //
        // RuntimeMessageStore.deleteError fires on the next call then self-clears.
        // Setting it here means the first delete call (for trailing1) throws immediately,
        // so zero trailing messages are removed. The update commits before the delete
        // loop runs, so .messageUpdated is emitted and the store reflects the new
        // content even though the throw follows.
        let (runtime, store, _, _) = makeRuntime()
        let sessionID = UUID()

        let userMsg = ChatMessageRecord(role: .user, content: "q", sessionID: sessionID)
        let trailing1 = ChatMessageRecord(role: .assistant, content: "t1", sessionID: sessionID)
        let trailing2 = ChatMessageRecord(role: .assistant, content: "t2", sessionID: sessionID)
        try await store.insertMessage(userMsg)
        try await store.insertMessage(trailing1)
        try await store.insertMessage(trailing2)

        // Collect events so we can verify .messageUpdated fired before the
        // delete failure and that no .messageRemoved events were emitted.
        var collectedEvents: [ConversationEvent] = []
        let eventCollector = Task { @MainActor [runtime] in
            for await event in runtime.events {
                collectedEvents.append(event)
            }
        }

        // Poison: first delete call throws, leaving both trailing messages in place.
        store.deleteError = ChatPersistenceError.messageNotFound(trailing1.id)

        do {
            _ = try await runtime.edit(EditInput(sessionID: sessionID, messageID: userMsg.id, newContent: "edited"))
            XCTFail("Expected ConversationError.persistence to be thrown")
        } catch let error as ConversationError {
            if case .persistence = error {
                // Expected.
            } else {
                XCTFail("Expected .persistence, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Let any queued events drain.
        try await Task.sleep(for: .milliseconds(50))
        eventCollector.cancel()

        // The update committed before the delete attempt: store has user (with new
        // content) + both trailing messages (neither was deleted).
        XCTAssertEqual(store.messages.count, 3,
                       "Both trailing messages still in store when first delete fails")
        XCTAssertEqual(store.messages[userMsg.id]?.content, "edited",
                       "User message content was updated before the delete failure")

        // .messageUpdated fired — the update completed before the delete loop ran.
        XCTAssertTrue(collectedEvents.contains(where: {
            if case .messageUpdated(let record) = $0 { return record.id == userMsg.id } else { return false }
        }), ".messageUpdated fired for the edited message before the delete failure")

        // No .messageRemoved events — the first delete threw before anything was removed.
        let removedCount = collectedEvents.filter { event in
            if case .messageRemoved = event { return true } else { return false }
        }.count
        XCTAssertEqual(removedCount, 0, "No .messageRemoved events when first delete fails")
    }

    // MARK: - Branch: happy path (no generation)

    func test_branch_copiesMessagesAndEmitsEvent() async throws {
        // Sabotage check (verified manually): removing the `emit(.sessionBranched(...))`
        // call causes the `sessionBranched` assertion to fail. Changing the slice
        // to exclude the branch point message causes `copiedCount` to be 1
        // instead of 2, failing the count assertions.
        let (runtime, store, _, sessions) = makeRuntime(sessionStore: RuntimeSessionStore())
        let sessionID = UUID()
        let newSessionID = UUID()

        // Seed: user + assistant + user (branch at assistant, index 1).
        // Explicit timestamps ensure stable sort ordering in the in-memory store.
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let msg0 = ChatMessageRecord(role: .user, content: "question", timestamp: base, sessionID: sessionID)
        let msg1 = ChatMessageRecord(role: .assistant, content: "answer", timestamp: base.addingTimeInterval(1), sessionID: sessionID)
        let msg2 = ChatMessageRecord(role: .user, content: "follow-up", timestamp: base.addingTimeInterval(2), sessionID: sessionID)
        try await store.insertMessage(msg0)
        try await store.insertMessage(msg1)
        try await store.insertMessage(msg2)

        // Insert the source session so touchSession / title lookup works.
        let sourceSession = ChatSessionRecord(id: sessionID, title: "Source Chat")
        try await sessions!.insertSession(sourceSession)

        let input = BranchInput(
            sourceSessionID: sessionID,
            branchMessageID: msg1.id,   // branch at the assistant (index 1, inclusive)
            newSessionID: newSessionID,
            generateAfterBranch: false
        )
        let handle = try await runtime.branch(input)

        XCTAssertNil(handle, "branch returns nil when generateAfterBranch is false")

        // Collect any synchronously-queued events.
        let eventTask = Task { @MainActor [runtime] in
            var seen: [ConversationEvent] = []
            for await event in runtime.events { seen.append(event) }
            return seen
        }
        try await Task.sleep(for: .milliseconds(50))
        eventTask.cancel()
        let seenEvents = await eventTask.value

        // .sessionBranched fires with the correct newSessionID and copiedCount == 2.
        let branchedEvent = seenEvents.first {
            if case let .sessionBranched(sid, count) = $0 {
                return sid == newSessionID && count == 2
            }
            return false
        }
        XCTAssertNotNil(branchedEvent, "sessionBranched(newSessionID:, copiedCount: 2) fires")

        // New session has exactly 2 messages (msg0 + msg1 copies).
        let newMessages = try await store.fetchMessages(for: newSessionID)
        XCTAssertEqual(newMessages.count, 2, "New session has 2 copied messages")
        XCTAssertEqual(newMessages[0].role, .user)
        XCTAssertEqual(newMessages[0].content, "question")
        XCTAssertEqual(newMessages[1].role, .assistant)
        XCTAssertEqual(newMessages[1].content, "answer")
        // Copies have fresh IDs.
        XCTAssertNotEqual(newMessages[0].id, msg0.id, "Copied message has a fresh ID")
        XCTAssertNotEqual(newMessages[1].id, msg1.id, "Copied message has a fresh ID")

        // Source session is untouched.
        let sourceMessages = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(sourceMessages.count, 3, "Source session unchanged")
    }

    // MARK: - Branch: generation triggered when last copied message is user

    func test_branch_triggersGenerationWhenLastCopiedMessageIsUser() async throws {
        // Sabotage check (verified manually): changing `slice.last?.role == .user`
        // to always return false causes the handle to be nil, failing XCTAssertNotNil.
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Branch", " response"]
        let sessionStore = RuntimeSessionStore()
        let (runtime, store, _, _) = makeRuntime(mock: mock, sessionStore: sessionStore)

        let sessionID = UUID()
        let newSessionID = UUID()

        // Seed: user + assistant + user (branch at last user — index 2).
        // Explicit timestamps ensure stable sort ordering in the in-memory store.
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let msg0 = ChatMessageRecord(role: .user, content: "first", timestamp: base, sessionID: sessionID)
        let msg1 = ChatMessageRecord(role: .assistant, content: "reply", timestamp: base.addingTimeInterval(1), sessionID: sessionID)
        let msg2 = ChatMessageRecord(role: .user, content: "second", timestamp: base.addingTimeInterval(2), sessionID: sessionID)
        try await store.insertMessage(msg0)
        try await store.insertMessage(msg1)
        try await store.insertMessage(msg2)
        let sourceSession = ChatSessionRecord(id: sessionID, title: "Source")
        try await sessionStore.insertSession(sourceSession)

        let input = BranchInput(
            sourceSessionID: sessionID,
            branchMessageID: msg2.id,   // branch at the last user message
            newSessionID: newSessionID,
            generateAfterBranch: true
        )
        let handle = try await runtime.branch(input)

        XCTAssertNotNil(handle, "branch returns a handle when generation is triggered")

        // Wait for generation to complete on the new session.
        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        // Generation events fired against the newSessionID.
        let streamStarted = events.first { event in
            if case .streamStarted = event { return true } else { return false }
        }
        XCTAssertNotNil(streamStarted, "streamStarted fires during branch generation")

        // New session now has 3 + 1 messages: 3 copied + 1 new assistant.
        let newMessages = try await store.fetchMessages(for: newSessionID)
        XCTAssertEqual(newMessages.count, 4, "New session has 3 copied + 1 generated assistant message")
        XCTAssertEqual(newMessages.last?.role, .assistant)
        XCTAssertEqual(newMessages.last?.content, "Branch response")
    }

    // MARK: - Branch: no generation when last copied message is assistant

    func test_branch_noGenerationWhenLastCopiedMessageIsAssistant() async throws {
        // Sabotage check (verified manually): removing the `slice.last?.role == .user`
        // guard causes generation to trigger even on an assistant-terminated branch,
        // returning a non-nil handle and failing XCTAssertNil.
        let (runtime, store, _, sessions) = makeRuntime(sessionStore: RuntimeSessionStore())
        let sessionID = UUID()
        let newSessionID = UUID()

        let base = Date(timeIntervalSinceReferenceDate: 0)
        let msg0 = ChatMessageRecord(role: .user, content: "q", timestamp: base, sessionID: sessionID)
        let msg1 = ChatMessageRecord(role: .assistant, content: "a", timestamp: base.addingTimeInterval(1), sessionID: sessionID)
        try await store.insertMessage(msg0)
        try await store.insertMessage(msg1)
        let sourceSession = ChatSessionRecord(id: sessionID, title: "Source")
        try await sessions!.insertSession(sourceSession)

        let input = BranchInput(
            sourceSessionID: sessionID,
            branchMessageID: msg1.id,   // last copied is assistant
            newSessionID: newSessionID,
            generateAfterBranch: true   // requested, but should be suppressed
        )
        let handle = try await runtime.branch(input)

        XCTAssertNil(handle, "nil handle when last copied message is assistant, even with generateAfterBranch: true")

        // New session has 2 copied messages; no generated assistant.
        let newMessages = try await store.fetchMessages(for: newSessionID)
        XCTAssertEqual(newMessages.count, 2, "Only copied messages present; no generated assistant")
    }

    // MARK: - Branch: message not found

    func test_branch_messageNotFound_throws() async throws {
        // Sabotage check (verified manually): removing the guard that throws
        // `.messageNotFound` causes the method to branch at a non-existent
        // point without throwing, failing the XCTFail check.
        let (runtime, store, _, _) = makeRuntime()
        let sessionID = UUID()

        let msg0 = ChatMessageRecord(role: .user, content: "hello", sessionID: sessionID)
        try await store.insertMessage(msg0)

        let bogusID = UUID()
        let input = BranchInput(
            sourceSessionID: sessionID,
            branchMessageID: bogusID,
            newSessionID: UUID()
        )

        do {
            _ = try await runtime.branch(input)
            XCTFail("Expected ConversationError.messageNotFound to be thrown")
        } catch let error as ConversationError {
            if case .messageNotFound(let id) = error {
                XCTAssertEqual(id, bogusID, "messageNotFound carries the bogus message ID")
            } else {
                XCTFail("Expected .messageNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Token batcher

    func test_runGenerationTurn_batchesTokens() async throws {
        // Sabotage check (verified manually): setting streamingBatchCharacterLimit
        // to 1 and streamingUpdateInterval to .zero causes the batcher to flush on
        // every token, so tokenEmitted fires 10 times and the assertion fails.
        //
        // With a generous character limit and a long interval the batcher only
        // flushes once at stream-end, so we see exactly one tokenEmitted event.
        let mock = MockInferenceBackend()
        // 10 single-character tokens — none individually hits 128 chars or 33 ms.
        mock.tokensToYield = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        let (runtime, _, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(
            sessionID: sessionID,
            userText: "go",
            streamingUpdateInterval: .seconds(3600),   // never flush on time
            streamingBatchCharacterLimit: 128           // never flush on char count (10 < 128)
        ))

        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        let tokenEvents = events.filter {
            if case .tokenEmitted = $0 { return true } else { return false }
        }
        // All 10 tokens were buffered; the interval is 1 hour and the char limit is 128,
        // so no mid-stream flush occurs. The single end-of-stream flush fires exactly one event.
        // Sabotage: setting streamingBatchCharacterLimit to 1 and interval to .zero causes
        // the batcher to flush on every token, yielding 10 events — the assertion fails.
        XCTAssertEqual(tokenEvents.count, 1,
                       "Batcher coalesces all 10 tokens into one end-of-stream flush")
    }

    // MARK: - Thinking events

    func test_runGenerationTurn_thinkingEvents() async throws {
        // Sabotage check (verified manually): removing the `.thinkingStarted` emit
        // in the runtime causes XCTAssertEqual(thinkingStartedCount, 1) to fail with 0.
        // Removing the signature passthrough causes XCTAssertEqual(signature, "sig-abc")
        // to fail with nil.
        let mock = MockInferenceBackend()
        // Use the multi-block API so the mock emits a .thinkingSignature event.
        mock.thinkingBlocksToYield = [["think", "ing"]]
        mock.signaturesPerThinkingBlock = ["sig-abc"]
        mock.tokensToYield = ["done"]
        let (runtime, _, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(
            sessionID: sessionID,
            userText: "think",
            thinkingStreamingUpdateInterval: .seconds(3600),   // force single end-flush
            thinkingStreamingBatchCharacterLimit: 128
        ))

        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        let kinds = events.map(eventKind)

        let thinkingStartedCount = kinds.filter { $0 == "thinkingStarted" }.count
        XCTAssertEqual(thinkingStartedCount, 1, "thinkingStarted fires exactly once per thinking block")

        let thinkingFinalizedCount = kinds.filter { $0 == "thinkingFinalized" }.count
        XCTAssertEqual(thinkingFinalizedCount, 1, "thinkingFinalized fires exactly once")

        // thinkingStarted precedes thinkingFinalized.
        let startIdx = kinds.firstIndex { $0 == "thinkingStarted" }
        let finalIdx = kinds.firstIndex { $0 == "thinkingFinalized" }
        if let s = startIdx, let f = finalIdx {
            XCTAssertLessThan(s, f, "thinkingStarted precedes thinkingFinalized")
        } else {
            XCTFail("Expected both thinkingStarted and thinkingFinalized events")
        }

        // Full thinking text and signature are present in the finalized event.
        let finalizedEvent = events.first {
            if case .thinkingFinalized = $0 { return true } else { return false }
        }
        guard case let .thinkingFinalized(_, text, signature) = finalizedEvent else {
            XCTFail("Expected a thinkingFinalized event")
            return
        }
        XCTAssertEqual(text, "thinking",
                       "thinkingFinalized carries the complete thinking text")
        XCTAssertEqual(signature, "sig-abc",
                       "thinkingFinalized round-trips the provider signature")
    }

    // MARK: - Loop detection

    func test_runGenerationTurn_loopDetection() async throws {
        // Sabotage check (verified manually): disabling loopDetectionEnabled
        // (or removing the shouldStopForLoop check) causes loopDetected to never
        // fire and the stream finishes with .stop instead of stopping early.
        //
        // GenerationStreamConsumer.shouldStopForLoop requires content.count >= 100
        // before calling RepetitionDetector. Use a 52-char unit repeated 2x (104 chars)
        // to satisfy the 2x detection path (>= 100 chars, unit >= 50 chars repeated twice).
        let repeatingUnit = String(repeating: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", count: 2)  // 52 chars
        let loopingText = String(repeating: repeatingUnit, count: 2)  // 104 chars — 2x repeat
        // Emit as a single token so the batcher flushes all content at once.
        let mock = MockInferenceBackend()
        mock.tokensToYield = [loopingText]
        let (runtime, _, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(
            sessionID: sessionID,
            userText: "loop",
            streamingUpdateInterval: .zero,     // flush immediately on every token
            streamingBatchCharacterLimit: 1,    // also flush immediately
            loopDetectionEnabled: true
        ))

        // Wait until streamFinished so we capture all events including loopDetected
        // (which fires before streamFinished in the runtime's event sequence).
        let events = try await collectEvents(from: runtime) { event in
            if case .streamFinished = event { return true }
            return false
        }

        let hasLoopDetected = events.contains {
            if case .loopDetected = $0 { return true } else { return false }
        }
        XCTAssertTrue(hasLoopDetected, "loopDetected fires when repetition pattern is found")

        // Stream ends — streamFinished is the collection-stop event so it's always present.
        let hasFinished = events.contains {
            if case .streamFinished = $0 { return true } else { return false }
        }
        XCTAssertTrue(hasFinished, "streamFinished fires after loop detection stops the stream")
    }

    // MARK: - Tool call

    func test_runGenerationTurn_toolCall() async throws {
        // Sabotage check (verified manually): removing the `.dispatchToolCall`
        // branch in runGenerationTurn causes toolCallRequested to never be emitted,
        // failing the XCTAssertTrue check.
        let call = ToolCall(id: "call-1", toolName: "search", arguments: "{\"q\":\"test\"}")
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["result"]
        mock.scriptedToolCalls = [call]
        let (runtime, _, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        _ = try await runtime.send(SendInput(sessionID: sessionID, userText: "search"))

        let events = try await collectEvents(from: runtime) { event in
            if case .afterGeneration = event { return true }
            return false
        }

        let toolCallEvent = events.first {
            if case .toolCallRequested = $0 { return true } else { return false }
        }
        XCTAssertNotNil(toolCallEvent, "toolCallRequested fires when backend emits a toolCall event")

        if case let .toolCallRequested(emittedCall) = toolCallEvent {
            XCTAssertEqual(emittedCall.id, call.id, "toolCallRequested carries the correct call ID")
            XCTAssertEqual(emittedCall.toolName, call.toolName, "toolCallRequested carries the correct tool name")
        }
    }

    /// Cancellation fires after a tool call has been received but before the
    /// stream closes. Without the `hasToolContent` guard, `accumulated` is
    /// empty so the old code silently dropped the assistant message —
    /// losing the tool calls from the transcript.
    ///
    /// Strategy: emit two tool-call delta sequences. The first (`.call`) fires
    /// immediately so `contentParts` has one toolCall before the gate holds.
    /// A `toolDeltaEmissionGate` pauses before the second entry, giving a
    /// cancel window. The runtime processes cancel while the first toolCall
    /// part is already in the assistant message.
    ///
    /// Sabotage check: revert the `|| hasToolContent` addition in the
    /// cancellation path of `ConversationTurnExecutor.runGenerationTurn`.
    /// The assertion `store.messages…count == 1` will flip to 0, confirming
    /// the test catches the regression.
    func test_cancel_toolOnlyTurn_persistsAssistantWithToolContent() async throws {
        let call1 = ToolCall(id: "tool-cancel-1", toolName: "lookup", arguments: "{}")
        let call2 = ToolCall(id: "tool-cancel-2", toolName: "fetch", arguments: "{}")
        let mock = MockInferenceBackend()
        // No visible text tokens. Two tool calls emitted as a delta sequence:
        // the first fires immediately; the second is held by the gate.
        mock.tokensToYield = []
        mock.scriptedToolCallDeltasPerTurn = [[
            .call(call1),
            .call(call2)
        ]]
        let gate = TokenEmissionGate()
        mock.toolDeltaEmissionGate = gate
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let handle = try await runtime.send(SendInput(
            sessionID: UUID(),
            userText: "tool-only cancel test"
        ))

        // Drain events on a background task; cancel as soon as we see
        // toolCallRequested (first call emitted), then release the gate
        // so the mock can finish its teardown.
        let drain = Task { @MainActor [runtime] in
            var events: [ConversationEvent] = []
            var didCancel = false
            for await event in runtime.events {
                events.append(event)
                if case .toolCallRequested = event, !didCancel {
                    didCancel = true
                    await runtime.cancel(handle)
                }
                if case .streamFinished = event { return events }
            }
            return events
        }

        // Advance twice: first permit lets call1 emit; after cancel propagates
        // the second let the mock's Task drain cleanly.
        await gate.advance()
        let events = try await waitForEvents(from: drain)
        await gate.release()

        XCTAssertEqual(streamFinishedReasons(in: events), [.cancelled],
                       "Tool-only cancel emits exactly one cancelled terminal")

        let assistantMessages = store.messages.values.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1,
                       "Assistant message with tool content must be persisted on cancellation")

        let toolCallParts = assistantMessages.first?.contentParts.filter {
            if case .toolCall = $0 { return true }
            return false
        } ?? []
        XCTAssertGreaterThanOrEqual(toolCallParts.count, 1,
                                    "Persisted assistant must carry at least the first tool call content part")
    }

    /// Stream errors after tool calls arrive but before any text token.
    /// The error path had the same `accumulated.isEmpty` gap — verify it
    /// also persists when `hasToolContent` is true.
    ///
    /// Sabotage check: revert the `|| hasToolContent` addition in the
    /// error path of `ConversationTurnExecutor.runGenerationTurn`.
    /// The assertion `store.messages…count == 1` will flip to 0.
    func test_streamError_toolOnlyTurn_persistsAssistantWithToolContent() async throws {
        let call = ToolCall(id: "tool-error-1", toolName: "fetch", arguments: "{}")
        let mock = MockInferenceBackend()
        mock.tokensToYield = []
        mock.scriptedToolCalls = [call]
        mock.shouldThrowInsideStream = InferenceError.inferenceFailure("network blip")
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "tool-only error test"))
        let events = try await collectUntilStreamFinished(from: runtime)

        XCTAssertEqual(streamFinishedReasons(in: events), [.stop],
                       "Stream error emits exactly one terminal event")

        let assistantMessages = store.messages.values.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1,
                       "Assistant message with tool content must be persisted on stream error")

        let toolCallParts = assistantMessages.first?.contentParts.filter {
            if case .toolCall = $0 { return true }
            return false
        } ?? []
        XCTAssertEqual(toolCallParts.count, 1,
                       "Persisted assistant must carry the tool call content part")
    }

    /// A stream that completes normally but yields only tool calls and no
    /// visible text. Without the `hasToolContent` guard the `emptyResponse`
    /// flag stays true and the message was dropped as an empty turn.
    ///
    /// Sabotage check: revert the `&& !hasToolContent` addition in the
    /// `emptyResponse` branch of `ConversationTurnExecutor.runGenerationTurn`.
    /// The assertion `store.messages…count == 1` will flip to 0.
    func test_normalCompletion_toolOnlyTurn_persistsAssistantWithToolContent() async throws {
        let call = ToolCall(id: "tool-normal-1", toolName: "calculate", arguments: "{\"x\":1}")
        let mock = MockInferenceBackend()
        mock.tokensToYield = []
        mock.scriptedToolCalls = [call]
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        _ = try await runtime.send(SendInput(sessionID: UUID(), userText: "tool-only normal test"))
        let events = try await collectUntilStreamFinished(from: runtime)

        XCTAssertEqual(streamFinishedReasons(in: events), [.stop],
                       "Tool-only normal completion finishes with .stop, not .empty")

        let assistantMessages = store.messages.values.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1,
                       "Assistant message with tool content must be persisted on normal completion")

        let toolCallParts = assistantMessages.first?.contentParts.filter {
            if case .toolCall = $0 { return true }
            return false
        } ?? []
        XCTAssertEqual(toolCallParts.count, 1,
                       "Persisted assistant must carry the tool call content part")
    }

    // MARK: - Branch: insertSession fails

    func test_branch_insertSessionFails_throwsBeforeAnyMessagesCopied() async throws {
        // Sabotage check (verified manually): removing the re-throw on insertSession
        // failure causes the method to continue copying messages, so newMessages
        // would have content and the store.messages.count would increase.
        let sessionStore = RuntimeSessionStore()
        let (runtime, store, _, _) = makeRuntime(sessionStore: sessionStore)
        let sessionID = UUID()
        let newSessionID = UUID()

        let base = Date(timeIntervalSinceReferenceDate: 0)
        let msg0 = ChatMessageRecord(role: .user, content: "q", timestamp: base, sessionID: sessionID)
        let msg1 = ChatMessageRecord(role: .assistant, content: "a", timestamp: base.addingTimeInterval(1), sessionID: sessionID)
        try await store.insertMessage(msg0)
        try await store.insertMessage(msg1)

        // Poison: insertSession throws.
        sessionStore.insertError = ChatPersistenceError.providerNotConfigured

        do {
            _ = try await runtime.branch(BranchInput(
                sourceSessionID: sessionID,
                branchMessageID: msg0.id,
                newSessionID: newSessionID
            ))
            XCTFail("Expected ConversationError.persistence to be thrown")
        } catch let error as ConversationError {
            if case .persistence = error {
                // Expected.
            } else {
                XCTFail("Expected .persistence, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // No messages were copied into the new session.
        let newMessages = try await store.fetchMessages(for: newSessionID)
        XCTAssertEqual(newMessages.count, 0, "No messages copied when insertSession fails")
        // Source unchanged.
        XCTAssertEqual(store.messages.count, 2, "Source session messages unchanged")
    }

    // MARK: - Regenerate: cancel mid-stream

    func test_regenerate_cancelMidStream_partialContentPersists() async throws {
        // Sabotage check (verified manually): if cancel is ignored and the
        // stream drains fully, store.messages[assistant].content == "one two"
        // (both tokens), and `sawCancelled` remains false — both XCTAssert
        // calls would fail.
        //
        // Determinism: ConversationRuntime.events is a single-consumer
        // unbounded stream. The previous shape used two separate iterators
        // (one to trigger cancel, one to wait for streamFinished) and let
        // the mock fire all tokens into the unbounded buffer before cancel
        // had a chance to land — which sometimes produced
        // `.streamFinished(.stop)` instead of `.streamFinished(.cancelled)`.
        // We now drive the mock's token emission via a `TokenEmissionGate`
        // and drain `runtime.events` from a single task. Token 1 is released
        // first; token 2 is released only after we observe `.tokenEmitted`
        // and issue cancel — by which point the runtime's drain loop sees
        // `cancelled = true` on its next iteration and breaks.
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["one", " two"]
        let gate = TokenEmissionGate()
        mock.tokenEmissionGate = gate
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        let userMsg = ChatMessageRecord(role: .user, content: "q", sessionID: sessionID)
        let assistantMsg = ChatMessageRecord(role: .assistant, content: "old", sessionID: sessionID)
        try await store.insertMessage(userMsg)
        try await store.insertMessage(assistantMsg)

        // Use a tiny batch limit so each token flushes immediately, allowing
        // the cancel to fire before the stream drains completely.
        let handle = try await runtime.regenerate(RegenerateInput(
            sessionID: sessionID,
            streamingBatchCharacterLimit: 1
        ))

        // Single-consumer drain. We trigger cancel inline the moment we
        // observe the first `.tokenEmitted`, then continue draining until
        // the terminal `.streamFinished` arrives.
        var sawCancelled = false
        let drain = Task { @MainActor [runtime] in
            var cancelled = false
            for await event in runtime.events {
                switch event {
                case .tokenEmitted:
                    if !cancelled {
                        cancelled = true
                        await runtime.cancel(handle)
                        // Release the gate so the mock's emission task can
                        // observe its own `Task.isCancelled` (or yield the
                        // remaining tokens, which the runtime drops because
                        // it has already broken out of its drain loop).
                        await gate.release()
                    }
                case .streamFinished(_, let reason):
                    if reason == .cancelled { sawCancelled = true }
                    return
                default:
                    break
                }
            }
        }

        // Release token 1 to start the stream flowing.
        await gate.advance()

        // Bound the wait so a regression cannot hang CI for the full XCTest
        // default timeout. 5 s is generous; happy-path is sub-50ms.
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await drain.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                drain.cancel()
            }
            try await group.next()
            group.cancelAll()
        }
        // Always release pending waiters so the mock's emission task does
        // not strand if the test bailed out via the timeout branch.
        await gate.release()

        XCTAssertTrue(sawCancelled, "Cancel propagates to .streamFinished(reason: .cancelled)")
        // User message present; old assistant gone; partial assistant may exist.
        let userCount = store.messages.values.filter { $0.role == .user }.count
        XCTAssertEqual(userCount, 1, "User message preserved")
        let oldAssistantStillPresent = store.messages[assistantMsg.id] != nil
        XCTAssertFalse(oldAssistantStillPresent, "Old assistant message was deleted before stream start")
    }
}
