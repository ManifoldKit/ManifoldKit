import XCTest
import SnapshotTesting
@testable import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport

// MARK: - EventTapDrain

/// Actor that buffers ``ConversationEvent`` values from a tap and serves them
/// on demand via ``next()``.
///
/// Swift 6 disallows calling a `mutating` async function (like
/// `AsyncIteratorProtocol.next()`) on an actor-isolated stored property because
/// the borrow would span a suspension point. The workaround: a background task
/// drains the raw `AsyncStream` and enqueues events here; `next()` then returns
/// them from the buffer without holding any across-suspension borrow.
actor EventTapDrain {
    private var buffer: [ConversationEvent] = []
    private var waiters: [CheckedContinuation<ConversationEvent?, Never>] = []
    private var isDone = false

    /// Start consuming `tap` in the background. Returns the draining Task so the
    /// caller can cancel it during tearDown.
    func start(consuming tap: AsyncStream<ConversationEvent>) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in tap {
                await self?.enqueue(event)
            }
            await self?.finish()
        }
    }

    /// Suspends until the next event is available or the tap has finished.
    func next() async -> ConversationEvent? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if isDone { return nil }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    private func enqueue(_ event: ConversationEvent) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: event)
        } else {
            buffer.append(event)
        }
    }

    private func finish() {
        isDone = true
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }

    /// Resumes all pending `next()` waiters with `nil` without marking the
    /// drain as done. Use from a timeout handler to unblock a suspended
    /// `next()` call so an outer `withThrowingTaskGroup` can observe
    /// cancellation instead of hanging indefinitely.
    func drainRemaining() {
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }
}

// MARK: - TurnLoopCharacterizationTests

/// Golden-transcript harness for the ``ConversationRuntime`` turn loop.
///
/// Each test drives `send` / `regenerate` / `edit` / `cancel` / `branch`
/// against ``MockInferenceBackend`` + an in-memory SwiftData store, then
/// snapshots the ``ConversationEvent`` sequence and the final persisted
/// ``ManifoldInference.ChatMessage`` list using a UUID-canonicalizing serializer.
///
/// **Purpose.** P2 (engine carve) and P3a (`SingleTurnDriver`) both claim
/// "behaviour-preserving / byte-identical turns." These goldens are the
/// only falsifiable proof of that claim. Record them on `main` **before**
/// P2 lands; P2/P3a prove behaviour-preservation by diffing against them.
///
/// **Non-regression.** Adding these suites to the CI XCTest filter ensures
/// any turn-loop behaviour change — intentional or accidental — surfaces
/// as a snapshot diff rather than a silent regression.
///
/// **Sensitivity note.** Changing ``MockInferenceBackend/tokensToYield``
/// to a different value and re-running any test that snapshots token events
/// will produce a diff, confirming the harness catches turn-loop behaviour
/// changes. (Verified during development for `test_send_plainTurn`.)
///
/// **Out of scope (deliberately).** Compression / pre-turn compression /
/// preCompact wiring / summarisation / RAG behaviours are NOT goldened here —
/// they stay covered by their named unit suites (`CompressionPolicyTests`,
/// `PreTurnCompressionPolicyTests`, `PreCompactWiringTests`,
/// `SummarisationHookTests`, `RAGServiceTests`). Those paths fire on internal
/// thresholds, not on the turn-loop skeleton this harness pins, so a golden
/// would be a brittle restatement of unit-level policy. The records
/// canonicalizer DOES surface `promptTokens`/`completionTokens` so the
/// token-pinning those policies depend on is non-regression-tested here.
@MainActor
final class TurnLoopCharacterizationTests: XCTestCase {

    // MARK: - Per-test state

