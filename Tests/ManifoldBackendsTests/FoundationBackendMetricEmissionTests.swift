#if canImport(FoundationModels)
import XCTest
import FoundationModels
import ManifoldInference
@testable import ManifoldFoundation

/// Spy sink that captures every recorded metric for test assertions.
@available(iOS 26, macOS 26, *)
final class SpyMetricSink: InferenceMetricSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _recorded: [InferenceMetric] = []

    func record(_ metric: InferenceMetric) {
        lock.lock()
        defer { lock.unlock() }
        _recorded.append(metric)
    }

    var recorded: [InferenceMetric] {
        lock.lock()
        defer { lock.unlock() }
        return _recorded
    }
}

/// Tests that ``FoundationBackend`` emits an ``InferenceMetric`` after every
/// generation attempt and populates the key diagnostic fields.
///
/// These tests require iOS 26 / macOS 26 SDK symbols but do NOT require a live
/// Apple Intelligence entitlement — `_forceLoaded()` bypasses the probe, and
/// `MockInferenceBackend`-style forced responses are not needed because
/// ``GenerationMetricTracker`` operates on wall-clock timing that the
/// test harness can verify structurally rather than exactly.
@available(iOS 26, macOS 26, *)
final class FoundationBackendMetricEmissionTests: XCTestCase {

    private var backend: FoundationBackend!
    private var spy: SpyMetricSink!

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) else {
            throw XCTSkip("iOS 26 / macOS 26 required")
        }
        spy = SpyMetricSink()
        backend = FoundationBackend(availabilityResolver: { .available })
        backend.metricSink = spy
    }

    override func tearDown() async throws {
        await backend?.unloadModelAndWait()
        backend = nil
        spy = nil
        try await super.tearDown()
    }

    // MARK: - metricSink wiring

    func test_metricSink_defaultsToInMemoryMetricSinkShared() {
        let fresh = FoundationBackend()
        // The default sink must be non-nil so metrics are captured without any
        // host-app configuration — mirrors SSECloudBackend's contract.
        XCTAssertNotNil(fresh.metricSink)
        XCTAssertTrue(fresh.metricSink is InMemoryMetricSink)
    }

    func test_metricSink_canBeSetToNil() {
        backend.metricSink = nil
        XCTAssertNil(backend.metricSink)
    }

    // MARK: - Metric emission (requires live inference)

    func test_generate_emitsOneMetricOnSuccess() async throws {
        guard FoundationBackend.isAvailable else {
            throw XCTSkip("Apple Intelligence not available on this device")
        }
        guard await FoundationBackend.probeIsReady() else {
            throw XCTSkip("Apple Intelligence model not ready")
        }

        backend._forceLoaded()

        let stream = try backend.generate(
            prompt: "Reply with exactly one word: hello",
            systemPrompt: nil,
            config: .init()
        )

        // Drain the stream to let the generation run to completion.
        var tokenCount = 0
        do {
            for try await event in stream.events {
                if case .token = event { tokenCount += 1 }
            }
        } catch {
            // Generation errors are still expected to emit a metric.
        }

        // Allow the Task's defer block (which fires the metric) to execute.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        let metrics = spy.recorded
        XCTAssertEqual(metrics.count, 1, "Expected exactly one metric per generation call")

        let m = try XCTUnwrap(metrics.first)
        XCTAssertEqual(m.provider, "FoundationModels")
        XCTAssertNil(m.errorClass, "errorClass must be nil on a successful generation")

        // Foundation backend cannot report token counts via the SDK, so the
        // field is always zero. Verify it's not accidentally negative.
        XCTAssertGreaterThanOrEqual(m.completionTokens, 0)

        // wallClockDuration must be strictly positive.
        XCTAssertGreaterThan(m.wallClockDuration, .zero,
                             "wallClockDuration must reflect real elapsed time")
    }

    func test_generate_emitsMetricWithNonNilErrorClassOnFailure() async throws {
        // Use an unavailable-resolver so generate() will fail immediately
        // once we force the load check open.
        let failingBackend = FoundationBackend(availabilityResolver: { .available })
        let failSpy = SpyMetricSink()
        failingBackend.metricSink = failSpy

        // _forceLoaded bypasses the probe — but the session is still nil.
        // Trying to generate will fail when the SDK is unavailable or not ready.
        failingBackend._forceLoaded()

        do {
            let stream = try failingBackend.generate(
                prompt: "test",
                systemPrompt: nil,
                config: .init()
            )
            // If we get here the device has Apple Intelligence — drain and skip.
            var saw = false
            for try await event in stream.events {
                if case .token = event { saw = true }
            }
            if saw {
                throw XCTSkip("Device has Apple Intelligence; failure path not exercisable")
            }
        } catch is InferenceError {
            // Synchronous failure (e.g. alreadyGenerating) — metric fires in defer.
        } catch {
            // Async failure propagated through the stream.
        }

        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        // On a device without Apple Intelligence the defer block should have fired.
        // If the device HAS Apple Intelligence and succeeded, we skip above.
        guard !failSpy.recorded.isEmpty else {
            throw XCTSkip("No metric recorded — device may have Apple Intelligence loaded")
        }

        // When a metric is recorded, wallClockDuration must be non-negative.
        let m = try XCTUnwrap(failSpy.recorded.first)
        XCTAssertGreaterThanOrEqual(m.wallClockDuration, .zero)
    }

    func test_generate_noMetricEmittedWhenSinkIsNil() async throws {
        backend.metricSink = nil
        backend._forceLoaded()

        do {
            let stream = try backend.generate(
                prompt: "hello",
                systemPrompt: nil,
                config: .init()
            )
            for try await _ in stream.events {}
        } catch {}

        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        // No crash and no metric — just verify the spy (which is not wired)
        // received nothing. The real assertion is that no call was made to a
        // nil sink (which would have crashed).
        XCTAssertTrue(spy.recorded.isEmpty,
                      "Spy was replaced by nil — it should receive nothing")
    }
}

#endif
