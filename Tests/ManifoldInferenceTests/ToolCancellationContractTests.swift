import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Cancellation-contract tests for tools that are in flight when the user
/// hits stop (issue #622).
///
/// Coverage:
/// - Orchestrator-driven cancellation: scripted backend emits a tool call,
///   executor awaits forever, ``GenerationQueue.stopGeneration()``
///   propagates cancellation into the executor, the transcript records a
///   ``ToolResult/ErrorKind/cancelled`` result, and no further backend turn
///   runs.
/// - Registry-only cancellation: `ToolRegistry.dispatch(_:)` invoked from a
///   cancelled task returns ``ToolResult/ErrorKind/cancelled`` regardless of
///   whether the executor threw `CancellationError` or returned normally.
/// - Leak check: a bridged callback executor (modelled on the
///   `URLSessionDataTask` shape) deinits its underlying handle when the
///   surrounding task is cancelled — proving the cooperative-cancellation
///   contract in ``ToolExecutor`` actually frees resources.
@MainActor
final class ToolCancellationContractTests: XCTestCase {

    // MARK: - Fixtures

    /// Executor that suspends on a continuation forever until cancelled.
    /// `requiresApproval == false` so dispatch goes through the no-gate
    /// branch — keeps the test focused on the cancellation path itself.
    private final class HangingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition

        /// Signalled the moment ``execute(arguments:)`` is entered. Tests
        /// await it before invoking `stopGeneration()` so cancellation
        /// races are deterministic.
        let didEnter: AsyncStream<Void>
        private let enterContinuation: AsyncStream<Void>.Continuation

        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "hangs", parameters: .object([:]))
            var cont: AsyncStream<Void>.Continuation!
            self.didEnter = AsyncStream { cont = $0 }
            self.enterContinuation = cont
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            enterContinuation.yield(())
            // Hang on a cancellation-aware sleep. `try Task.sleep` throws
            // `CancellationError` the moment the surrounding task is
            // cancelled — this is the cooperative-cancellation contract
            // every executor is expected to honour.
            try await Task.sleep(for: .seconds(60))
            return ToolResult(callId: "", content: "should-never-reach", errorKind: nil)
        }
    }

    /// Executor that ignores cancellation: returns a real result even after
    /// the surrounding task is cancelled. The registry must still classify
    /// the outcome as ``ToolResult/ErrorKind/cancelled`` because the
    /// transcript contract is "no post-stop tool output flows through".
    private final class UncooperativeExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition

        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "ignores cancel", parameters: .object([:]))
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            // No `try Task.checkCancellation()` and no cancellation-aware
            // suspension — simulate a CPU-bound or otherwise non-cooperative
            // path. The registry's post-await `Task.isCancelled` upgrade is
            // what saves the transcript.
            ToolResult(callId: "", content: "stale-output", errorKind: nil)
        }
    }

    private var provider: FakeGenerationContextProvider!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
    }

    override func tearDown() async throws {
        provider = nil
        try await super.tearDown()
    }

    // MARK: - Orchestrator: stopGeneration during in-flight tool

    /// End-to-end: backend emits a tool call → executor hangs → caller hits
    /// stop → cancellation propagates into the executor → transcript records
    /// a `.cancelled` ToolResult → orchestrator does NOT run another backend
    /// turn.
    func test_stopGeneration_duringInFlightTool_recordsCancelledResult_noFurtherTurn() async throws {
        let executor = HangingExecutor(name: "slow_op")
        let registry = ToolRegistry()
        registry.register(executor)

        // Scripted backend: turn 1 emits the tool call. If the orchestrator
        // were to (incorrectly) run a follow-up turn after cancellation it
        // would also drain turn 2's tokens — the assertion below catches
        // that regression.
        provider.backend.scriptedToolCallsPerTurn = [
            [ToolCall(id: "c-cancel", toolName: "slow_op", arguments: "{}")],
            []
        ]
        provider.backend.tokensToYieldPerTurn = [
            [],
            ["second", "-turn", "-must-not-run"]
        ]

        let coordinator = GenerationQueue(toolRegistry: registry)
        provider.bind(to: coordinator)

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "go")],
            maxOutputTokens: 64
        )

        // Drain events on a separate task so we can stop generation while
        // the executor is hanging. The stream is expected to terminate
        // by throwing `CancellationError` after the orchestrator finishes
        // yielding the synthesized `.toolResult(.cancelled)` event — that
        // matches the existing stopGeneration contract (cancelled streams
        // throw rather than finish cleanly). Catch it here and return the
        // events we managed to collect.
        let collector = Task<[GenerationEvent], Never> {
            var events: [GenerationEvent] = []
            do {
                for try await event in stream.events {
                    events.append(event)
                }
            } catch {
                // Cancellation throws — events accumulated before the
                // throw are still observed by the test below.
            }
            return events
        }

        // Wait until the executor is actually inside `execute(arguments:)`
        // before cancelling. Without this, stopGeneration() could fire
        // before the executor even enters the await — covering a different
        // (less interesting) code path.
        for await _ in executor.didEnter { break }

        coordinator.stopGeneration()

        // Stream collection must finish promptly. Bound the wait so a
        // regression that fails to propagate cancellation surfaces as a
        // visible test failure rather than a timeout from the test runner.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(5))
            collector.cancel()
        }
        let events = await collector.value
        timeoutTask.cancel()

        // Sabotage check: removing the `result.errorKind == .cancelled`
        // early-return in `runToolDispatchLoop` lets the loop run another
        // turn, which would surface the "second-turn-must-not-run" tokens
        // below.
        let toolResults = events.compactMap { event -> ToolResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        XCTAssertEqual(toolResults.count, 1, "exactly one tool result must be recorded")
        XCTAssertEqual(toolResults.first?.errorKind, .cancelled)
        XCTAssertEqual(toolResults.first?.callId, "c-cancel")
        XCTAssertTrue(
            toolResults.first?.content.contains("cancelled") == true,
            "result content should describe the cancellation; got: \(toolResults.first?.content ?? "<nil>")"
        )

        // The orchestrator must NOT have run a second backend turn after the
        // cancellation — turn 2's scripted tokens must not appear.
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertFalse(
            tokens.contains("second"),
            "no further backend turn should run after a cancelled tool — found: \(tokens)"
        )
    }

    // MARK: - Registry: dispatch under task cancellation

    /// `ToolRegistry.dispatch(_:)` invoked from a cancelled task returns
    /// `.cancelled` when the executor cooperates by throwing
    /// `CancellationError`.
    func test_registryDispatch_underCancellation_returnsCancelled_whenExecutorCooperates() async throws {
        let executor = HangingExecutor(name: "slow_op")
        let registry = ToolRegistry()
        registry.register(executor)

        let dispatchTask = Task { @MainActor in
            await registry.dispatch(ToolCall(id: "x", toolName: "slow_op", arguments: "{}"))
        }
        // Wait until the executor is suspended inside `Task.sleep` before
        // cancelling — otherwise the cancellation may arrive before the
        // executor enters the cancellation-aware suspension.
        for await _ in executor.didEnter { break }

        dispatchTask.cancel()

        let result = await dispatchTask.value
        // Sabotage check: changing the registry's `catch is CancellationError`
        // branch back to `.permanent` flips this assertion.
        XCTAssertEqual(result.errorKind, .cancelled)
        XCTAssertEqual(result.callId, "x")
    }

    /// Even an uncooperative executor that returns a real value must not
    /// have that value surface in the transcript when the surrounding task
    /// was cancelled mid-flight. The post-await `Task.isCancelled` check
    /// upgrades the result to `.cancelled`.
    func test_registryDispatch_underCancellation_returnsCancelled_whenExecutorIgnoresCancellation() async {
        let executor = UncooperativeExecutor(name: "stale")
        let registry = ToolRegistry()
        registry.register(executor)

        // Run dispatch inside a task we cancel before awaiting its value.
        // Cancelling before `await dispatchTask.value` guarantees
        // `Task.isCancelled` is true throughout the dispatch body.
        let dispatchTask = Task { @MainActor () -> ToolResult in
            // Yield once so cancellation is observable.
            await Task.yield()
            return await registry.dispatch(ToolCall(id: "u", toolName: "stale", arguments: "{}"))
        }
        dispatchTask.cancel()
        let result = await dispatchTask.value

        XCTAssertEqual(result.errorKind, .cancelled)
        XCTAssertFalse(
            result.content.contains("stale-output"),
            "stale executor output must not flow into the transcript after cancellation; got: \(result.content)"
        )
    }

    // MARK: - Leak check: bridged callback resource is released on cancel

    /// Tracker shared with ``BridgedHandleExecutor`` so the test can observe
    /// the bridged-handle deinit deterministically. Using a class with a
    /// strong-ref counter mirrors the `URLSessionDataTask` shape — the
    /// executor must release the handle on cancel for the deinit to fire
    /// and for the test to see `liveHandles == 0`.
    private final class HandleTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var _liveHandles = 0
        var liveHandles: Int {
            lock.lock(); defer { lock.unlock() }
            return _liveHandles
        }
        func incr() {
            lock.lock(); _liveHandles += 1; lock.unlock()
        }
        func decr() {
            lock.lock(); _liveHandles -= 1; lock.unlock()
        }
    }

    /// Mimics `URLSessionDataTask`: a class handle that the executor owns,
    /// releases on cancel, and whose deinit decrements a tracker. This is
    /// the leak-check shape called out in the issue ("no dangling
    /// URLSessionDataTask after cancellation").
    private final class BridgedHandle: @unchecked Sendable {
        let tracker: HandleTracker
        init(tracker: HandleTracker) {
            self.tracker = tracker
            tracker.incr()
        }
        deinit {
            tracker.decr()
        }
        // No `cancel()` is needed: holding only a strong reference inside
        // the executor's `withTaskCancellationHandler` body is enough — the
        // body unwinds when `Task.sleep` throws on cancel, the local
        // strong reference is released, and the deinit fires. The
        // `onCancel` closure exists to mirror the URLSessionDataTask
        // shape; in production it would call the underlying handle's
        // `cancel()` to tear down I/O before letting the task unwind.
    }

    private final class BridgedHandleExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        let tracker: HandleTracker

        init(name: String, tracker: HandleTracker) {
            self.definition = ToolDefinition(name: name, description: "bridged", parameters: .object([:]))
            self.tracker = tracker
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            // Allocate a "data task". Crucially the handle is owned only
            // by the local scope; if `withTaskCancellationHandler`
            // releases its retain via `cancel()`, the handle deinits and
            // the tracker decrements.
            let handle = BridgedHandle(tracker: tracker)

            return try await withTaskCancellationHandler {
                // Suspend cooperatively so cancellation can be observed.
                try await Task.sleep(for: .seconds(60))
                _ = handle  // keep alive across suspension
                return ToolResult(callId: "", content: "done", errorKind: nil)
            } onCancel: {
                // Real-world equivalent: a `URLSessionDataTask.cancel()`
                // call here. The mock has no underlying I/O — the strong
                // ref is released the moment the body above unwinds via
                // `CancellationError`, which fires `BridgedHandle.deinit`
                // and decrements the tracker.
                _ = handle  // keep retained until the body returns
            }
        }
    }

    /// Cancelling a dispatch must not leak the bridged handle — once the
    /// executor returns, the handle's strong ref is released and its
    /// deinit fires.
    func test_bridgedCallbackExecutor_releasesHandle_onCancellation() async throws {
        let tracker = HandleTracker()
        let registry = ToolRegistry()
        registry.register(BridgedHandleExecutor(name: "bridged", tracker: tracker))

        let dispatchTask = Task { @MainActor in
            await registry.dispatch(ToolCall(id: "lk", toolName: "bridged", arguments: "{}"))
        }
        // Wait until the executor has actually allocated the handle. We
        // observe this indirectly via `tracker.liveHandles == 1`. A small
        // poll is unavoidable because the executor allocates the handle
        // synchronously on entry but the dispatch hop is async.
        let allocDeadline = Date().addingTimeInterval(2)
        while tracker.liveHandles == 0 && Date() < allocDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(tracker.liveHandles, 1, "executor should have allocated exactly one handle by now")

        dispatchTask.cancel()
        let result = await dispatchTask.value
        XCTAssertEqual(result.errorKind, .cancelled)

        // The handle deinits when `withTaskCancellationHandler` unwinds with the
        // thrown `CancellationError`. That unwinding happens inside the child
        // task the default `executeStreaming` wrapper spawns, so it is ordered
        // *after* `dispatch` returns but is not synchronous with it. Bound-wait
        // for the release rather than assuming it already happened — otherwise
        // the assertion races the deinit and flakes under `--parallel`
        // main-actor contention. A genuine leak holds `liveHandles == 1` past
        // the deadline and still fails the assertion.
        let releaseDeadline = Date().addingTimeInterval(2)
        while tracker.liveHandles > 0 && Date() < releaseDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            tracker.liveHandles,
            0,
            "bridged handle leaked after cancellation — expected zero live handles, got \(tracker.liveHandles)"
        )
    }
}
