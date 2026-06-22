import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for the two tool-dispatch loop hardening features:
///
/// **B — Parallel dispatch of concurrent-safe tool calls.** When a turn emits
/// more than one tool call AND every targeted executor reports
/// ``ToolExecutor/supportsConcurrentDispatch``, the loop dispatches them
/// concurrently while preserving receipt order in the recorded results. If any
/// executor opts out, the whole batch falls back to sequential dispatch.
///
/// **C — Transient-error retry with backoff.** A `.transient` / `.rateLimited`
/// / `.timeout` tool result triggers a bounded retry of the *same* call.
/// Permanent failures and cancellation never retry.
///
/// All tests route through `GenerationQueue`, which constructs the dispatch loop
/// with `RetryPolicy.default` (3 attempts, 200ms base delay). The retry tests
/// rely on attempt counters, not wall-clock assertions, to stay deterministic.
@MainActor
final class ToolDispatchHardeningTests: XCTestCase {

    private var provider: FakeGenerationContextProvider!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
    }

    override func tearDown() async throws {
        provider = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeCoordinator(registry: ToolRegistry) -> GenerationQueue {
        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)
        return coordinator
    }

    private func collectEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func makeCall(id: String, name: String, arguments: String = "{}") -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: arguments)
    }

    // MARK: - C. Transient retry then success

    /// A tool that returns `.transient` on its first attempt and a success on
    /// the second must be retried; the loop surfaces exactly one terminal
    /// `.toolResult` (the success) and stamps the final attempt count on the
    /// `.toolDispatchStarted` event.
    func test_transientResult_retriesThenSucceeds() async throws {
        let executor = FlakyExecutor(
            name: "flaky",
            results: [
                ToolResult(callId: "", content: "blip", errorKind: .transient),
                ToolResult(callId: "", content: "recovered", errorKind: nil),
            ]
        )
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "t1", name: "flaky")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["ok"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(messages: [("user", "go")], maxOutputTokens: 8)
        let events = try await collectEvents(stream)

        // Two executor invocations: the transient one and the retry.
        // Sabotage check: returning `.permanent` on attempt 1 drops this to 1.
        XCTAssertEqual(executor.invocationCount, 2, "transient result must trigger exactly one retry")

        let results = events.compactMap { e -> ToolResult? in
            if case .toolResult(let r) = e { return r } else { return nil }
        }
        // Only the terminal (successful) result is recorded — the transient
        // attempt is internal to the retry loop.
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.callId, "t1")
        XCTAssertEqual(results.first?.content, "recovered")
        XCTAssertNil(results.first?.errorKind)

        // Each attempt emits its own start marker with an incrementing
        // `attempt` field: the first attempt (1) then the retry (2).
        let started = events.compactMap { e -> Int? in
            if case .toolDispatchStarted(_, _, let attempt) = e { return attempt } else { return nil }
        }
        XCTAssertEqual(started, [1, 2], "each attempt emits a start marker; the retry is attempt 2")
    }

    // MARK: - C. RateLimited backs off and retries

    /// A `.rateLimited` result is retry-safe. With two rate-limited responses
    /// then a success, the default 3-attempt policy reaches the success on the
    /// third attempt.
    func test_rateLimitedResult_retriesWithBackoff() async throws {
        let executor = FlakyExecutor(
            name: "limited",
            results: [
                ToolResult(callId: "", content: "429", errorKind: .rateLimited),
                ToolResult(callId: "", content: "429", errorKind: .rateLimited),
                ToolResult(callId: "", content: "served", errorKind: nil),
            ]
        )
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "r1", name: "limited")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["ok"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(messages: [("user", "go")], maxOutputTokens: 8)
        let events = try await collectEvents(stream)

        XCTAssertEqual(executor.invocationCount, 3, "two rate-limited responses must drive two retries")

        let results = events.compactMap { e -> ToolResult? in
            if case .toolResult(let r) = e { return r } else { return nil }
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.content, "served")

        let started = events.compactMap { e -> Int? in
            if case .toolDispatchStarted(_, _, let attempt) = e { return attempt } else { return nil }
        }
        XCTAssertEqual(started, [1, 2, 3], "three attempts; the success arrives on attempt 3")
    }

    // MARK: - C. Retry budget exhausts and surfaces the last failure

    /// When every attempt fails transiently, the loop stops after
    /// `maxAttempts` (default 3) and surfaces the last failure rather than
    /// looping forever.
    func test_transientResult_exhaustsRetryBudget() async throws {
        let executor = FlakyExecutor(
            name: "always_flaky",
            results: [
                ToolResult(callId: "", content: "blip-1", errorKind: .transient),
                ToolResult(callId: "", content: "blip-2", errorKind: .transient),
                ToolResult(callId: "", content: "blip-3", errorKind: .transient),
            ]
        )
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "x1", name: "always_flaky")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["ok"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(messages: [("user", "go")], maxOutputTokens: 8)
        let events = try await collectEvents(stream)

        // Exactly maxAttempts invocations — no unbounded looping.
        XCTAssertEqual(executor.invocationCount, 3, "retry must stop at the attempt ceiling")

        let results = events.compactMap { e -> ToolResult? in
            if case .toolResult(let r) = e { return r } else { return nil }
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.errorKind, .transient, "the last failure is surfaced")
        XCTAssertEqual(results.first?.content, "blip-3")
    }

    // MARK: - C. Permanent failures never retry

    /// A `.permanent` result is structural — retrying it would loop on a failure
    /// that cannot self-heal. The executor must run exactly once.
    func test_permanentResult_doesNotRetry() async throws {
        let executor = FlakyExecutor(
            name: "broken",
            results: [ToolResult(callId: "", content: "boom", errorKind: .permanent)]
        )
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "p1", name: "broken")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["ok"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(messages: [("user", "go")], maxOutputTokens: 8)
        let events = try await collectEvents(stream)

        // Sabotage check: classifying `.permanent` as retriable in
        // `RetryPolicy.isRetriable` would push this above 1.
        XCTAssertEqual(executor.invocationCount, 1, "permanent failures must not retry")

        let results = events.compactMap { e -> ToolResult? in
            if case .toolResult(let r) = e { return r } else { return nil }
        }
        XCTAssertEqual(results.first?.errorKind, .permanent)

        let started = events.compactMap { e -> Int? in
            if case .toolDispatchStarted(_, _, let attempt) = e { return attempt } else { return nil }
        }
        XCTAssertEqual(started, [1], "a non-retried call reports a single attempt")
    }

    // MARK: - C. Cancellation never retries

    /// A `.cancelled` result is an intentional user stop. The loop must honor it
    /// immediately — no retry — and terminate with `.cancelled`.
    func test_cancelledResult_doesNotRetry_andStopsLoop() async throws {
        let executor = FlakyExecutor(
            name: "stoppable",
            results: [ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)]
        )
        let registry = ToolRegistry()
        registry.register(executor)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "c1", name: "stoppable")],
            [],
        ]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(messages: [("user", "go")], maxOutputTokens: 8)
        let events = try await collectEvents(stream)

        XCTAssertEqual(executor.invocationCount, 1, "cancellation must not retry")

        let completions = events.compactMap { e -> GenerationCompletion? in
            if case .generationCompleted(let c) = e { return c } else { return nil }
        }
        XCTAssertEqual(completions.first?.reason, .cancelled, "a cancelled tool result stops the loop")
    }

    // MARK: - B. Concurrent-safe calls dispatch in parallel

    /// Two concurrent-safe executors in one turn must run concurrently. Each
    /// executor signals start, then awaits a shared barrier that only opens once
    /// BOTH have started. Under sequential dispatch the second would never start
    /// until the first returned — so the barrier would never open and the test
    /// would time out. Parallel dispatch lets both reach the barrier.
    func test_concurrentSafeCalls_dispatchInParallel() async throws {
        let barrier = StartBarrier(expected: 2)
        let execA = BarrierExecutor(name: "fetch_a", result: "A", barrier: barrier, concurrent: true)
        let execB = BarrierExecutor(name: "fetch_b", result: "B", barrier: barrier, concurrent: true)

        let registry = ToolRegistry()
        registry.register(execA)
        registry.register(execB)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "a-1", name: "fetch_a"), makeCall(id: "b-1", name: "fetch_b")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["done"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(messages: [("user", "go")], maxOutputTokens: 8)

        // If dispatch were sequential, the stream would never finish (barrier
        // deadlock) and this would hang the test deadline rather than fail.
        let events = try await collectEvents(stream)

        let results = events.compactMap { e -> ToolResult? in
            if case .toolResult(let r) = e { return r } else { return nil }
        }
        XCTAssertEqual(results.count, 2, "both parallel calls must produce a result")

        // Receipt order is preserved in the recorded results regardless of which
        // executor finished first.
        // Sabotage check: reversing the gather order in `dispatchParallel`
        // flips these callIds.
        XCTAssertEqual(results.map(\.callId), ["a-1", "b-1"], "results must stay in receipt order")
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.callId, $0.content) })
        XCTAssertEqual(byId["a-1"], "A")
        XCTAssertEqual(byId["b-1"], "B")
    }

    // MARK: - B. Cancellation propagates into an in-flight parallel batch

    /// Two concurrent-safe executors are dispatched in parallel and both hang on
    /// a cancellation-aware sleep. A user stop (`stopGeneration()`) must
    /// propagate into the parallel child tasks so each executor observes
    /// `Task.isCancelled` and unwinds, the loop records `.cancelled`, and the
    /// stream terminates promptly.
    ///
    /// This is the regression guard for the parallel cancellation contract: the
    /// parallel children are unstructured `Task`s that do NOT inherit parent
    /// cancellation automatically, so `dispatchParallel` wraps the await in a
    /// `withTaskCancellationHandler` that cancels every child. Without that
    /// handler the executors hang forever and this test times out.
    func test_stopGeneration_duringParallelBatch_cancelsChildren_andStops() async throws {
        let entered = StartBarrier(expected: 2)
        let execA = HangingConcurrentExecutor(name: "hang_a", didEnter: entered)
        let execB = HangingConcurrentExecutor(name: "hang_b", didEnter: entered)

        let registry = ToolRegistry()
        registry.register(execA)
        registry.register(execB)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "h-a", name: "hang_a"), makeCall(id: "h-b", name: "hang_b")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["must-not-run"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(messages: [("user", "go")], maxOutputTokens: 8)

        let collector = Task<[GenerationEvent], Never> {
            var events: [GenerationEvent] = []
            do {
                for try await event in stream.events { events.append(event) }
            } catch {
                // Cancellation throws — events gathered before the throw stand.
            }
            return events
        }

        // Both parallel children must be inside `execute` before we stop, so the
        // cancellation lands on a genuinely in-flight batch (not before dispatch).
        await entered.waitUntilAllArrived()
        coordinator.stopGeneration()

        // Bound the wait: a regression that fails to cancel the children leaves
        // them sleeping 60s and surfaces here as a visible failure, not a hang.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(5))
            collector.cancel()
        }
        let events = await collector.value
        timeoutTask.cancel()

        let completions = events.compactMap { e -> GenerationCompletion? in
            if case .generationCompleted(let c) = e { return c } else { return nil }
        }
        XCTAssertEqual(completions.first?.reason, .cancelled, "stop during a parallel batch must terminate the loop as cancelled")

        let tokens = events.compactMap { e -> String? in
            if case .token(let t) = e { return t } else { return nil }
        }
        XCTAssertFalse(tokens.contains("must-not-run"), "no further turn after a cancelled parallel batch")
    }

    // MARK: - B. Mixed batch falls back to sequential

    /// When one executor in the batch is NOT concurrent-safe, the whole turn
    /// falls back to sequential dispatch. The non-concurrent executor must still
    /// run and both results must arrive in receipt order. (No barrier here — a
    /// barrier would deadlock the sequential path by design.)
    func test_mixedConcurrencyBatch_fallsBackToSequential() async throws {
        let concurrent = FlakyExecutor(
            name: "safe",
            results: [ToolResult(callId: "", content: "S", errorKind: nil)],
            supportsConcurrentDispatch: true
        )
        let sequential = FlakyExecutor(
            name: "unsafe",
            results: [ToolResult(callId: "", content: "U", errorKind: nil)],
            supportsConcurrentDispatch: false
        )

        let registry = ToolRegistry()
        registry.register(concurrent)
        registry.register(sequential)

        provider.backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "s-1", name: "safe"), makeCall(id: "u-1", name: "unsafe")],
            [],
        ]
        provider.backend.tokensToYieldPerTurn = [[], ["done"]]

        let coordinator = makeCoordinator(registry: registry)
        let (_, stream) = try coordinator.enqueue(messages: [("user", "go")], maxOutputTokens: 8)
        let events = try await collectEvents(stream)

        XCTAssertEqual(concurrent.invocationCount, 1)
        XCTAssertEqual(sequential.invocationCount, 1, "the non-concurrent executor still runs under fallback")

        let results = events.compactMap { e -> ToolResult? in
            if case .toolResult(let r) = e { return r } else { return nil }
        }
        XCTAssertEqual(results.map(\.callId), ["s-1", "u-1"], "sequential fallback preserves receipt order")
    }
}

