import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for ``KeepAlivePolicy`` and its idle auto-unload integration with
/// ``InferenceService``.
///
/// ## Timing under CI scheduling starvation
///
/// The idle watch task polls a **wall-clock** `idleDuration` against the
/// configured `idleTimeout`. Under `swift test --parallel` on a CPU-
/// oversubscribed CI runner, any `Task.sleep` the test issues can overrun its
/// nominal duration by hundreds of milliseconds. Earlier revisions of this
/// suite armed a short timeout (0.3–0.5 s) and then `sleep`-ed before doing the
/// work whose effect they wanted to observe; when that pre-work sleep stretched
/// past the timeout, the watch task auto-unloaded the model *before the work
/// ran*, producing spurious `"No model loaded"` failures (and false negatives
/// for the "activity keeps the model loaded" assertion).
///
/// To stay robust against arbitrary scheduling jitter these tests follow two
/// rules:
///   1. **Never sleep on the critical path before the action under test.** A
///      freshly loaded service that has never generated reports
///      `idleDuration == .infinity`, so any armed timeout would fire on its
///      first poll. We establish activity (or arm the policy) only at the point
///      we actually want the clock to start.
///   2. **Use a large timeout relative to the observation window, and poll**
///      rather than sleeping a fixed amount then asserting. The "stays loaded"
///      window is a small fraction of the timeout, and the "eventually unloads"
///      check polls against a generous deadline. Jitter that is small relative
///      to the timeout can no longer flip the outcome.
@MainActor
final class KeepAlivePolicyTests: XCTestCase {

    // MARK: - Helpers

    private func makeService() -> InferenceService {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        return InferenceService(backend: backend)
    }

