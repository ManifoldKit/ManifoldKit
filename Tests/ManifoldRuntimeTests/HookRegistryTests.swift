import XCTest
@testable import ManifoldRuntime
import ManifoldTestSupport

/// Tests for the synchronous hook dispatch surface. Timeout test uses a
/// `TestClock` fake so the suite never burns wall-clock time on a hung
/// handler (per `feedback_task_yield_fragility`).
final class HookRegistryTests: XCTestCase {

    // MARK: - Helpers

    /// Thread-safe counter for asserting handler invocation order and skips.
    private actor Counter {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
        func snapshot() -> [String] { values }
    }

    /// Minimal fake clock that suspends `sleep(for:)` calls until the test
    /// explicitly advances time. We don't need a real virtual-time
    /// scheduler — we just need a `sleep` that never returns on its own,
    /// plus a way to release it. The test uses cancellation as the release
    /// mechanism (the registry races against this clock and cancels the
    /// timeout task when the handler-side decides the chain is done).
    ///
    /// For the timeout-fires test, we use a clock whose `sleep` returns
    /// immediately so the timeout always wins the race deterministically.
    private struct ImmediateClock: Clock {
        struct Instant: InstantProtocol {
            let rawValue: Int = 0
            func advanced(by duration: Duration) -> Instant { self }
            func duration(to other: Instant) -> Duration { .zero }
            static func < (lhs: Instant, rhs: Instant) -> Bool { false }
            static func == (lhs: Instant, rhs: Instant) -> Bool { true }
        }
        var now: Instant { Instant() }
        var minimumResolution: Duration { .zero }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            // Yield once to honour cooperative cancellation but return
            // immediately. The injected timeout fires "now" deterministically.
            await Task.yield()
        }
    }

    /// A clock released explicitly by the test after the handler has started.
    /// It makes the deadline/cancellation ordering deterministic without
    /// pretending that a virtual timeout forcibly ends arbitrary Swift code.
    private struct ControlledClock: Clock {
        struct Instant: InstantProtocol {
            let rawValue: Int = 0
            func advanced(by duration: Duration) -> Instant { self }
            func duration(to other: Instant) -> Duration { .zero }
            static func < (lhs: Instant, rhs: Instant) -> Bool { false }
            static func == (lhs: Instant, rhs: Instant) -> Bool { true }
        }

        let gate: ClockGate
        var now: Instant { Instant() }
        var minimumResolution: Duration { .zero }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try Task.checkCancellation()
            await gate.awaitFire()
            try Task.checkCancellation()
        }
    }

    private actor ClockGate {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func awaitFire() async {
            if fired { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func fire() {
            fired = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor ControlledHandler {
        private var started = false
        private var cancellationObserved = false
        private var completed = false
        private var releaseRequested = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        private var completionWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func run() async -> HookOutput {
            started = true
            let starters = startWaiters
            startWaiters.removeAll()
            for waiter in starters { waiter.resume() }

            while !Task.isCancelled && !releaseRequested {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    // Check cancellation on the next loop iteration.
                }
            }
            if Task.isCancelled {
                cancellationObserved = true
                let cancellationObservers = cancellationWaiters
                cancellationWaiters.removeAll()
                for waiter in cancellationObservers { waiter.resume() }
            }

            if !releaseRequested {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            completed = true
            let completions = completionWaiters
            completionWaiters.removeAll()
            for waiter in completions { waiter.resume() }
            return HookOutput(block: true, denyReason: "late block")
        }

        func awaitStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func awaitCancellationObserved() async {
            if cancellationObserved { return }
            await withCheckedContinuation { cancellationWaiters.append($0) }
        }

        func awaitCompletion() async {
            if completed { return }
            await withCheckedContinuation { completionWaiters.append($0) }
        }

        func release() {
            releaseRequested = true
            let pending = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    // MARK: - Tests

    func test_run_emptyRegistry_returnsPassthrough() async {
        let registry = HookRegistry()
        let input = HookInput(event: .preToolUse, sessionID: UUID())

        let output = await registry.run(input)

        XCTAssertEqual(output, .passthrough)
        // Sabotage-evidence: M1 changing `guard !chain.isEmpty else { return .passthrough }`
        // to `return HookOutput(block: true)` flips this from passthrough → blocked.
        // M2 returning `lastOutput` unconditionally after iterating zero handlers
        // would still pass (lastOutput defaults to passthrough), so M1 is the
        // load-bearing mutation. M3 removing the empty-guard early-return would
        // still pass for the same reason — the guard is a fast path, not a
        // correctness boundary. M1 is the only sabotage that fails this test.
    }

    func test_run_orderedDispatch_threadsUpdatedInput() async {
        let registry = HookRegistry()
        let observed = Counter()
        let sessionID = UUID()

        await registry.register(.preToolUse) { input in
            await observed.append("first:\(input.toolArguments ?? "nil")")
            return HookOutput(updatedInput: "{\"sanitized\": true}")
        }
        await registry.register(.preToolUse) { input in
            await observed.append("second:\(input.toolArguments ?? "nil")")
            return .passthrough
        }

        let input = HookInput(
            event: .preToolUse,
            sessionID: sessionID,
            toolName: "read_file",
            toolArguments: "{\"path\": \"./foo\"}"
        )
        _ = await registry.run(input)

        let trace = await observed.snapshot()
        XCTAssertEqual(trace, [
            "first:{\"path\": \"./foo\"}",
            "second:{\"sanitized\": true}",
        ])
        // Sabotage-evidence: M1 dropping the `current = HookInput(...)` rebind
        // (so the second handler sees the original args) flips the second
        // trace entry back to `./foo` and fails. M2 reversing the for-loop
        // order swaps the trace. M3 short-circuiting on the first non-nil
        // updatedInput would skip the second handler entirely and fail.
    }

    func test_run_blockShortCircuits() async {
        let registry = HookRegistry()
        let counter = Counter()

        await registry.register(.preToolUse) { _ in
            await counter.append("first")
            return .passthrough
        }
        await registry.register(.preToolUse) { _ in
            await counter.append("second")
            return HookOutput(block: true, denyReason: "test denial")
        }
        await registry.register(.preToolUse) { _ in
            await counter.append("third")
            return .passthrough
        }

        let output = await registry.run(HookInput(event: .preToolUse, sessionID: UUID()))

        XCTAssertTrue(output.block)
        XCTAssertEqual(output.denyReason, "test denial")
        let trace = await counter.snapshot()
        XCTAssertEqual(trace, ["first", "second"])
        // Sabotage-evidence: M1 removing the `if result.block { return result }`
        // short-circuit lets the third handler run; trace becomes
        // ["first", "second", "third"] and fails. M2 returning .passthrough
        // instead of `result` after detecting block keeps the trace correct
        // but fails the `output.block` assertion. M3 swapping the order of
        // block-check and updatedInput-thread can't be triggered here (the
        // blocking handler returns no updatedInput).
    }

    func test_run_timeoutHandler_treatedAsPassthrough() async {
        // Use ImmediateClock so the timeout task wins the race instantly.
        // The handler honours cancellation (throws on `try await Task.sleep`)
        // so the registry sees a timeout-source result and the handler's
        // would-be `block: true` return value is dropped. We assert the
        // chain continues to the next handler and the final output is NOT
        // blocked — i.e. the slow hook was treated as a no-op.
        let registry = HookRegistry(
            clock: ImmediateClock(),
            timeout: .milliseconds(1)
        )
        let counter = Counter()

        await registry.register(.preToolUse) { _ in
            await counter.append("entered")
            // The Handler signature is non-throwing, so we honour
            // cancellation by checking after the sleep. A handler that
            // *would* have returned block:true must not be allowed to
            // leak that decision after the timeout fired — the registry
            // tags the race winner and discards the late handler result.
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                await counter.append("cancelled")
                return HookOutput(block: true) // late result; should be discarded
            }
            await counter.append("returned")
            return HookOutput(block: true)
        }
        await registry.register(.preToolUse) { _ in
            await counter.append("next")
            return .passthrough
        }

        let output = await registry.run(HookInput(event: .preToolUse, sessionID: UUID()))

        let trace = await counter.snapshot()
        XCTAssertTrue(trace.contains("entered"), "trace=\(trace)")
        XCTAssertTrue(trace.contains("cancelled"), "trace=\(trace)")
        XCTAssertFalse(trace.contains("returned"), "trace=\(trace)")
        XCTAssertTrue(trace.contains("next"), "trace=\(trace)")
        XCTAssertFalse(output.block, "trace=\(trace) output=\(output)")
        // Sabotage-evidence: M1 removing the timeout task from the
        // TaskGroup race lets the slow handler block on the real clock
        // until XCTest's default 60s timeout kills the test. M2 treating
        // timeout as block:true (i.e. returning `.handler(HookOutput(block:true))`
        // for the timeout branch) would fail `XCTAssertFalse(output.block)`.
        // M3 returning the late handler result instead of the timeout's
        // passthrough (e.g. by removing the RaceWinner tagging) would let
        // a cancellation-swallowing handler still block the call.
    }

    func test_run_timeoutRequestsCancellation_ignoresLateBlock_afterHandlerReturns() async throws {
        let clockGate = ClockGate()
        let handler = ControlledHandler()
        let registry = HookRegistry(
            clock: ControlledClock(gate: clockGate),
            timeout: .milliseconds(1)
        )
        let trace = Counter()

        await registry.register(.preToolUse) { _ in
            await handler.run()
        }
        await registry.register(.preToolUse) { _ in
            await trace.append("following")
            return .passthrough
        }

        let runTask = Task {
            await registry.run(HookInput(event: .preToolUse, sessionID: UUID()))
        }

        do {
            try await withTimeout(.seconds(5)) { await handler.awaitStarted() }
            await clockGate.fire()
            try await withTimeout(.seconds(5)) { await handler.awaitCancellationObserved() }
            let followingBeforeRelease = await trace.snapshot()
            XCTAssertTrue(followingBeforeRelease.isEmpty)
            let resultSettledWhileHeld: Bool
            do {
                _ = try await withTimeout(.milliseconds(100)) { await runTask.value }
                resultSettledWhileHeld = true
            } catch {
                // `run` is non-throwing; the test deadline proves it remains
                // pending until the direct handler is released.
                resultSettledWhileHeld = false
            }
            XCTAssertFalse(resultSettledWhileHeld, "The registry must join the direct handler after requesting cancellation")
        } catch {
            // The release latch covers both a handler waiting already and one
            // that reaches its continuation after this bounded observation.
            await handler.release()
            await clockGate.fire()
            throw error
        }

        // Deterministic cleanup for the deliberately noncooperative handler.
        await handler.release()
        let output = try await withTimeout(.seconds(5)) { await runTask.value }

        XCTAssertEqual(output, .passthrough, "The late block result must be discarded after the deadline")
        let traceValues = await trace.snapshot()
        XCTAssertEqual(traceValues, ["following"], "The following handler must run after timeout-as-passthrough")
        // Sabotage-evidence: return `.handler(output)` after the timed-out
        // handler finally returns, rather than preserving the timeout winner;
        // this assertion flips to the late block and fails.
    }
}
