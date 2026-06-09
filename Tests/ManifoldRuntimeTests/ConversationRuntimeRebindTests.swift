import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldRuntime

/// Exercises the per-turn rebind path: a host that built the runtime once
/// at app init can swap `sessionToolSources` / `hookRegistry` via the
/// `update*` mutators and the change takes effect on the *next* turn.
///
/// Closes the W3B/W4 deferral: the demo app's `DemoScenarioRunner` calls
/// these mutators before kicking off a scenario's prompt, swapping context
/// per scenario card without rebuilding the runtime.
@MainActor
final class ConversationRuntimeRebindTests: XCTestCase {

    // MARK: - Stores (shared shape with HandoffScenarioTests)

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

    /// Minimal `SessionToolSource` that surfaces a single fixed tool. Used
    /// to assert the executor's per-turn snapshot folds the source's
    /// contributions into the advertised list when bindings are populated,
    /// and drops them when the binding is cleared.
    struct StubToolSource: SessionToolSource {
        let toolName: String
        func toolDefinitions(for session: ChatSession) async -> [ToolDefinition] {
            [ToolDefinition(name: toolName, description: "stub", parameters: .object([:]))]
        }
        func resolve(toolName: String, arguments: String, session: ChatSession) async throws -> ToolResult {
            ToolResult(callId: "", content: "")
        }
    }

    private struct Fixture {
        let runtime: ConversationRuntime
        let mock: MockInferenceBackend
        let messageStore: InMemoryMessageStore
        let sessionStore: InMemorySessionStore
        let sessionID: UUID
    }

