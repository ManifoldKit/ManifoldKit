import XCTest
import Foundation
@testable import BaseChatRuntime
@testable import BaseChatInference
import BaseChatTestSupport

/// I6 collapsed `SendInput` / `RegenerateInput` / `EditInput` / `BranchInput`
/// into a single ``TurnInput`` + ``TurnConfig`` + ``TurnKind`` triple.
///
/// These tests pin two contracts:
///
/// 1. **Round-trip parity**: each legacy `*Input` struct produces the same
///    observable event sequence whether the caller invokes the deprecated
///    `runtime.send(_:)` / `regenerate(_:)` / `edit(_:)` / `branch(_:)`
///    overloads or the canonical `runtime.processTurn(_:)` with the
///    matching ``TurnKind``.
/// 2. **Knob propagation**: the per-flow knobs encoded on ``TurnConfig``
///    reach the inner generation loop intact (proxied via the assistant
///    record produced by a finished turn).
@MainActor
final class TurnInputCollapseTests: XCTestCase {

    // MARK: - In-memory MessageStore (minimal — sibling to ConversationRuntimeTests')

    @MainActor
    final class MemoryStore: MessageStore {
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

    @MainActor
    final class MemorySessionStore: SessionStore {
        private(set) var sessions: [UUID: ChatSessionRecord] = [:]

        func insertSession(_ session: ChatSessionRecord) async throws {
            sessions[session.id] = session
        }

        func updateSession(_ session: ChatSessionRecord) async throws {
            guard sessions[session.id] != nil else {
                throw ChatPersistenceError.sessionNotFound(session.id)
            }
            sessions[session.id] = session
        }

        func deleteSession(_ sessionID: UUID) async throws {
            sessions.removeValue(forKey: sessionID)
        }

        func fetchSessions() async throws -> [ChatSessionRecord] {
            sessions.values.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        tokens: [String] = ["a", "b"],
        sessionStore: MemorySessionStore? = nil
    ) -> (ConversationRuntime, MemoryStore, MemorySessionStore?) {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = tokens
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = MemoryStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            sessionStore: sessionStore,
            inferenceService: inference,
            pipeline: nil
        )
        return (runtime, store, sessionStore)
    }

    enum DrainError: Error { case deadlineElapsed }

    private func drainUntilAfterGeneration(
        _ runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        var collected: [ConversationEvent] = []
        let collectTask = Task {
            for await event in runtime.events {
                collected.append(event)
                if case .afterGeneration = event { break }
                if case .streamFinished(_, let reason) = event, reason == .empty { break }
            }
            return collected
        }
        return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
            group.addTask { await collectTask.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                collectTask.cancel()
                throw DrainError.deadlineElapsed
            }
            let result = try await group.next()
            group.cancelAll()
            return result ?? []
        }
    }

    /// Reduces a transcript to a stable shape we can assert across two
    /// runs. We strip identifiers (UUIDs vary between runs) and message
    /// timestamps, leaving only the case discriminator and load-bearing
    /// payloads.
    private func eventShapes(_ events: [ConversationEvent]) -> [String] {
        events.map { event -> String in
            switch event {
            case let .messageInserted(record):
                return "messageInserted-\(record.role.rawValue)-\(record.content)"
            case .beforeContextAssembly:
                return "beforeContextAssembly"
            case .contextAssembled:
                return "contextAssembled"
            case .streamStarted:
                return "streamStarted"
            case let .tokenEmitted(_, delta):
                return "tokenEmitted-\(delta)"
            case let .streamFinished(_, reason):
                return "streamFinished-\(reason)"
            case let .afterGeneration(_, finalText):
                return "afterGeneration-\(finalText)"
            case .messageRemoved:
                return "messageRemoved"
            case .messageUpdated:
                return "messageUpdated"
            case .sessionBranched:
                return "sessionBranched"
            case .errorRaised:
                return "errorRaised"
            case .thinkingStarted:
                return "thinkingStarted"
            case .thinkingUpdated:
                return "thinkingUpdated"
            case .thinkingFinalized:
                return "thinkingFinalized"
            case .toolCallRequested:
                return "toolCallRequested"
            case .toolCallApproved:
                return "toolCallApproved"
            case .toolCallCompleted:
                return "toolCallCompleted"
            case .tokenUsageRecorded:
                return "tokenUsageRecorded"
            case .loopDetected:
                return "loopDetected"
            case .compressionTriggered:
                return "compressionTriggered"
            case .sessionTouchFailed:
                return "sessionTouchFailed"
            }
        }
    }