// MARK: - Fixtures

/// Executor that returns a scripted sequence of results across successive
/// invocations. Used to drive the retry path (each invocation pops the next
/// scripted result). `@unchecked Sendable` is safe: the counter and queue are
/// only mutated on the main actor (the dispatch loop is `@MainActor`).
@MainActor
private final class FlakyExecutor: ToolExecutor, @unchecked Sendable {
    let definition: ToolDefinition
    let supportsConcurrentDispatch: Bool
    private var queued: [ToolResult]
    private(set) var invocationCount = 0

    init(
        name: String,
        results: [ToolResult],
        supportsConcurrentDispatch: Bool = false
    ) {
        self.definition = ToolDefinition(name: name, description: "flaky test fixture", parameters: .object([:]))
        self.queued = results
        self.supportsConcurrentDispatch = supportsConcurrentDispatch
    }

    nonisolated func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        await MainActor.run {
            invocationCount += 1
            // Once the script is drained, repeat the last result so an
            // over-eager retry surfaces visibly rather than crashing.
            if queued.count > 1 {
                return queued.removeFirst()
            }
            return queued.first ?? ToolResult(callId: "", content: "drained", errorKind: .permanent)
        }
    }
}

/// A barrier that opens only once `expected` participants have arrived. Used to
/// prove that two executors run concurrently: each calls `arrive()` and then
/// awaits the open. Under sequential dispatch the second never arrives, so the
/// barrier never opens.
private actor StartBarrier {
    private let expected: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= expected {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Marks arrival WITHOUT waiting — for executors that need to signal "I'm
    /// in-flight" and then suspend on something else (e.g. a cancellation-aware
    /// sleep) rather than block on the barrier.
    func arrive() {
        arrived += 1
        if arrived >= expected {
            for waiter in observers { waiter.resume() }
            observers.removeAll()
        }
    }

    /// Suspends until `expected` participants have called `arrive()` (or
    /// `arriveAndWait()`). Used by a non-participant observer (the test) to know
    /// the whole batch is in-flight before acting.
    func waitUntilAllArrived() async {
        if arrived >= expected { return }
        await withCheckedContinuation { continuation in
            observers.append(continuation)
        }
    }

    private var observers: [CheckedContinuation<Void, Never>] = []
}

/// Concurrent-safe executor that arrives at a shared barrier before returning.
/// If two of these are dispatched in parallel, both arrive and the barrier
/// opens; if dispatched sequentially, the first would block forever waiting.
private struct BarrierExecutor: ToolExecutor {
    let definition: ToolDefinition
    let supportsConcurrentDispatch: Bool
    private let result: String
    private let barrier: StartBarrier

    init(name: String, result: String, barrier: StartBarrier, concurrent: Bool) {
        self.definition = ToolDefinition(name: name, description: "barrier test fixture", parameters: .object([:]))
        self.result = result
        self.barrier = barrier
        self.supportsConcurrentDispatch = concurrent
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        await barrier.arriveAndWait()
        return ToolResult(callId: "", content: result, errorKind: nil)
    }
}

/// Concurrent-safe executor that signals it has entered `execute` and then hangs
/// on a cancellation-aware sleep. Used to prove that a stop during an in-flight
/// parallel batch propagates cancellation into every child task.
private struct HangingConcurrentExecutor: ToolExecutor {
    let definition: ToolDefinition
    var supportsConcurrentDispatch: Bool { true }
    private let didEnter: StartBarrier

    init(name: String, didEnter: StartBarrier) {
        self.definition = ToolDefinition(name: name, description: "hangs (concurrent)", parameters: .object([:]))
        self.didEnter = didEnter
    }

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        await didEnter.arrive()
        // Cancellation-aware sleep: `Task.sleep` throws `CancellationError` the
        // moment the surrounding (child) task is cancelled.
        try await Task.sleep(for: .seconds(60))
        return ToolResult(callId: "", content: "should-never-reach", errorKind: nil)
    }
}
