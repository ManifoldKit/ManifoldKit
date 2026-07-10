import XCTest
import SnapshotTesting
@testable import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport
// ScriptedGenerationBackend relocated to ManifoldAppEval (app-eval harness wave 1).
import ManifoldAppEval

// MARK: - CompressionGoldenTests

/// Golden-transcript harness for the turn-loop compression paths in
/// ``ConversationTurnExecutor``.
///
/// **Purpose.** PR #1724 deliberately left the pre-turn and post-turn
/// compress-and-replace sequences inside ``ConversationTurnExecutor`` because
/// no golden harness covered them. Any future "behavior-preserving" extraction
/// of those paths (P3a) was therefore unprovable. These tests provide the
/// proof: the full ``ConversationEvent`` sequence and persisted record set for
/// each compression path are snapshotted; any behavior-altering refactor of
/// the executor's compression coordination will produce a diff here.
///
/// **What each test pins:**
/// - ``test_postTurn_compressionTriggered`` — post-turn path: events include
///   `compressionTriggered` then `historyCompressed`; records contain only the
///   replacement summary message.
/// - ``test_preTurn_compressionTriggered`` — pre-turn path: compression events
///   fire before the user message is inserted; records reflect the compressed
///   history followed by the new user and assistant messages.
/// - ``test_postTurn_preCompactHook_observational`` — preCompact hook is
///   observational (invariant 6 from P2c brief): a `block:true` result does
///   not prevent compression; the ``hookFired`` event appears in the golden
///   and compression still completes.
///
/// **No-compression control** is already goldened by
/// ``TurnLoopCharacterizationTests/test_send_plainTurn`` (no compression
/// policy wired, no compression events). Duplicating it here would be noise.
///
/// **Sabotage verification** was performed for each test during development;
/// the PR body describes the mutation applied and the observed diff.
@MainActor
final class CompressionGoldenTests: XCTestCase {

    // MARK: - Per-test state

