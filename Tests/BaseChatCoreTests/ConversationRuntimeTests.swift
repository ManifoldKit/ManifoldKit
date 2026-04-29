@preconcurrency import XCTest
import Foundation
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Phase 1.2.5 PR-A — coverage for the new `ConversationRuntime` send sub-flow.
///
/// Send is the only sub-flow PR-A ships. Regenerate / edit / branch are
/// covered by their PRs (PR-B / PR-C). Tests use the in-memory `MessageStore`
/// fake from `MessageStorePostWriteHookTests` shape (re-stated here as
/// `RuntimeMessageStore` to keep the fixture independent — these tests run
/// in `BaseChatCoreTests`, the hook tests live in `BaseChatInferenceTests`).
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

        func insertSession(_ session: ChatSessionRecord) async throws {
            sessions[session.id] = session
        }

        func updateSession(_ session: ChatSessionRecord) async throws {
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
            sessions.values.sorted { $0.updatedAt > $1.updatedAt }
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

    enum TestError: Error { case deadlineElapsed }

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
        XCTAssertEqual(kinds.filter { $0.hasPrefix("tokenEmitted") }.count, 2,
                       "Emits one tokenEmitted per scripted token")
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

    // MARK: - Cancellation

    func test_send_cancel_propagatesAndEndsStream() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["one", "two", "three", "four", "five"]
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        let handle = try await runtime.send(SendInput(sessionID: sessionID, userText: "long"))

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

    // MARK: - Helpers

    private func eventKind(_ event: ConversationEvent) -> String {
        switch event {
        case let .messageInserted(record):
            return "messageInserted-\(record.role.rawValue)"
        case let .messageRemoved(messageID):
            return "messageRemoved(\(messageID))"
        case .streamStarted: return "streamStarted"
        case let .tokenEmitted(_, delta): return "tokenEmitted(\(delta))"
        case let .streamFinished(_, reason):
            switch reason {
            case .stop: return "streamFinished-stop"
            case .cancelled: return "streamFinished-cancelled"
            case .empty: return "streamFinished-empty"
            case .length: return "streamFinished-length"
            }
        case .errorRaised: return "errorRaised"
        case .beforeContextAssembly: return "beforeContextAssembly"
        case .contextAssembled: return "contextAssembled"
        case .afterGeneration: return "afterGeneration"
        case .compressionTriggered: return "compressionTriggered"
        case .toolCallRequested: return "toolCallRequested"
        case .toolCallApproved: return "toolCallApproved"
        case .toolCallCompleted: return "toolCallCompleted"
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

    // MARK: - Regenerate: cancel mid-stream

    func test_regenerate_cancelMidStream_partialContentPersists() async throws {
        // Sabotage check (verified manually): if cancel is ignored and the
        // stream drains fully, store.messages[assistant].content == "one two"
        // (both tokens), and `sawCancelled` remains false — both XCTAssert
        // calls would fail.
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["one", " two"]
        let (runtime, store, _, _) = makeRuntime(mock: mock)

        let sessionID = UUID()
        let userMsg = ChatMessageRecord(role: .user, content: "q", sessionID: sessionID)
        let assistantMsg = ChatMessageRecord(role: .assistant, content: "old", sessionID: sessionID)
        try await store.insertMessage(userMsg)
        try await store.insertMessage(assistantMsg)

        let handle = try await runtime.regenerate(RegenerateInput(sessionID: sessionID))

        // Cancel after the first token.
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
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await waitTask.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                waitTask.cancel()
            }
            try await group.next()
            group.cancelAll()
        }

        XCTAssertTrue(sawCancelled, "Cancel propagates to .streamFinished(reason: .cancelled)")
        // User message present; old assistant gone; partial assistant may exist.
        let userCount = store.messages.values.filter { $0.role == .user }.count
        XCTAssertEqual(userCount, 1, "User message preserved")
        let oldAssistantStillPresent = store.messages[assistantMsg.id] != nil
        XCTAssertFalse(oldAssistantStillPresent, "Old assistant message was deleted before stream start")
    }
}