    private func makeFixture(
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil
    ) async throws -> Fixture {
        // Tool-capable capabilities: the executor's union of registry +
        // sessionToolSources can produce a non-empty `tools` list, and
        // `GenerationQueue.enqueue` throws if `tools.isEmpty == false`
        // while the backend reports `supportsToolCalling == false`. The
        // rebind path is a no-op on a backend that can't carry tools.
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        ))
        mock.isModelLoaded = true
        // Yield a single token per turn so the executor runs the happy
        // path (assistant message persisted) rather than the empty-response
        // drop path — the drop branch still emits streamFinished but
        // observability is cleaner when we keep both turns symmetric.
        mock.tokensToYield = ["ok"]
        let inference = InferenceService(backend: mock, name: "Mock")
        let messageStore = InMemoryMessageStore()
        let sessionStore = InMemorySessionStore()
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: inference,
            pipeline: nil,
            sessionToolSources: sessionToolSources,
            hookRegistry: hookRegistry
        )
        let sessionID = UUID()
        try await sessionStore.insertSession(
            ChatSession(id: sessionID, title: "Rebind")
        )
        return Fixture(
            runtime: runtime,
            mock: mock,
            messageStore: messageStore,
            sessionStore: sessionStore,
            sessionID: sessionID
        )
    }

    /// Collects events until either `.streamFinished` fires or the deadline
    /// elapses. Mirrors the helper in ``HandoffScenarioTests`` so the two
    /// suites stay shape-compatible.
    private func collectUntilStreamFinished(
        from runtime: ConversationRuntime,
        deadline: Duration = .seconds(5)
    ) async throws -> [ConversationEvent] {
        let task = Task {
            var collected: [ConversationEvent] = []
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

    /// Polls the bag until at least `atLeast` `.streamFinished` events have
    /// been observed. Used by `test_updateHookRegistry_takesEffectOnNextTurn`
    /// to demarcate turn boundaries on a single shared event collector.
    private func waitForStreamFinishedCount(
        _ bag: EventBag,
        atLeast target: Int,
        deadline: Duration
    ) async throws {
        let start = ContinuousClock().now
        while ContinuousClock().now - start < deadline {
            let count = await bag.snapshot().reduce(into: 0) { acc, event in
                if case .streamFinished = event { acc += 1 }
            }
            if count >= target { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("waitForStreamFinishedCount: did not observe \(target) streamFinished events within \(deadline)")
    }

    /// Hoisted out so multiple tests can share the type. Re-declared here
    /// because nested actor types can't be referenced outside their enclosing
    /// function in Swift today.
    actor EventBag {
        var events: [ConversationEvent] = []
        func append(_ e: ConversationEvent) { events.append(e) }
        func snapshot() -> [ConversationEvent] { events }
    }

    // MARK: - Tests

    /// Turn 1 with no sources advertises nothing. After
    /// `updateSessionToolSources` installs a source, turn 2 advertises its
    /// tool. The point of the test is the *rebind*, not the wiring of
    /// sources at init time.
    func test_updateSessionToolSources_takesEffectOnNextTurn() async throws {
        let fx = try await makeFixture()

        // Turn 1: no sources installed.
        _ = try await fx.runtime.processTurn(
            TurnInput(sessionID: fx.sessionID, kind: .send(text: "hi"))
        )
        _ = try await collectUntilStreamFinished(from: fx.runtime)
        let turn1Tools = fx.mock.lastConfig?.tools ?? []
        XCTAssertFalse(
            turn1Tools.contains(where: { $0.name == "fixture_tool" }),
            "fixture_tool must not appear before updateSessionToolSources is called"
        )

        // Rebind: install a source that advertises `fixture_tool`.
        await fx.runtime.updateSessionToolSources([StubToolSource(toolName: "fixture_tool")])

        // Turn 2: the executor snapshots bindings at the top of the turn,
        // so the new source must be advertised on this send.
        _ = try await fx.runtime.processTurn(
            TurnInput(sessionID: fx.sessionID, kind: .send(text: "hi again"))
        )
        _ = try await collectUntilStreamFinished(from: fx.runtime)
        let turn2Tools = fx.mock.lastConfig?.tools ?? []
        XCTAssertTrue(
            turn2Tools.contains(where: { $0.name == "fixture_tool" }),
            "fixture_tool must be advertised after updateSessionToolSources rebind; got: \(turn2Tools.map(\.name))"
        )
        // Sabotage-evidence: M1 stub `updateSessionToolSources` to a no-op
        //   → turn2 advertised list stays empty; XCTAssertTrue trips.
        // Sabotage-evidence: M2 read bindings ONCE at init in the executor
        //   (revert to `let sessionToolSources`) → same trip.
        // Sabotage-evidence: M3 return [] from `SessionToolDispatchBinder.advertisedToolDefinitions`'s
        //   source branch → same trip.
    }

    /// Passing `[]` to `updateSessionToolSources` after a non-empty bind
    /// must clear the previous advertisement. Resets between demo
    /// scenarios rely on this.
    func test_updateSessionToolSources_nil_resetsToEmpty() async throws {
        let fx = try await makeFixture(
            sessionToolSources: [StubToolSource(toolName: "fixture_tool")]
        )

        // Turn 1: source installed at init — tool should be advertised.
        _ = try await fx.runtime.processTurn(
            TurnInput(sessionID: fx.sessionID, kind: .send(text: "hi"))
        )
        _ = try await collectUntilStreamFinished(from: fx.runtime)
        XCTAssertTrue(
            (fx.mock.lastConfig?.tools ?? []).contains(where: { $0.name == "fixture_tool" }),
            "precondition: turn 1 should advertise the init-time source's tool"
        )

        // Clear sources.
        await fx.runtime.updateSessionToolSources([])

        // Turn 2: nothing advertised.
        _ = try await fx.runtime.processTurn(
            TurnInput(sessionID: fx.sessionID, kind: .send(text: "hi again"))
        )
        _ = try await collectUntilStreamFinished(from: fx.runtime)
        XCTAssertFalse(
            (fx.mock.lastConfig?.tools ?? []).contains(where: { $0.name == "fixture_tool" }),
            "after updateSessionToolSources([]), no source-contributed tools should remain"
        )
        // Sabotage-evidence: M1 make `updateSessionToolSources` append rather
        //   than replace → turn2 still advertises fixture_tool; XCTAssertFalse trips.
        // Sabotage-evidence: M2 cache the initial sources in the executor and
        //   ignore the box snapshot → same trip.
    }

    /// Installing a `HookRegistry` with a registered `.preToolUse` handler
    /// must be visible on the next turn. We assert via
    /// `ConversationEvent.hookFired(event: "preToolUse", ...)`: the
    /// `PreToolUseHookAdapter` emits that event on every dispatch, so
    /// triggering a tool call after the rebind proves the new registry is
    /// wired.
    ///
    /// The handler itself is a passthrough — we're testing the binding,
    /// not the sanitiser shape.
    func test_updateHookRegistry_takesEffectOnNextTurn() async throws {
        // Use a real `ToolRegistry` with an executor registered so the
        // dispatch loop actually fires the preToolUse adapter. Without a
        // matching executor the dispatch loop short-circuits before the
        // adapter runs, and we can't observe hookFired downstream.
        let echoExecutor = TypedToolExecutor<EchoArgs, EchoArgs>(
            definition: ToolDefinition(
                name: "echo_tool",
                description: "echoes args",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ),
            handler: { args in args }
        )
        let toolRegistry = ToolRegistry(tools: [echoExecutor])

        let mock = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        ))
        mock.isModelLoaded = true
        mock.tokensToYield = ["ok"]
        // Schedule the mock to drive both user turns:
        //   - user-turn 1: generate() → no tool calls, tokens ["ok"]
        //   - user-turn 2: generate() #1 → ONE tool call, no tokens
        //                  generate() #2 (post-dispatch) → no tool calls, tokens ["ok"]
        // scriptedToolCallsPerTurn pops once per generate() call; the same
        // applies to tokensToYieldPerTurn. The three entries below cover
        // the three generate() invocations across the two user turns.
        mock.scriptedToolCallsPerTurn = [
            [], // user-turn 1
            [ToolCall(id: "tc-1", toolName: "echo_tool", arguments: "{}")], // user-turn 2, first generate()
            [] // user-turn 2, post-dispatch generate()
        ]
        mock.tokensToYieldPerTurn = [["ok"], [], ["ok"]]

        let inference = InferenceService(backend: mock, name: "Mock", toolRegistry: toolRegistry)
        let messageStore = InMemoryMessageStore()
        let sessionStore = InMemorySessionStore()
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: inference,
            pipeline: nil
        )
        let sessionID = UUID()
        try await sessionStore.insertSession(ChatSession(id: sessionID, title: "Hook"))

        // Single long-running collector across both turns. `runtime.events`
        // is single-consumer — creating a second `for await` over it after
        // the first has consumed .streamFinished does not reliably observe
        // subsequent turn events. Drain on one task and demarcate turns
        // ourselves.
        let bag = EventBag()
        let drain = Task.detached {
            for await event in runtime.events {
                await bag.append(event)
            }
        }
        defer { drain.cancel() }

        // Turn 1: no hook registry installed.
        let h1 = try await runtime.processTurn(
            TurnInput(sessionID: sessionID, kind: .send(text: "go"))
        )
        _ = h1
        // Spin until we observe turn 1's terminal streamFinished.
        try await waitForStreamFinishedCount(bag, atLeast: 1, deadline: .seconds(5))
        let turn1Events = await bag.snapshot()
        XCTAssertFalse(
            turn1Events.contains(where: {
                if case .hookFired(let name, _) = $0 { return name == "preToolUse" } else { return false }
            }),
            "preToolUse hookFired must not appear before updateHookRegistry is called"
        )

        // Install a passthrough registry.
        let hookRegistry = HookRegistry()
        await hookRegistry.register(.preToolUse) { _ in .passthrough }
        await runtime.updateHookRegistry(hookRegistry)

        // Turn 2: the dispatch loop must run through the new adapter.
        _ = try await runtime.processTurn(
            TurnInput(sessionID: sessionID, kind: .send(text: "go again"))
        )
        try await waitForStreamFinishedCount(bag, atLeast: 2, deadline: .seconds(5))
        let turn2Events = await bag.snapshot()
        // Filter to events emitted AFTER turn 1's first streamFinished —
        // events accumulate across turns; we only assert about turn 2.
        var seenFirstFinish = false
        let postTurn1: [ConversationEvent] = turn2Events.compactMap { event in
            if seenFirstFinish { return event }
            if case .streamFinished = event { seenFirstFinish = true }
            return nil
        }
        XCTAssertTrue(
            postTurn1.contains(where: {
                if case .hookFired(let name, _) = $0 { return name == "preToolUse" } else { return false }
            }),
            "preToolUse hookFired must appear after updateHookRegistry rebind; turn2-only events: \(postTurn1.map { String(describing: $0) })"
        )
        // Sabotage-evidence: M1 stub `updateHookRegistry` to a no-op
        //   → turn2 emits no preToolUse hookFired; XCTAssertTrue trips.
        // Sabotage-evidence: M2 revert the executor's hookRegistry read to a
        //   one-shot init capture → same trip.
    }

    /// Argument type for the echo executor used in
    /// `test_updateHookRegistry_takesEffectOnNextTurn`. Reflexive
    /// `Codable` over an empty payload so the dispatch loop can pass JSON
    /// `{}` through unchanged.
    struct EchoArgs: Codable, Sendable {}

}
