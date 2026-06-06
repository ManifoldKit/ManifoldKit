import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldRuntime

/// End-to-end handoff scenarios driven by a scripted ``MockInferenceBackend``
/// so the executor's swap + boundary + tagging behaviour is deterministic
/// without a real LLM in CI (per QA reviewer fix #2).
@MainActor
final class HandoffScenarioTests: XCTestCase {

    // MARK: - Stores

    final class InMemoryMessageStore: MessageStore {
        var messages: [UUID: ChatMessage] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []
        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
            for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
        }
        func updateMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
        }
        func deleteMessage(_ messageID: UUID) async throws { messages.removeValue(forKey: messageID) }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) { hooks.append(hook) }
    }

    final class InMemorySessionStore: SessionStore {
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

    // MARK: - Fixtures

    private func makeAgents() -> (researcher: Agent, writer: Agent) {
        (
            Agent(name: "Researcher", systemPrompt: "You are a Researcher.", description: "Gathers facts."),
            Agent(name: "Writer", systemPrompt: "You are a Writer.", description: "Drafts copy.")
        )
    }

    private struct ScenarioFixture {
        let runtime: ConversationRuntime
        let messageStore: InMemoryMessageStore
        let sessionStore: InMemorySessionStore
        let mock: MockInferenceBackend
        let sessionID: UUID
        let researcher: Agent
        let writer: Agent
    }

    private func makeFixture() async throws -> ScenarioFixture {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let inference = InferenceService(backend: mock, name: "Mock")
        let messageStore = InMemoryMessageStore()
        let sessionStore = InMemorySessionStore()
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: inference,
            pipeline: nil
        )

        let (researcher, writer) = makeAgents()
        let sessionID = UUID()
        let session = ChatSession(
            id: sessionID,
            title: "Handoff scenario",
            agents: [researcher, writer],
            activeAgentID: researcher.id
        )
        try await sessionStore.insertSession(session)

        return ScenarioFixture(
            runtime: runtime,
            messageStore: messageStore,
            sessionStore: sessionStore,
            mock: mock,
            sessionID: sessionID,
            researcher: researcher,
            writer: writer
        )
    }

    /// Collects events until either `.streamFinished` fires or the deadline
    /// elapses.
    private func collectUntilStreamFinished(
        from runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        var collected: [ConversationEvent] = []
        let task = Task {
            for await event in runtime.events {
                collected.append(event)
                if case .streamFinished = event { return collected }
            }
            return collected
        }
        return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw CocoaError(.userCancelled)
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? []
        }
    }

    // MARK: - Tests

    /// Full happy path: a `transfer_to_Writer` tool call emitted by the
    /// scripted backend triggers an `activeAgentID` swap, emits
    /// `.agentHandoff`, and (on the next turn) tags the persisted
    /// assistant message with the new agent's id.
    func test_handoff_swapsActiveAgent_andEmitsConversationEvent() async throws {
        let fx = try await makeFixture()
        // Script the backend to emit a transfer_to_Writer tool call.
        fx.mock.tokensToYield = []
        fx.mock.scriptedToolCalls = [
            ToolCall(id: "tc-1", toolName: "transfer_to_Writer", arguments: "{}")
        ]

        _ = try await fx.runtime.processTurn(TurnInput(sessionID: fx.sessionID, kind: .send(text: "find facts")))
        let events = try await collectUntilStreamFinished(from: fx.runtime)

        // Active agent persisted.
        let updated = fx.sessionStore.sessions[fx.sessionID]
        XCTAssertEqual(updated?.activeAgentID, fx.writer.id, "active agent should have swapped to Writer")

        // ConversationEvent.agentHandoff emitted with correct ids.
        let handoffEvents = events.compactMap { event -> (UUID?, UUID)? in
            if case let .agentHandoff(from, to) = event { return (from, to) } else { return nil }
        }
        XCTAssertEqual(handoffEvents.count, 1)
        XCTAssertEqual(handoffEvents.first?.0, fx.researcher.id)
        XCTAssertEqual(handoffEvents.first?.1, fx.writer.id)
        // Sabotage-evidence: M1 strip persistence.updateSession call → updated?.activeAgentID stays Researcher.
        // Sabotage-evidence: M2 drop emit(.agentHandoff) → handoffEvents empty.
        // Sabotage-evidence: M3 reverse from/to → tuple ordering mismatches.
    }

    /// After a handoff lands, the next turn's structured history carries a
    /// synthetic system-role boundary message describing the handoff. The
    /// mock backend records the last system prompt so we can also confirm
    /// the active agent's prompt is re-derived.
    func test_handoff_followUpTurn_injectsBoundaryAndReDerivesSystemPrompt() async throws {
        let fx = try await makeFixture()
        // Turn 1: emit the transfer.
        fx.mock.tokensToYield = []
        fx.mock.scriptedToolCalls = [
            ToolCall(id: "tc-1", toolName: "transfer_to_Writer", arguments: #"{"payload":"facts"}"#)
        ]
        _ = try await fx.runtime.processTurn(TurnInput(sessionID: fx.sessionID, kind: .send(text: "find facts")))
        _ = try await collectUntilStreamFinished(from: fx.runtime)

        // Turn 2: the executor should re-derive system prompt from Writer.
        // Clear scripted tool calls so this turn produces a regular text
        // response and we can inspect the last captured system prompt.
        fx.mock.scriptedToolCalls = []
        fx.mock.tokensToYield = ["Drafting"]
        _ = try await fx.runtime.processTurn(TurnInput(sessionID: fx.sessionID, kind: .send(text: "now write")))
        _ = try await collectUntilStreamFinished(from: fx.runtime)

        // System prompt should now be Writer's prompt (plus the synthesised
        // handoff-instructions block listing Researcher as a sibling).
        let lastSystem = fx.mock.lastSystemPrompt ?? ""
        XCTAssertTrue(lastSystem.contains("You are a Writer."), "Writer system prompt must be active; got: \(lastSystem)")
        XCTAssertTrue(lastSystem.contains("- Researcher:"), "Researcher should appear as a sibling in the handoff-instructions block; got: \(lastSystem)")
        // Sabotage-evidence: M1 drop activeAgent-derivation path → original config.systemPrompt sticks; "You are a Writer." absent.
        // Sabotage-evidence: M2 always list active in siblings → "- Writer:" appears (we don't assert against it explicitly but contains check still valid).
        // Sabotage-evidence: M3 swap handoffInstructions return to "" → "- Researcher:" check fails.
    }

    /// The agent count soft cap is informational — exceeding it still
    /// returns every transfer tool. Smoke-tests the source under the
    /// runtime path so the cap doesn't accidentally truncate behaviour.
    func test_handoff_softCapDoesNotTruncate_advertisedList() async {
        let active = Agent(name: "A", systemPrompt: "", description: "")
        let others = (0..<4).map { Agent(name: "Agent\($0)", systemPrompt: "", description: "") }
        let session = ChatSession(
            id: UUID(),
            title: "Big",
            agents: [active] + others,
            activeAgentID: active.id
        )
        let source = HandoffToolSource()
        let defs = await source.toolDefinitions(for: session)
        XCTAssertEqual(defs.count, 4)
        // Sabotage-evidence: M1 hard-cap to 3 → defs.count<4.
        // Sabotage-evidence: M2 include active → defs.count==5.
        // Sabotage-evidence: M3 return [] over cap → defs.empty.
    }
}
