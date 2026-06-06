#if Fuzz
import XCTest
@testable import ManifoldFuzz
import ManifoldInference

@MainActor
final class EventRecorderTests: XCTestCase {

    /// A stream that throws mid-thinking-block must still surface the partial
    /// reasoning it accumulated since the last `.thinkingCompleted`. Without
    /// this, detectors that rely on `thinkingRaw`/`thinkingParts` go blind on
    /// mid-stream failures (network drop, KV decode error, OOM) — they see a
    /// clean capture even though the model emitted and the harness saw real
    /// reasoning content right up to the error.
    func test_consume_flushesPartialThinkingBuffer_onMidStreamThrow() async {
        struct FuzzError: Error, Equatable { let message: String }

        let stream = GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.thinkingToken("partial-a"))
            continuation.yield(.thinkingToken("partial-b"))
            continuation.finish(throwing: FuzzError(message: "simulated mid-stream drop"))
        })

        let capture = await EventRecorder().consume(stream)

        XCTAssertEqual(capture.phase, "failed", "phase must reflect the thrown error")
        XCTAssertNotNil(capture.error, "error string must be populated on throw")
        XCTAssertEqual(capture.stopReason, "error", "stopReason classifies a throw as 'error'")
        XCTAssertEqual(
            capture.thinkingParts,
            ["partial-apartial-b"],
            "partial thinking buffer must be flushed into thinkingParts on throw"
        )
        XCTAssertEqual(
            capture.thinkingRaw,
            "partial-apartial-b",
            "thinkingRaw must retain every thinking token seen before the throw"
        )
        XCTAssertEqual(capture.thinkingCompleteCount, 0, "no thinkingCompleted event was emitted")
    }

    /// Sanity check the success path: when `.thinkingCompleted` drains the
    /// buffer, the post-loop flush is a no-op — no duplicate entries, no
    /// empty strings.
    func test_consume_successPath_doesNotDuplicateCompletedThinkingBlock() async {
        let stream = GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.thinkingToken("hello "))
            continuation.yield(.thinkingToken("world"))
            continuation.yield(.thinkingCompleted)
            continuation.yield(.token("response"))
            continuation.finish()
        })

        let capture = await EventRecorder().consume(stream)

        XCTAssertEqual(capture.phase, "done")
        XCTAssertNil(capture.error)
        XCTAssertEqual(capture.thinkingParts, ["hello world"])
        XCTAssertEqual(capture.thinkingCompleteCount, 1)
        XCTAssertEqual(capture.raw, "response")
    }
}
#endif
