@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldInference

/// Coverage for ``VideoGenerationService`` — the cloud-video orchestration
/// layer. Drives a mock ``VideoGenerationBackend`` through the service and
/// asserts state transitions and stream event forwarding.
@MainActor
final class VideoGenerationServiceTests: XCTestCase {

    // MARK: - Mock backend

    /// Controllable ``VideoGenerationBackend`` for unit-testing the service.
    /// All state is guarded by `OSAllocatedUnfairLock` so the backing
    /// `Task` (off the main actor) can update flags without a race.
    final class MockVideoBackend: VideoGenerationBackend, @unchecked Sendable {

        struct Plan: Sendable {
            var events: [VideoGenerationEvent] = []
            /// When non-nil the stream throws this after all events.
            var trailingError: (any Error)?
            /// Thrown from `generate(...)` itself before a stream is returned.
            var submitError: (any Error)?
            /// Delay between events — set to a large value in cancellation tests.
            var delayPerEventNs: UInt64 = 1_000_000  // 1ms
        }

        private struct State: Sendable {
            var plan = Plan()
            var cancelCalled = false
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        var cancelCalled: Bool { lock.withLock { $0.cancelCalled } }

        func setPlan(_ plan: Plan) {
            lock.withLock { $0.plan = plan }
        }

        func generate(
            prompt: String,
            config: VideoGenerationConfig
        ) async throws -> AsyncThrowingStream<VideoGenerationEvent, Error> {
            let plan = lock.withLock { $0.plan }

            if let error = plan.submitError {
                throw error
            }

            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> {
                    for event in plan.events {
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: plan.delayPerEventNs)
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    if let trailing = plan.trailingError, !Task.isCancelled {
                        continuation.finish(throwing: trailing)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func cancel() async {
            lock.withLock { $0.cancelCalled = true }
        }
    }

    // MARK: - Helpers

    private static let config = VideoGenerationConfig(
        duration: 5,
        aspectRatio: VideoGenerationConfig.AspectRatio.landscape
    )

    // MARK: - Tests

    func test_initialState_isIdle() {
        let service = VideoGenerationService(backend: MockVideoBackend())
        XCTAssertEqual(service.state, .idle)
    }

    func test_generate_stateIsGeneratingAfterSubmit() async throws {
        let backend = MockVideoBackend()
        backend.setPlan(.init(events: [
            .queued,
            .generating(fractionComplete: 0.5),
            .completed(URL(fileURLWithPath: "/tmp/vid.mp4"))
        ]))

        let service = VideoGenerationService(backend: backend)
        let stream = try await service.generate(prompt: "test", config: Self.config)
        // State is set to .generating before `generate` returns.
        XCTAssertEqual(service.state, .generating)
        // Drain to let the detached task finish.
        for try await _ in stream {}
    }

    func test_generate_alreadyGenerating_throws() async throws {
        let backend = MockVideoBackend()
        // Long delay so the stream stays open long enough to call `generate` again.
        backend.setPlan(.init(
            events: [.generating(fractionComplete: 0.0)],
            delayPerEventNs: 500_000_000  // 500ms
        ))

        let service = VideoGenerationService(backend: backend)
        let _ = try await service.generate(prompt: "first", config: Self.config)

        do {
            let _ = try await service.generate(prompt: "second", config: Self.config)
            XCTFail("Expected alreadyGenerating error")
        } catch VideoGenerationServiceError.alreadyGenerating {
            // expected
        }
    }

    func test_generate_submissionError_throwsAndResetsToIdle() async throws {
        struct SubmitError: Error {}
        let backend = MockVideoBackend()
        backend.setPlan(.init(submitError: SubmitError()))

        let service = VideoGenerationService(backend: backend)

        do {
            let _ = try await service.generate(prompt: "x", config: Self.config)
            XCTFail("Expected error to propagate")
        } catch is SubmitError {
            // expected
        }

        // State is reset synchronously in the catch block before the error
        // propagates to the caller — no actor-hop race here.
        XCTAssertEqual(service.state, .idle)
    }

    func test_generate_streamEventsForwarded() async throws {
        let videoURL = URL(fileURLWithPath: "/tmp/output.mp4")
        let backend = MockVideoBackend()
        backend.setPlan(.init(events: [
            .queued,
            .generating(fractionComplete: 0.3),
            .generating(fractionComplete: 0.7),
            .completed(videoURL)
        ]))

        let service = VideoGenerationService(backend: backend)
        let stream = try await service.generate(prompt: "a sunset", config: Self.config)

        var collected: [VideoGenerationEvent] = []
        for try await event in stream {
            collected.append(event)
        }

        XCTAssertEqual(collected.count, 4)
        guard case .queued = collected[0] else {
            return XCTFail("Expected .queued at index 0, got \(collected[0])")
        }
        guard case .generating(let f1) = collected[1] else {
            return XCTFail("Expected .generating at index 1")
        }
        XCTAssertEqual(f1, 0.3, accuracy: 0.001)
        guard case .generating(let f2) = collected[2] else {
            return XCTFail("Expected .generating at index 2")
        }
        XCTAssertEqual(f2, 0.7, accuracy: 0.001)
        guard case .completed(let url) = collected[3] else {
            return XCTFail("Expected .completed at index 3")
        }
        XCTAssertEqual(url, videoURL)
    }

    func test_generate_trailingStreamError_propagates() async throws {
        struct NetworkError: Error {}
        let backend = MockVideoBackend()
        backend.setPlan(.init(
            events: [.queued, .generating(fractionComplete: 0.5)],
            trailingError: NetworkError()
        ))

        let service = VideoGenerationService(backend: backend)
        let stream = try await service.generate(prompt: "x", config: Self.config)

        do {
            for try await _ in stream {}
            XCTFail("Expected stream to throw")
        } catch is NetworkError {
            // expected
        }
    }
}
