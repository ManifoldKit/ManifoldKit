import XCTest
import ManifoldInference
@testable import ManifoldBackends
@testable import ManifoldCloudCore

/// Unit tests for `ThinkingBlockManager` — the open/flush primitive that the
/// SSE backends share to guarantee `.thinkingCompleted` is emitted exactly
/// once on the transition out of a thinking block.
final class ThinkingBlockManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Drains a continuation by finishing the stream and collecting all yielded events.
    private func drain(_ build: (AsyncThrowingStream<GenerationEvent, Error>.Continuation) -> Void) async throws -> [GenerationEvent] {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            build(continuation)
            continuation.finish()
        }
        var events: [GenerationEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Behaviour

    func test_open_thenFlush_yieldsThinkingCompleteExactlyOnce() async throws {
        let events = try await drain { continuation in
            var manager = ThinkingBlockManager()
            manager.open()
            manager.flushIfOpen(into: continuation)
        }

        XCTAssertEqual(events.count, 1, "expected one event, got \(events)")
        guard case .thinkingCompleted = events.first else {
            return XCTFail("expected .thinkingCompleted, got \(String(describing: events.first))")
        }
    }

    func test_flushWithoutPriorOpen_isNoOp() async throws {
        let events = try await drain { continuation in
            var manager = ThinkingBlockManager()
            manager.flushIfOpen(into: continuation)
        }

        XCTAssertTrue(events.isEmpty, "expected no events, got \(events)")
    }

    func test_repeatedOpen_isIdempotent() async throws {
        let events = try await drain { continuation in
            var manager = ThinkingBlockManager()
            manager.open()
            manager.open()
            manager.open()
            // Still expect exactly one .thinkingCompleted on flush.
            manager.flushIfOpen(into: continuation)
        }

        XCTAssertEqual(events.count, 1)
    }

    func test_flushAfterFlush_isNoOp() async throws {
        let events = try await drain { continuation in
            var manager = ThinkingBlockManager()
            manager.open()
            manager.flushIfOpen(into: continuation)
            manager.flushIfOpen(into: continuation)
            manager.flushIfOpen(into: continuation)
        }

        XCTAssertEqual(events.count, 1, "second flush must not re-emit .thinkingCompleted")
    }

    func test_isOpen_reflectsState() {
        var manager = ThinkingBlockManager()
        XCTAssertFalse(manager.isOpen)
        manager.open()
        XCTAssertTrue(manager.isOpen)

        // Build a throw-away stream just to drive flush.
        _ = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            manager.flushIfOpen(into: continuation)
            continuation.finish()
        }
        XCTAssertFalse(manager.isOpen)
    }
}