    // MARK: - Send round-trip

    func test_send_processTurn_matchesLegacySendInput() async throws {
        // Drive the canonical TurnInput path.
        let (runtimeNew, _, _) = makeRuntime()
        let sessionID = UUID()
        _ = try await runtimeNew.processTurn(
            TurnInput(sessionID: sessionID, kind: .send(text: "hi"))
        )
        let newEvents = try await drainUntilAfterGeneration(runtimeNew)

        // Drive the deprecated SendInput path and confirm the event-sequence
        // shape matches. Suppress deprecation warnings for the legacy struct
        // — that's the whole point of this test.
        let (runtimeLegacy, _, _) = makeRuntime()
        let legacyInput = legacySendInput(sessionID: sessionID, text: "hi")
        _ = try await runtimeLegacy.send(legacyInput)
        let legacyEvents = try await drainUntilAfterGeneration(runtimeLegacy)

        XCTAssertEqual(eventShapes(newEvents), eventShapes(legacyEvents),
                       "Canonical TurnInput.processTurn and legacy send(SendInput) must produce identical event sequences")
    }

    // MARK: - Regenerate round-trip

    func test_regenerate_processTurn_matchesLegacyRegenerateInput() async throws {
        // Seed each runtime with one user + assistant turn so regenerate has
        // something to replace. Run sequentially so the test class's MainActor
        // isolation isn't sent across an `async let` boundary.
        let canonical = try await drivePathA()
        let legacy = try await drivePathB()
        XCTAssertEqual(eventShapes(canonical), eventShapes(legacy),
                       "Canonical regenerate via processTurn(.regenerate) must mirror legacy regenerate(RegenerateInput)")
    }

    private func drivePathA() async throws -> [ConversationEvent] {
        let (runtime, _, _) = makeRuntime(tokens: ["second"])
        let sessionID = UUID()
        _ = try await runtime.processTurn(TurnInput(sessionID: sessionID, kind: .send(text: "hi")))
        _ = try await drainUntilAfterGeneration(runtime)
        _ = try await runtime.processTurn(TurnInput(sessionID: sessionID, kind: .regenerate))
        return try await drainUntilAfterGeneration(runtime)
    }

    private func drivePathB() async throws -> [ConversationEvent] {
        let (runtime, _, _) = makeRuntime(tokens: ["second"])
        let sessionID = UUID()
        _ = try await runtime.send(legacySendInput(sessionID: sessionID, text: "hi"))
        _ = try await drainUntilAfterGeneration(runtime)
        _ = try await runtime.regenerate(legacyRegenerateInput(sessionID: sessionID))
        return try await drainUntilAfterGeneration(runtime)
    }

    // MARK: - Edit round-trip

    func test_edit_processTurn_matchesLegacyEditInput() async throws {
        // Path A: canonical TurnInput.
        let (runtimeA, storeA, _) = makeRuntime()
        let sessionA = UUID()
        _ = try await runtimeA.processTurn(TurnInput(sessionID: sessionA, kind: .send(text: "first")))
        _ = try await drainUntilAfterGeneration(runtimeA)
        let userMsgA = try XCTUnwrap(storeA.messages.values.first { $0.role == .user })
        _ = try await runtimeA.processTurn(
            TurnInput(sessionID: sessionA, kind: .edit(messageID: userMsgA.id, text: "edited"))
        )
        let canonical = try await drainUntilAfterGeneration(runtimeA)

        // Path B: legacy EditInput.
        let (runtimeB, storeB, _) = makeRuntime()
        let sessionB = UUID()
        _ = try await runtimeB.send(legacySendInput(sessionID: sessionB, text: "first"))
        _ = try await drainUntilAfterGeneration(runtimeB)
        let userMsgB = try XCTUnwrap(storeB.messages.values.first { $0.role == .user })
        _ = try await runtimeB.edit(legacyEditInput(sessionID: sessionB, messageID: userMsgB.id, text: "edited"))
        let legacy = try await drainUntilAfterGeneration(runtimeB)

        XCTAssertEqual(eventShapes(canonical), eventShapes(legacy),
                       "Canonical edit via processTurn(.edit) must mirror legacy edit(EditInput)")
    }

    // MARK: - Branch round-trip

