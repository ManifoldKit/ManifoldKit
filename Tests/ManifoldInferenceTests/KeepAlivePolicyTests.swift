import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for ``KeepAlivePolicy`` and its idle auto-unload integration with
/// ``InferenceService``.
///
/// Timer-based tests use short idle timeouts (0.3 – 0.5 s) with 2-second
/// XCTWaiter deadlines so they run fast on CI without being flaky.
@MainActor
final class KeepAlivePolicyTests: XCTestCase {

    // MARK: - Helpers

    private func makeService() -> InferenceService {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        return InferenceService(backend: backend)
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

        // Set a 0.4-second idle timeout.
        service.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 0.4)

        // Enqueue and fully consume a generation ~0.1 s after setting the policy,
        // which should reset the idle clock to now.
        try await Task.sleep(for: .milliseconds(100))
        let (_, genStream) = try service.enqueue(
            messages: [.user("hi")],
            config: GenerationConfig()
        )
        for try await _ in genStream.events {}

        // Shortly after the generation completes the model should still be loaded
        // (idle clock was just reset).
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(
            service.isModelLoaded,
            "Model should still be loaded — activity reset the idle clock"
        )

        // But eventually (well after 0.4 s of silence post-generation) it should
        // auto-unload.
        let deadline = Date.now.addingTimeInterval(2.0)
        while service.isModelLoaded && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(
            service.isModelLoaded,
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