    /// Polls `condition` until it is true or the deadline elapses.
    /// - Returns: `true` if the condition became true before the deadline.
    @discardableResult
    private func poll(
        timeout: TimeInterval,
        interval: Duration = .milliseconds(20),
        until condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: interval)
        }
        return condition()
    }

    // MARK: - KeepAlivePolicy value semantics

    func test_keepAlivePolicy_defaultIsNever() {
        let service = makeService()
        XCTAssertNil(service.keepAlivePolicy.idleTimeout)
        XCTAssertEqual(service.keepAlivePolicy, .never)
    }

    func test_keepAlivePolicy_equatable() {
        XCTAssertEqual(KeepAlivePolicy.never, KeepAlivePolicy(idleTimeout: nil))
        XCTAssertNotEqual(KeepAlivePolicy(idleTimeout: 30), KeepAlivePolicy(idleTimeout: 60))
        XCTAssertNotEqual(KeepAlivePolicy.never, KeepAlivePolicy(idleTimeout: 30))
    }

    // MARK: - Default .never does NOT auto-unload

    func test_never_policy_doesNotUnload() async throws {
        let service = makeService()
        // .never is the default; model is loaded.
        XCTAssertTrue(service.isModelLoaded)

        // Wait briefly — no unload should occur.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(
            service.isModelLoaded,
            "Model should remain loaded when keepAlivePolicy is .never"
        )
    }

    // MARK: - Policy fires after idle timeout

    func test_idleTimeout_unloadsAfterIdle() async throws {
        let service = makeService()
        XCTAssertTrue(service.isModelLoaded)

        // Record any unload events so we can verify the reason.
        var unloadReasons: [UnloadReason] = []
        let stream = service.memoryPressureEvents()
        let eventTask = Task { @MainActor in
            for await event in stream {
                if case .didUnload(_, let reason) = event {
                    unloadReasons.append(reason)
                }
            }
        }
        defer { eventTask.cancel() }

        // Set a 0.3-second idle timeout — short enough that the watch task fires
        // before our 2-second test deadline, long enough to not be flaky.
        service.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 0.3)

        // Wait up to 2 seconds for the model to be auto-unloaded.
        let deadline = Date.now.addingTimeInterval(2.0)
        while service.isModelLoaded && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(service.isModelLoaded, "Model should have been auto-unloaded after idle timeout")

        // Allow the event stream task a tick to collect the event.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(
            unloadReasons.contains(.idleTimeout),
            "MemoryPressureEvent should carry UnloadReason.idleTimeout; got \(unloadReasons)"
        )
    }

    // MARK: - Activity resets the idle clock

    func test_activity_resetsIdleClock() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        // Provide tokens so the generation stream has something to consume.
        backend.tokensToYield = ["hello"]
        let service = InferenceService(backend: backend)

        // Establish real generation activity FIRST, while the policy is still
        // `.never`. This is the critical ordering: a service that has never
        // generated reports `idleDuration == .infinity`, so arming a timeout
        // before any activity would unload on the very first poll — and any
        // pre-generate sleep racing that poll is exactly the CI-starvation flake
        // this test previously suffered. By generating before arming, the idle
        // clock starts from a concrete `lastActivityTimestamp`, not `.infinity`.
        let (_, genStream) = try service.enqueue(
            messages: [.user("hi")],
            config: GenerationConfig()
        )
        for try await _ in genStream.events {}
        XCTAssertTrue(service.isModelLoaded, "Model loaded after a fresh generation")

        // Now arm a generous timeout. The watch task polls wall-clock idle time;
        // 5 s is far larger than any plausible scheduling jitter in the short
        // "stays loaded" window below, so jitter cannot prematurely unload.
        service.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 5.0)

        // For a window much shorter than the timeout the model must stay loaded:
        // the just-completed generation reset the idle clock. We poll and assert
        // it never drops — if `isModelLoaded` flips to false the poll returns
        // early and the assertion below catches it.
        let stayedLoaded = try await poll(timeout: 0.4) { !service.isModelLoaded }
        XCTAssertFalse(
            stayedLoaded,
            "Model should stay loaded well within the idle timeout — activity reset the clock"
        )
        XCTAssertTrue(service.isModelLoaded)

        // Eventually, after silence exceeding the timeout, it must auto-unload.
        // Shrink the timeout to a small value now (the watch task re-reads the
        // current policy each poll) so we don't wait the full 5 s; the idle clock
        // already carries the elapsed-since-generation time, so this fires
        // promptly without ever having raced an empty (`.infinity`) idle window.
        service.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 0.3)
        let didUnload = try await poll(timeout: 3.0) { !service.isModelLoaded }
        XCTAssertTrue(
            didUnload,
            "Model should eventually auto-unload after activity silence"
        )
    }

    // MARK: - Policy disabled at runtime before timeout fires

    func test_policyDisabledBeforeTimeout_keepsModelLoaded() async throws {
        let service = makeService()
        XCTAssertTrue(service.isModelLoaded)

        // Arm a 0.5-second timeout.
        service.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 0.5)

        // Immediately disable it — the watch task should be cancelled.
        service.keepAlivePolicy = .never

        // Wait beyond what the timeout would have been.
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertTrue(
            service.isModelLoaded,
            "Model should remain loaded after the policy was reverted to .never"
        )
    }

    // MARK: - Explicit unload cancels the watch task (no double-unload)

    // MARK: - Preemptive eviction on .warning (#1931)

    /// Collects every `didUnload` reason emitted by the service so a test can
    /// assert *which* reason drove an eviction (or that none did).
    @MainActor
    private func collectUnloadReasons(
        from service: InferenceService
    ) -> (reasons: () -> [UnloadReason], task: Task<Void, Never>) {
        let box = UnloadReasonBox()
        let stream = service.memoryPressureEvents()
        let task = Task { @MainActor in
            for await event in stream {
                if case .didUnload(_, let reason) = event {
                    box.append(reason)
                }
            }
        }
        return ({ box.snapshot() }, task)
    }

    func test_warning_idleModel_preemptivelyEvicts() async throws {
        let service = makeService()
        XCTAssertTrue(service.isModelLoaded)

        // Opt in with a zero grace window: a freshly-loaded model that has never
        // generated reports idleDuration == .infinity, so it is immediately past
        // any grace window — the warning should evict it straight away.
        service.keepAlivePolicy = KeepAlivePolicy(idleTimeout: nil, evictOnMemoryWarning: true, memoryWarningGrace: 0)

        let (reasons, eventTask) = collectUnloadReasons(from: service)
        defer { eventTask.cancel() }

        service.notifyPressureLevel(.warning)

        let didUnload = try await poll(timeout: 1.0) { !service.isModelLoaded }
        XCTAssertTrue(didUnload, "An idle model should be preemptively evicted on .warning when evictOnMemoryWarning is true")

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(
            reasons().contains(.backgroundEviction),
            "Preemptive .warning eviction must carry UnloadReason.backgroundEviction; got \(reasons())"
        )
    }

    func test_warning_busyModel_doesNotEvict() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["one", "two"]
        // Gate the token emission so the generation is held in-flight: the mock
        // awaits the gate BEFORE yielding each token, so once a turn starts the
        // service reports isGenerating == true until we advance the gate.
        let gate = TokenEmissionGate()
        backend.tokenEmissionGate = gate
        let service = InferenceService(backend: backend)

        // Zero grace window so the ONLY thing standing between a .warning and an
        // eviction is the busy guard — this is what the sabotage check flips.
        service.keepAlivePolicy = KeepAlivePolicy(idleTimeout: nil, evictOnMemoryWarning: true, memoryWarningGrace: 0)

        let (token, stream) = try service.enqueue(messages: [.user("hi")], config: GenerationConfig())
        let drain = Task { @MainActor in
            for try await _ in stream.events {}
        }
        defer {
            drain.cancel()
            service.cancel(token)
        }

        // Wait until the turn is actually in flight (the mock is parked on the
        // gate before its first token).
        let becameBusy = try await poll(timeout: 1.0) { service.isGenerating }
        XCTAssertTrue(becameBusy, "Generation should be in flight before we send the warning")

        service.notifyPressureLevel(.warning)

        // Give the (non-)eviction path a moment to run; the model must stay loaded.
        let stayedLoaded = try await poll(timeout: 0.4) { !service.isModelLoaded }
        XCTAssertFalse(stayedLoaded, "A .warning must NOT evict a BUSY model — generation in flight")
        XCTAssertTrue(service.isModelLoaded)
        XCTAssertTrue(service.isGenerating)

        // Let the generation finish cleanly so the gate doesn't leak.
        await gate.advance()
        await gate.advance()
    }

    func test_warning_defaultPolicy_isNoOp() async throws {
        let service = makeService()
        XCTAssertTrue(service.isModelLoaded)

        // Default policy: evictOnMemoryWarning == false. A .warning must do nothing.
        XCTAssertFalse(service.keepAlivePolicy.evictOnMemoryWarning)

        service.notifyPressureLevel(.warning)

        let evicted = try await poll(timeout: 0.4) { !service.isModelLoaded }
        XCTAssertFalse(evicted, "With the default policy a .warning must be a no-op — only .critical evicts")
        XCTAssertTrue(service.isModelLoaded)
    }

    func test_explicitUnload_doesNotTriggerSecondUnload() async throws {
        let service = makeService()
        XCTAssertTrue(service.isModelLoaded)

        var didUnloadCount = 0
        let stream = service.memoryPressureEvents()
        let eventTask = Task { @MainActor in
            for await event in stream {
                if case .didUnload = event { didUnloadCount += 1 }
            }
        }
        defer { eventTask.cancel() }

        service.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 0.5)

        // Explicitly unload before the timer fires.
        service.unloadModel()
        XCTAssertFalse(service.isModelLoaded)

        // Wait beyond the timeout window.
        try await Task.sleep(for: .milliseconds(700))

        // Allow the event stream task a tick to collect events.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(didUnloadCount, 1, "Only one unload event should fire — the explicit one")
    }
}

/// MainActor-confined collector for unload reasons observed on the event stream.
/// The collecting `Task` is `@MainActor`, so plain mutation is race-free.
@MainActor
private final class UnloadReasonBox {
    private var reasons: [UnloadReason] = []
    func append(_ reason: UnloadReason) { reasons.append(reason) }
    func snapshot() -> [UnloadReason] { reasons }
}
