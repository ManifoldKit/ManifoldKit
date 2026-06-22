import XCTest
import Foundation
@testable import ManifoldInference

/// Coverage for ``AudioGenerationService`` — the TTS orchestration layer.
/// Drives a mock ``AudioGenerationBackend`` through the service and asserts
/// state transitions, in particular that must-complete state-restore cleanup
/// still runs when the consumer drops the stream early.
@MainActor
final class AudioGenerationServiceTests: XCTestCase {

    // MARK: - Mock backend

    /// Backend whose stream yields events on a real per-event delay so a
    /// consumer can drop the iterator mid-stream (with events still queued),
    /// forcing the `onTermination(.cancelled)` cleanup path.
    private final class SlowMockBackend: AudioGenerationBackend, @unchecked Sendable {
        let events: [AudioGenerationEvent]
        let delayPerEventNs: UInt64

        // Synchronously-read flags are only touched on the main actor by the
        // service (`stopGeneration`) and read in tests after an await, so a
        // plain stored property is sufficient.
        var isGenerating: Bool = false

        init(events: [AudioGenerationEvent], delayPerEventNs: UInt64) {
            self.events = events
            self.delayPerEventNs = delayPerEventNs
        }

        func generate(
            config: SpeechGenerationConfig
        ) throws -> AsyncThrowingStream<AudioGenerationEvent, Error> {
            isGenerating = true
            let events = self.events
            let delay = self.delayPerEventNs
            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> {
                    for event in events {
                        if Task.isCancelled { break }
                        do {
                            try await Task.sleep(nanoseconds: delay)
                        } catch {
                            break
                        }
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func stopGeneration() { isGenerating = false }
    }

    // MARK: - Tests

    func test_initialState_isIdle() {
        let service = AudioGenerationService(backend: SlowMockBackend(events: [], delayPerEventNs: 0))
        XCTAssertEqual(service.state, .idle)
    }

    func test_generate_happyPath_restoresIdleState() async throws {
        let mock = SlowMockBackend(
            events: [.progress(step: 1, total: 2), .completed(URL(fileURLWithPath: "/tmp/a.caf"))],
            delayPerEventNs: 1_000_000
        )
        let service = AudioGenerationService(backend: mock)
        let stream = service.generate(config: SpeechGenerationConfig(text: "hi"))
        XCTAssertEqual(service.state, .generating)

        for try await _ in stream {}

        try await pollUntilState(service, equals: .idle, timeoutNs: 2_000_000_000)
        XCTAssertEqual(service.state, .idle)
    }

    /// Regression: when the consumer drops the stream after the first event
    /// (with more events still queued), the service's must-complete
    /// state-restore must still run and return the service to `.idle`. Before
    /// the `[weak self]` → strong-`self` fix the restore could be dropped,
    /// leaving the service stuck in `.generating`.
    ///
    /// While the consumer holds the service alive this test passes either way
    /// — see `test_generate_consumerDropsEarly_taskRetainsServiceUntilCleanup`
    /// for the sabotage-provable variant that exercises the dealloc race.
    func test_generate_consumerDropsEarly_restoresIdleState() async throws {
        let mock = SlowMockBackend(
            events: [
                .progress(step: 1, total: 5),
                .progress(step: 2, total: 5),
                .progress(step: 3, total: 5),
                .progress(step: 4, total: 5),
                .completed(URL(fileURLWithPath: "/tmp/a.caf")),
            ],
            delayPerEventNs: 20_000_000  // 20ms
        )
        let service = AudioGenerationService(backend: mock)
        let stream = service.generate(config: SpeechGenerationConfig(text: "hello"))
        XCTAssertEqual(service.state, .generating)

        // Consume one event then drop the iterator. onTermination(.cancelled)
        // cancels the forwarding task, whose strong-self cleanup must run.
        for try await _ in stream {
            break
        }

        try await pollUntilState(service, equals: .idle, timeoutNs: 2_000_000_000)
        XCTAssertEqual(service.state, .idle, "service must return to .idle after the consumer drops the stream early")
    }

    /// Sabotage-provable regression for the dealloc race. The bug: the
    /// forwarding `Task.detached` captured `[weak self]`, so when the only
    /// strong reference to the service is dropped mid-stream the task does NOT
    /// keep it alive — the service deallocates and `await self?.restoreIdleState()`
    /// no-ops, dropping the cleanup. The fix strong-captures `self`, so the task
    /// retains the service until it finishes; the service must therefore still
    /// be alive while a generation is in flight even after every external strong
    /// reference is released.
    ///
    /// With the `[weak self]` regression `weakService` is nil immediately after
    /// the local strong ref is dropped (the service is unreachable). With the
    /// fix it stays non-nil until the in-flight task completes.
    func test_generate_consumerDropsEarly_taskRetainsServiceUntilCleanup() async throws {
        // Long per-event delay so the forwarding task is reliably still
        // in-flight when we drop our strong reference below.
        let mock = SlowMockBackend(
            events: [
                .progress(step: 1, total: 3),
                .progress(step: 2, total: 3),
                .completed(URL(fileURLWithPath: "/tmp/a.caf")),
            ],
            delayPerEventNs: 500_000_000  // 500ms
        )

        weak var weakService: AudioGenerationService?
        // Hold the stream so iteration is in flight; we deliberately do not
        // iterate it, leaving the forwarding task mid-`Task.sleep`.
        var stream: AsyncThrowingStream<AudioGenerationEvent, Error>?

        do {
            let service = AudioGenerationService(backend: mock)
            weakService = service
            stream = service.generate(config: SpeechGenerationConfig(text: "hi"))
            XCTAssertEqual(service.state, .generating)
            // `service` goes out of scope at the end of this `do` block — the
            // only remaining potential owner of the service is the forwarding
            // task (iff it strong-captured self).
        }

        // The forwarding task is still mid-flight (first event is 500ms out).
        // With the fix the task retains the service, so it is still alive.
        XCTAssertNotNil(
            weakService,
            "forwarding task must retain the service while a generation is in flight (regressed under [weak self])"
        )

        // Keep `stream` alive across the assertion above, then release it so the
        // task can finish and the service can deallocate.
        withExtendedLifetime(stream) {}
        stream = nil
    }

    /// Polls `service.state` until it equals `expected` or the timeout elapses.
    private func pollUntilState(
        _ service: AudioGenerationService,
        equals expected: AudioGenerationService.State,
        timeoutNs: UInt64
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if service.state == expected { return }
            try await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        }
    }
}