    func test_branch_processTurn_matchesLegacyBranchInput() async throws {
        // Both paths: send one user+assistant turn, then branch at the user
        // message with `generateAfter: true` so the new session also runs a
        // generation pass.

        // Path A: canonical TurnInput.
        let sessionsA = MemorySessionStore()
        let (runtimeA, storeA, _) = makeRuntime(sessionStore: sessionsA)
        let sourceA = UUID()
        try await sessionsA.insertSession(ChatSessionRecord(id: sourceA, title: "A"))
        _ = try await runtimeA.processTurn(TurnInput(sessionID: sourceA, kind: .send(text: "hello")))
        _ = try await drainUntilAfterGeneration(runtimeA)
        let userA = try XCTUnwrap(storeA.messages.values.first { $0.role == .user })
        let newSessionA = UUID()
        _ = try await runtimeA.processTurn(
            TurnInput(
                sessionID: sourceA,
                kind: .branch(messageID: userA.id, newSessionID: newSessionA, generateAfter: true)
            )
        )
        let canonical = try await drainUntilAfterGeneration(runtimeA)

        // Path B: legacy BranchInput.
        let sessionsB = MemorySessionStore()
        let (runtimeB, storeB, _) = makeRuntime(sessionStore: sessionsB)
        let sourceB = UUID()
        try await sessionsB.insertSession(ChatSessionRecord(id: sourceB, title: "B"))
        _ = try await runtimeB.send(legacySendInput(sessionID: sourceB, text: "hello"))
        _ = try await drainUntilAfterGeneration(runtimeB)
        let userB = try XCTUnwrap(storeB.messages.values.first { $0.role == .user })
        let newSessionB = UUID()
        _ = try await runtimeB.branch(
            legacyBranchInput(sourceSessionID: sourceB, branchMessageID: userB.id, newSessionID: newSessionB, generateAfterBranch: true)
        )
        let legacy = try await drainUntilAfterGeneration(runtimeB)

        XCTAssertEqual(eventShapes(canonical), eventShapes(legacy),
                       "Canonical branch via processTurn(.branch) must mirror legacy branch(BranchInput)")
    }

    // MARK: - TurnConfig knob propagation

    /// Sanity-check that custom TurnConfig values reach the runtime — the
    /// streaming-batcher knobs influence how tokens are coalesced. We pin
    /// the system prompt because that's the easiest knob to observe via the
    /// composeSystemPrompt path: the runtime forwards a non-nil systemPrompt
    /// onto the enqueue call, and a custom prompt threading through means
    /// the config was honoured.
    func test_turnConfig_systemPrompt_threadsToBackend() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["hi"]
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = MemoryStore()
        let runtime = ConversationRuntime(
            messageStore: store,
            inferenceService: inference,
            pipeline: nil
        )
        let sessionID = UUID()
        let pinned = "you are a unicorn"
        _ = try await runtime.processTurn(
            TurnInput(
                sessionID: sessionID,
                kind: .send(text: "hi"),
                config: TurnConfig(systemPrompt: pinned)
            )
        )
        _ = try await drainUntilAfterGeneration(runtime)
        XCTAssertEqual(backend.lastSystemPrompt, pinned,
                       "TurnConfig.systemPrompt must reach the backend's generate(prompt:systemPrompt:config:) call.")
    }

    // MARK: - Legacy struct construction (deprecation-suppressed)

    @available(*, deprecated)
    private func legacySendInput(sessionID: UUID, text: String) -> SendInput {
        SendInput(sessionID: sessionID, userText: text)
    }

    @available(*, deprecated)
    private func legacyRegenerateInput(sessionID: UUID) -> RegenerateInput {
        RegenerateInput(sessionID: sessionID)
    }

    @available(*, deprecated)
    private func legacyEditInput(sessionID: UUID, messageID: UUID, text: String) -> EditInput {
        EditInput(sessionID: sessionID, messageID: messageID, newContent: text)
    }

    @available(*, deprecated)
    private func legacyBranchInput(
        sourceSessionID: UUID,
        branchMessageID: UUID,
        newSessionID: UUID,
        generateAfterBranch: Bool
    ) -> BranchInput {
        BranchInput(
            sourceSessionID: sourceSessionID,
            branchMessageID: branchMessageID,
            newSessionID: newSessionID,
            generateAfterBranch: generateAfterBranch
        )
    }
}