    private var persistenceStack: InMemoryPersistenceHarness.Stack!
    private var backend: MockInferenceBackend!
    private var runtime: ConversationRuntime!
    private var tapDrain: EventTapDrain!
    private var tapDrainTask: Task<Void, Never>?
    private var sessionID: UUID!

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()
        persistenceStack = try InMemoryPersistenceHarness.make()
        backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hello", " world"]
        let service = InferenceService(backend: backend, name: "CharacterizationMock")
        runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service
        )
        tapDrain = EventTapDrain()
        tapDrainTask = await tapDrain.start(consuming: runtime.addEventTap())
        sessionID = UUID()
    }

    override func tearDown() async throws {
        tapDrainTask?.cancel()
        tapDrainTask = nil
        try await super.tearDown()
    }

    // MARK: - Drain helpers

    /// Drains `tapIterator` until `predicate` returns `true` or the deadline elapses.
    private func drain(
        until predicate: (ConversationEvent) -> Bool,
        deadline: Duration = .seconds(5)
    ) async -> [ConversationEvent] {
        var events: [ConversationEvent] = []
        let end = ContinuousClock.now.advanced(by: deadline)
        while let event = await tapDrain.next() {
            events.append(event)
            if predicate(event) { break }
            if ContinuousClock.now > end { break }
        }
        return events
    }

    /// Drains until the true terminal event for any generation-producing turn.
    ///
    /// Event ordering in `ConversationTurnExecutor`:
    /// - Happy path (.stop / .empty): `streamFinished` → `afterGeneration`  ← TERMINAL
    /// - Cancelled: `streamFinished(.cancelled)`  ← TERMINAL (no afterGeneration follows)
    /// - Error: `errorRaised` → `streamFinished`  ← TERMINAL (no afterGeneration follows)
    ///
    /// Stopping at `afterGeneration` captures the complete event sequence for the
    /// happy path; stopping at `.cancelled` / `errorRaised` handles the early-exit
    /// paths where `afterGeneration` is never emitted.
    private func drainTurn() async -> [ConversationEvent] {
        await drain {
            switch $0 {
            case .afterGeneration: return true
            case .errorRaised: return true
            case .streamFinished(_, let reason):
                return reason == .cancelled || reason == .length
            default: return false
            }
        }
    }

    /// Drains until `sessionBranched` — the terminal event for a branch-without-generate turn.
    private func drainBranch() async -> [ConversationEvent] {
        await drain { if case .sessionBranched = $0 { return true }; return false }
    }

    // MARK: - Snapshot helper

    private func assertGolden(
        events: [ConversationEvent],
        records: [ManifoldInference.ChatMessage],
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        var c = EventTraceCanonicalizer()
        assertSnapshot(
            of: c.serialize(events: events),
            as: .lines,
            named: "events",
            record: .missing,
            file: file,
            testName: testName,
            line: line
        )
        assertSnapshot(
            of: c.serialize(records: records),
            as: .lines,
            named: "records",
            record: .missing,
            file: file,
            testName: testName,
            line: line
        )
    }

    // MARK: - Verb: send

    func test_send_plainTurn() async throws {
        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "Hello"))
        )
        let events = await drainTurn()
        await handle?.outcome

        let records = try await persistenceStack.provider.fetchMessages(for: sessionID)
        assertGolden(events: events, records: records)
    }

    // MARK: - Verb: regenerate

    func test_regenerate() async throws {
        // Turn 1: send
        let s1 = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "Hello"))
        )
        var allEvents = await drainTurn()
        await s1?.outcome

        // Turn 2: regenerate — replaces the assistant message
        let s2 = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .regenerate)
        )
        allEvents += await drainTurn()
        await s2?.outcome

        let records = try await persistenceStack.provider.fetchMessages(for: sessionID)
        assertGolden(events: allEvents, records: records)
    }

    // MARK: - Verb: edit

    func test_edit_userMessage() async throws {
        // Turn 1: send to establish a user + assistant message
        let s1 = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "Original text"))
        )
        var allEvents = await drainTurn()
        await s1?.outcome

        // Fetch user message ID for edit target
        let msgs1 = try await persistenceStack.provider.fetchMessages(for: sessionID)
        let userMsg = try XCTUnwrap(msgs1.first(where: { $0.role == .user }),
                                    "Expected a persisted user message after send")

        // Turn 2: edit the user message (produces a new assistant reply)
        backend.tokensToYield = ["Edited", " reply"]
        let s2 = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .edit(messageID: userMsg.id, text: "Edited text"))
        )
        allEvents += await drainTurn()
        await s2?.outcome

        let records = try await persistenceStack.provider.fetchMessages(for: sessionID)
        assertGolden(events: allEvents, records: records)
    }

    // MARK: - Verb: branch

    func test_branch_withoutGenerate() async throws {
        // Turn 1: send to create messages to branch from
        let s1 = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "Branch source"))
        )
        var allEvents = await drainTurn()
        await s1?.outcome

        // Get the user message ID to branch at
        let msgs = try await persistenceStack.provider.fetchMessages(for: sessionID)
        let userMsg = try XCTUnwrap(msgs.first(where: { $0.role == .user }),
                                    "Expected a persisted user message")

        // Branch: fork at the user message (inclusive), no generation on the fork
        let branchSessionID = UUID()
        try await runtime.processTurn(
            TurnInput(sessionID: sessionID, kind: .branch(
                messageID: userMsg.id,
                newSessionID: branchSessionID,
                generateAfter: false
            ))
        )
        allEvents += await drainBranch()

        let sourceRecords = try await persistenceStack.provider.fetchMessages(for: sessionID)
        let branchRecords = try await persistenceStack.provider.fetchMessages(for: branchSessionID)

        var c = EventTraceCanonicalizer()
        assertSnapshot(
            of: c.serialize(events: allEvents),
            as: .lines, named: "events", record: .missing
        )
        assertSnapshot(
            of: c.serialize(records: sourceRecords),
            as: .lines, named: "source-records", record: .missing
        )
        assertSnapshot(
            of: c.serialize(records: branchRecords),
            as: .lines, named: "branch-records", record: .missing
        )
    }

    // MARK: - Verb: cancel mid-stream

    func test_cancel_midStream() async throws {
        // Gate controls token emission so we can cancel after the first token
        // and before the second, making the truncation deterministic.
        let gate = TokenEmissionGate()
        backend.tokensToYield = ["Hello", " world"]
        backend.tokenEmissionGate = gate

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(
                sessionID: sessionID,
                kind: .send(text: "Cancel me"),
                config: TurnConfig(streamingBatchCharacterLimit: 1)
            )
        )

        // Drain events; cancel after the first tokenEmitted event.
        // For cancel, streamFinished(.cancelled) is the terminal — afterGeneration
        // does not fire on cancelled turns.
        let drainTask = Task { @MainActor [self] in
            var events: [ConversationEvent] = []
            var didCancel = false
            while let event = await tapDrain.next() {
                events.append(event)
                if case .tokenEmitted = event, !didCancel, let h = handle {
                    didCancel = true
                    await runtime.cancel(h.streamHandle)
                }
                if case .streamFinished(_, .cancelled) = event { break }
                if case .errorRaised = event { break }
            }
            return events
        }

        await gate.advance()    // release "Hello" so the first tokenEmitted fires
        let events = await drainTask.value
        await gate.release()    // allow the mock's generation Task to clean up
        await handle?.outcome

        let records = try await persistenceStack.provider.fetchMessages(for: sessionID)
        assertGolden(events: events, records: records)
    }

    // MARK: - Tool: real two-turn round-trip

    func test_tool_roundTrip() async throws {
        // Use a backend that declares supportsToolCalling so GenerationQueue
        // includes tool definitions in the request (required for the dispatch loop
        // to wire the registry). Default capabilities have supportsToolCalling: false.
        let toolBackend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        ))
        toolBackend.isModelLoaded = true

        // Build a dedicated runtime with a ToolRegistry.
        // Register ScriptedEchoTool directly in the registry (not via
        // SessionToolSource) to keep the golden stable across the #1606 fix.
        let registry = ToolRegistry()
        registry.register(ScriptedEchoTool(toolName: "echo", response: "Echo: hello"))
        let service = InferenceService(backend: toolBackend, name: "CharacterizationMock", toolRegistry: registry)
        let toolRuntime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service
        )
        let toolDrain = EventTapDrain()
        let toolDrainTask = await toolDrain.start(consuming: toolRuntime.addEventTap())

        // Turn 1: backend emits a tool call; no visible text
        // Turn 2: backend emits the final answer after the tool result is fed back
        toolBackend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "tool-1", toolName: "echo", arguments: "{\"q\":\"hello\"}")]
        ]
        toolBackend.tokensToYieldPerTurn = [
            [],        // turn 1: no visible tokens (tool call only)
            ["Done"]   // turn 2: final response after tool result
        ]

        let toolSessionID = UUID()
        let handle = try await toolRuntime.processTurnWithOutcome(
            TurnInput(sessionID: toolSessionID, kind: .send(text: "Use the echo tool"))
        )

        // The tool dispatch loop produces ONE streamFinished covering both turns
        var events: [ConversationEvent] = []
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while let event = await toolDrain.next() {
            events.append(event)
            if case .afterGeneration = event { break }
            if case .errorRaised = event { break }
            if case .streamFinished(_, let r) = event, r == .cancelled { break }
            if ContinuousClock.now > end { break }
        }
        await handle?.outcome

        toolDrainTask.cancel()

        let records = try await persistenceStack.provider.fetchMessages(for: toolSessionID)
        var c = EventTraceCanonicalizer()
        assertSnapshot(
            of: c.serialize(events: events),
            as: .lines, named: "events", record: .missing
        )
        assertSnapshot(
            of: c.serialize(records: records),
            as: .lines, named: "records", record: .missing
        )
    }

    // MARK: - Tool: forwarded without registry

    func test_tool_forwarded_noRegistry() async throws {
        // No ToolRegistry wired → tool call is forwarded upstream verbatim;
        // the dispatch loop exits without executing the tool or re-prompting.
        backend.scriptedToolCalls = [ToolCall(id: "tool-fwd-1", toolName: "search", arguments: "{}")]
        backend.tokensToYield = []  // no visible text; tool call only

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "Forward a tool call"))
        )
        let events = await drainTurn()
        await handle?.outcome

        let records = try await persistenceStack.provider.fetchMessages(for: sessionID)
        assertGolden(events: events, records: records)
    }

    // MARK: - Handoff: agent swap mid-stream

    /// Multi-turn handoff golden.
    ///
    /// Turn 1: the active agent (Researcher) emits a `transfer_to_Writer`
    /// tool call. The executor swaps `activeAgentID`, emits `.agentHandoff`,
    /// and persists the assistant message tagged with the *new* agent's id.
    /// Turn 2: a plain send re-derives the system prompt from the now-active
    /// Writer, proving the mid-stream `updateSession` is reflected in the
    /// next turn's prompt.
    ///
    /// Goldens this pins (that the happy-path skeleton drops):
    /// - `agentHandoff` event ordering (after the tool call, before finish).
    /// - persisted `agentID` attribution on the assistant message.
    /// - Writer's prompt active on turn N+1 (asserted directly via the mock's
    ///   captured `lastSystemPrompt`, since the system prompt is not snapshotted).
    func test_handoff_midStream() async throws {
        // Tool-calling backend so HandoffToolSource's synthesised
        // `transfer_to_<name>` definitions reach the request.
        let handoffBackend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        ))
        handoffBackend.isModelLoaded = true

        let service = InferenceService(backend: handoffBackend, name: "CharacterizationMock")
        let handoffRuntime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service
        )
        let handoffDrain = EventTapDrain()
        let handoffDrainTask = await handoffDrain.start(consuming: handoffRuntime.addEventTap())
        defer { handoffDrainTask.cancel() }

        // Pre-create a two-agent session with Researcher active. Fixed UUIDs
        // are fine — the canonicalizer relabels them positionally.
        let researcher = Agent(name: "Researcher", systemPrompt: "You are a Researcher.", description: "Gathers facts.")
        let writer = Agent(name: "Writer", systemPrompt: "You are a Writer.", description: "Drafts copy.")
        let handoffSessionID = UUID()
        try await persistenceStack.provider.insertSession(ChatSession(
            id: handoffSessionID,
            title: "Handoff characterization",
            agents: [researcher, writer],
            activeAgentID: researcher.id
        ))

        // A single drain pass to the terminal (afterGeneration / cancelled).
        func drainTurn(on drain: EventTapDrain) async -> [ConversationEvent] {
            var events: [ConversationEvent] = []
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            while let event = await drain.next() {
                events.append(event)
                if case .afterGeneration = event { break }
                if case .errorRaised = event { break }
                if case .streamFinished(_, let r) = event, r == .cancelled { break }
                if ContinuousClock.now > end { break }
            }
            return events
        }

        // Turn 1: Researcher emits transfer_to_Writer (no visible text). The
        // executor swaps `activeAgentID` to Writer and emits `.agentHandoff`.
        // The transfer ends the turn (the swap is not a re-promptable tool).
        handoffBackend.scriptedToolCalls = [
            ToolCall(id: "tc-1", toolName: "transfer_to_Writer", arguments: "{}")
        ]
        handoffBackend.tokensToYield = []

        let h1 = try await handoffRuntime.processTurnWithOutcome(
            TurnInput(sessionID: handoffSessionID, kind: .send(text: "find facts then hand off"))
        )
        var events = await drainTurn(on: handoffDrain)
        await h1?.outcome

        // The swap must have landed on turn 1.
        let agentSwapped = events.contains { if case .agentHandoff = $0 { return true }; return false }
        XCTAssertTrue(agentSwapped, "expected an .agentHandoff event on the transfer turn")

        // Turn 2 (N+1): a plain send. The executor re-derives the system prompt
        // from the now-active Writer and tags the assistant message with the
        // Writer's id. Clear the scripted transfer so this turn is plain text.
        handoffBackend.scriptedToolCalls = []
        handoffBackend.tokensToYield = ["Drafting"]

        let h2 = try await handoffRuntime.processTurnWithOutcome(
            TurnInput(sessionID: handoffSessionID, kind: .send(text: "now write the draft"))
        )
        events += await drainTurn(on: handoffDrain)
        await h2?.outcome

        // Turn N+1's prompt must reflect the mid-stream updateSession: the
        // last system prompt the backend saw is Writer's, not Researcher's.
        let lastSystem = handoffBackend.lastSystemPrompt ?? ""
        XCTAssertTrue(lastSystem.contains("You are a Writer."),
                      "turn N+1 system prompt should be re-derived from the post-handoff active agent; got: \(lastSystem)")
        XCTAssertFalse(lastSystem.contains("You are a Researcher."),
                       "Researcher's prompt must not leak into turn N+1; got: \(lastSystem)")

        let records = try await persistenceStack.provider.fetchMessages(for: handoffSessionID)

        // The assistant message must be attributed to the Writer (the active
        // agent after the swap). Pin it directly so a regeneration that drops
        // attribution can't mask itself behind a re-recorded golden.
        let assistant = try XCTUnwrap(records.first(where: { $0.role == .assistant }),
                                      "expected a persisted assistant message")
        XCTAssertEqual(assistant.agentID, writer.id,
                       "assistant message should carry the post-handoff Writer agentID")

        var c = EventTraceCanonicalizer()
        assertSnapshot(
            of: c.serialize(events: events),
            as: .lines, named: "events", record: .missing
        )
        assertSnapshot(
            of: c.serialize(records: records),
            as: .lines, named: "records", record: .missing
        )
    }

    // MARK: - Token usage recorded

    /// Token-usage golden.
    ///
    /// The backend yields a `.usage(prompt:completion:)` event before its
    /// tokens; the executor records it on the assistant message and emits
    /// `.tokenUsageRecorded`. This pins the token-count fields the happy-path
    /// skeleton drops — a lost token-pinning in the engine de-tangle now diffs.
    ///
    /// Uses ``ScriptedGenerationBackend`` (which has a `.withUsage` factory)
    /// rather than ``MockInferenceBackend`` (no usage scripting hook).
    func test_tokenUsage() async throws {
        let usageBackend = ScriptedGenerationBackend(turns: [
            .withUsage(prompt: 42, completion: 7, tokens: ["Hello", " world"])
        ])
        let service = InferenceService(backend: usageBackend, name: "CharacterizationMock")
        let usageRuntime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service
        )
        let usageDrain = EventTapDrain()
        let usageDrainTask = await usageDrain.start(consuming: usageRuntime.addEventTap())
        defer { usageDrainTask.cancel() }

        let usageSessionID = UUID()
        let handle = try await usageRuntime.processTurnWithOutcome(
            TurnInput(sessionID: usageSessionID, kind: .send(text: "Count my tokens"))
        )

        var events: [ConversationEvent] = []
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while let event = await usageDrain.next() {
            events.append(event)
            if case .afterGeneration = event { break }
            if case .errorRaised = event { break }
            if ContinuousClock.now > end { break }
        }
        await handle?.outcome

        // The usage event must have surfaced with the scripted counts.
        let usageEvent = events.compactMap { event -> (Int, Int)? in
            if case let .tokenUsageRecorded(_, prompt, completion) = event { return (prompt, completion) }
            return nil
        }.first
        let usage = try XCTUnwrap(usageEvent, "expected a .tokenUsageRecorded event")
        XCTAssertEqual(usage.0, 42, "promptTokens should be the scripted value")
        XCTAssertEqual(usage.1, 7, "completionTokens should be the scripted value")

        let records = try await persistenceStack.provider.fetchMessages(for: usageSessionID)

        // Pin the counts on the persisted assistant record directly so a
        // re-record can't silently absorb a dropped token-pinning.
        let assistant = try XCTUnwrap(records.first(where: { $0.role == .assistant }),
                                      "expected a persisted assistant message")
        XCTAssertEqual(assistant.promptTokens, 42, "persisted assistant record should carry promptTokens")
        XCTAssertEqual(assistant.completionTokens, 7, "persisted assistant record should carry completionTokens")

        var c = EventTraceCanonicalizer()
        assertSnapshot(
            of: c.serialize(events: events),
            as: .lines, named: "events", record: .missing
        )
        assertSnapshot(
            of: c.serialize(records: records),
            as: .lines, named: "records", record: .missing
        )
    }
}