    private var persistenceStack: InMemoryPersistenceHarness.Stack!
    private var tapDrain: EventTapDrain!
    private var tapDrainTask: Task<Void, Never>?
    private var sessionID: UUID!

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()
        persistenceStack = try InMemoryPersistenceHarness.make()
        tapDrain = EventTapDrain()
        sessionID = UUID()
    }

    override func tearDown() async throws {
        tapDrainTask?.cancel()
        tapDrainTask = nil
        try await super.tearDown()
    }

    // MARK: - Policy helpers (local to this suite)

    /// Compression policy that always decides to compress (when contextSize > 0).
    /// Returns a single summary record without calling `generate`, so no second
    /// backend round-trip is needed and the generate closure is deterministic.
    private struct AlwaysCompressPolicy: CompressionPolicy {
        let summaryContent: String

        func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
            contextSize > 0
        }

        func compress(
            history: [ManifoldInference.ChatMessage],
            sessionID: UUID,
            generate: @Sendable ([ManifoldInference.ChatMessage]) async throws -> String
        ) async throws -> [ManifoldInference.ChatMessage] {
            // Return a single memory record summarising the history. Does NOT
            // call `generate` so the test stays self-contained: no second
            // backend round-trip means no non-determinism in the event stream.
            [ManifoldInference.ChatMessage(
                role: .system,
                content: summaryContent,
                sessionID: sessionID,
                kind: .memory("summary")
            )]
        }
    }

    /// Pre-turn compression policy that fires when the history already contains
    /// at least one message (messageCount >= 1). Like the post-turn variant,
    /// it returns a single summary record without calling `generate`.
    private struct AlwaysPreCompressPolicy: PreTurnCompressionPolicy {
        let summaryContent: String

        func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
            // Fire whenever there is any existing history to compress.
            messageCount >= 1
        }

        func compressBeforeTurn(
            history: [ManifoldInference.ChatMessage],
            sessionID: UUID,
            generate: @Sendable ([ManifoldInference.ChatMessage]) async throws -> String
        ) async throws -> [ManifoldInference.ChatMessage] {
            [ManifoldInference.ChatMessage(
                role: .system,
                content: summaryContent,
                sessionID: sessionID,
                kind: .memory("summary")
            )]
        }
    }

    // MARK: - Backend helper

    /// Returns a ``ScriptedGenerationBackend`` that emits a usage event so
    /// the post-turn compression gate activates (requires non-nil promptTokens).
    /// `maxContextTokens: 256` gives a non-zero context size; the executor's
    /// `readContextWindowSize()` reads `capabilities.contextWindowSize` which
    /// is `Int(maxContextTokens)`, so 256 is both representable and above zero.
    private func makeUsageBackend(
        promptTokens: Int = 50,
        completionTokens: Int = 5,
        textTokens: [String] = ["OK"],
        maxContextTokens: Int32 = 256
    ) -> ScriptedGenerationBackend {
        ScriptedGenerationBackend(
            turns: [.withUsage(prompt: promptTokens, completion: completionTokens, tokens: textTokens)],
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: maxContextTokens,
                requiresPromptTemplate: false,
                supportsSystemPrompt: true,
                supportsToolCalling: false,
                supportsStructuredOutput: false,
                cancellationStyle: .cooperative,
                supportsTokenCounting: false
            )
        )
    }

    // MARK: - Drain helpers

    /// Drains the tap until `afterGeneration` or an early-exit terminal event.
    private func drainTurn() async -> [ConversationEvent] {
        var events: [ConversationEvent] = []
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while let event = await tapDrain.next() {
            events.append(event)
            if case .afterGeneration = event { break }
            if case .errorRaised = event { break }
            if case .streamFinished(_, let r) = event, r == .cancelled { break }
            if ContinuousClock.now > end { break }
        }
        return events
    }

    /// Continues draining after `afterGeneration` until the post-turn
    /// `historyCompressed` event fires. Post-turn compression runs AFTER
    /// `afterGeneration` in the executor's call chain, so the normal
    /// `drainTurn()` terminal misses it. This drain runs for up to `deadline`
    /// after `drainTurn()` returns.
    ///
    /// The deadline is enforced by racing the drain against a `Task.sleep`
    /// using `withThrowingTaskGroup`. When the sleep wins, the group is
    /// cancelled and `next()` — which uses `withCheckedContinuation` — is
    /// unblocked via `EventTapDrain.drainRemaining()` (a batch flush that
    /// resumes all pending waiters with `nil`).
    private func drainPostTurnCompression(deadline: Duration = .seconds(5)) async -> [ConversationEvent] {
        // Capture the actor reference (Sendable) separately to avoid capturing
        // the non-Sendable XCTestCase self into the task closure.
        let drain = tapDrain!
        do {
            return try await withThrowingTaskGroup(of: [ConversationEvent].self) { group in
                group.addTask { () throws -> [ConversationEvent] in
                    var events: [ConversationEvent] = []
                    while let event = await drain.next() {
                        events.append(event)
                        if case .historyCompressed = event { break }
                        try Task.checkCancellation()
                    }
                    return events
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    return []
                }
                // First task to finish wins.
                let result = try await group.next() ?? []
                group.cancelAll()
                // Unblock any suspended .next() waiters so the drain child can
                // observe cancellation (or finish) without hanging.
                await drain.drainRemaining()
                return result
            }
        } catch {
            return []
        }
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

    // MARK: - Test: post-turn compression triggered

    /// Post-turn compression golden.
    ///
    /// The backend emits `usage(prompt:50, completion:5)` before text tokens.
    /// The executor reads `promptTokens = 50` and `contextSize = 256` (from
    /// `maxContextTokens`), so `AlwaysCompressPolicy.shouldCompress` returns
    /// `true`. The executor calls `compress`, which returns one summary record.
    /// The original messages are deleted and replaced.
    ///
    /// Events pinned:
    /// - Normal turn skeleton (beforeContextAssembly → ... → afterGeneration)
    /// - `compressionTriggered` with the removed message IDs
    /// - `historyCompressed` with the inserted summary record
    ///
    /// Records pinned:
    /// - Only the summary replacement record (user + assistant replaced)
    func test_postTurn_compressionTriggered() async throws {
        let policy = AlwaysCompressPolicy(summaryContent: "Compression summary.")
        let backend = makeUsageBackend(promptTokens: 50, completionTokens: 5, textTokens: ["OK"])
        let service = InferenceService(backend: backend, name: "CompressionMock")
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            compressionPolicy: policy
        )

        tapDrainTask = await tapDrain.start(consuming: runtime.addEventTap())

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "Compress me"))
        )
        var events = await drainTurn()
        // Post-turn compression fires after afterGeneration; drain it separately.
        events += await drainPostTurnCompression()
        _ = await handle?.outcome

        let records = try await persistenceStack.provider.fetchMessages(for: sessionID)
        assertGolden(events: events, records: records)
    }

    // MARK: - Test: pre-turn compression triggered

    /// Pre-turn compression golden.
    ///
    /// The store is seeded with one prior user message before the send turn.
    /// `AlwaysPreCompressPolicy.shouldCompressBeforeTurn` returns `true` when
    /// `messageCount >= 1`. The executor compresses before inserting the new
    /// user message, so the compression events appear early in the event stream
    /// (before `messageInserted(user)` for the *new* user message).
    ///
    /// Events pinned:
    /// - `compressionTriggered` + `historyCompressed` before the user message
    ///   for the new turn is inserted
    /// - Normal turn skeleton follows the compression events
    ///
    /// Records pinned:
    /// - The summary record (replacing the prior message) + the new user
    ///   message + the new assistant reply
    func test_preTurn_compressionTriggered() async throws {
        // Seed the store with a prior message so shouldCompressBeforeTurn fires.
        let priorMsg = ManifoldInference.ChatMessage(
            role: .user,
            content: "Prior message to be compressed.",
            sessionID: sessionID
        )
        try await persistenceStack.provider.insertMessage(priorMsg)

        let policy = AlwaysPreCompressPolicy(summaryContent: "Pre-turn summary.")
        let backend = ScriptedGenerationBackend(
            turns: [.tokens(["Pre-turn response."])],
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: 256,
                requiresPromptTemplate: false,
                supportsSystemPrompt: true,
                supportsToolCalling: false,
                supportsStructuredOutput: false,
                cancellationStyle: .cooperative,
                supportsTokenCounting: false
            )
        )
        let service = InferenceService(backend: backend, name: "PreTurnMock")
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            preTurnCompressionPolicy: policy
        )

        tapDrainTask = await tapDrain.start(consuming: runtime.addEventTap())

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "New turn after compression"))
        )
        let events = await drainTurn()
        _ = await handle?.outcome

        let records = try await persistenceStack.provider.fetchMessages(for: sessionID)
        assertGolden(events: events, records: records)
    }

    // MARK: - Test: preCompact hook is observational

    /// preCompact hook observational golden (invariant 6 from P2c brief).
    ///
    /// A `HookRegistry` is wired with a `preCompact` handler that returns
    /// `block: true`. Per the v1 contract, `block: true` is ignored — compression
    /// still runs, and the executor logs a warning. The golden pins:
    /// - `hookFired(event: "preCompact")` appears in the event stream
    /// - `compressionTriggered` and `historyCompressed` follow it
    /// - The final record set is the compressed output (not the original history)
    ///
    /// This confirms the executor's "preCompact observational" invariant is
    /// structurally enforced: extracting the compression coordinator in P3a
    /// cannot accidentally honour `block: true` without diffing this golden.
    func test_postTurn_preCompactHook_observational() async throws {
        let policy = AlwaysCompressPolicy(summaryContent: "Hook-gated summary.")
        let backend = makeUsageBackend(promptTokens: 60, completionTokens: 6, textTokens: ["Done"])

        let hookRegistry = HookRegistry()
        // Register a blocking preCompact hook — the v1 contract says this is a
        // no-op for blocking, but the hook MUST still fire.
        await hookRegistry.register(.preCompact) { _ in
            HookOutput(block: true, denyReason: "test-block")
        }

        let service = InferenceService(backend: backend, name: "HookMock")
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            compressionPolicy: policy,
            hookRegistry: hookRegistry
        )

        tapDrainTask = await tapDrain.start(consuming: runtime.addEventTap())

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "Hook test turn"))
        )
        var events = await drainTurn()
        events += await drainPostTurnCompression()
        _ = await handle?.outcome

        // Direct assertion: the hook must have fired and compression must have
        // run. This is load-bearing on top of the snapshot so a
        // re-record cannot silently absorb a regression that drops one of them.
        let hookFired = events.contains {
            if case .hookFired(let name, _) = $0 { return name == "preCompact" }
            return false
        }
        XCTAssertTrue(hookFired, "hookFired(preCompact) must appear even when block:true")

        let compressionRan = events.contains {
            if case .historyCompressed = $0 { return true }
            return false
        }
        XCTAssertTrue(compressionRan, "compression must proceed even when preCompact hook returns block:true")

        let records = try await persistenceStack.provider.fetchMessages(for: sessionID)
        assertGolden(events: events, records: records)
    }
}
