import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFuzz

/// Verifies `EventRecorder.consume` bounds `raw`/`thinkingRaw`/`events` for a
/// generation that never naturally stops, rather than accumulating them
/// unboundedly (see #2266's fuzz-harness-timeout-hardening PR). A genuinely
/// runaway/looping model is exactly the anomaly the fuzzer exists to catch,
/// so truncation must keep the TAIL of `raw`/`thinkingRaw` — `LoopingDetector`
/// reads a suffix of those buffers to detect repetition — while still
/// bounding total memory.
final class EventRecorderTruncationTests: XCTestCase {

    private func loadedBackend(tokensToYield: [String]) async throws -> MockInferenceBackend {
        let backend = MockInferenceBackend()
        backend.tokensToYield = tokensToYield
        try await backend.loadModel(from: URL(string: "mock:mock-model")!, plan: .cloud())
        return backend
    }

    /// A single token far larger than `maxBufferedCharacters` is truncated to
    /// exactly the cap, keeping the most recent characters (the tail), and
    /// `truncated` is set.
    func test_consume_oversizedRaw_truncatesToTailAndSetsFlag() async throws {
        let head = String(repeating: "A", count: EventRecorder.maxBufferedCharacters + 1_000_000)
        let tail = String(repeating: "B", count: 500)
        let backend = try await loadedBackend(tokensToYield: [head + tail])

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let capture = await EventRecorder().consume(stream)

        XCTAssertTrue(capture.truncated)
        XCTAssertEqual(capture.raw.count, EventRecorder.maxBufferedCharacters)
        XCTAssertTrue(
            capture.raw.hasSuffix(tail),
            "truncation must drop from the front and preserve the tail, which is where a real repeating-loop pattern lives"
        )
    }

    /// Same guarantee for `thinkingRaw` — the reasoning-channel buffer is
    /// capped independently of `raw`.
    func test_consume_oversizedThinkingRaw_truncatesToTailAndSetsFlag() async throws {
        let head = String(repeating: "X", count: EventRecorder.maxBufferedCharacters + 1_000_000)
        let tail = String(repeating: "Y", count: 500)
        let backend = try await loadedBackend(tokensToYield: ["done"])
        backend.thinkingTokensToYield = [head + tail]

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let capture = await EventRecorder().consume(stream)

        XCTAssertTrue(capture.truncated)
        XCTAssertEqual(capture.thinkingRaw.count, EventRecorder.maxBufferedCharacters)
        XCTAssertTrue(capture.thinkingRaw.hasSuffix(tail))
    }

    /// A run comfortably under the cap is never truncated — the safety valve
    /// must not fire on ordinary bounded generations.
    func test_consume_normalRun_isNotTruncated() async throws {
        let backend = try await loadedBackend(tokensToYield: ["Hello", " ", "world", "."])
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let capture = await EventRecorder().consume(stream)

        XCTAssertFalse(capture.truncated)
        XCTAssertEqual(capture.raw, "Hello world.")
    }

    /// `events.count` is capped independently of the string buffers — a
    /// generation emitting far more discrete events than any bounded
    /// `maxOutputTokens` run would produce still yields a bounded `events`
    /// array, keeping the most recent entries.
    func test_consume_tooManyEvents_capsEventCountAndSetsFlag() async throws {
        let tokenCount = EventRecorder.maxBufferedEvents + 10
        let tokens = (0..<tokenCount).map { "t\($0) " }
        let backend = try await loadedBackend(tokensToYield: tokens)

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        let capture = await EventRecorder().consume(stream)

        XCTAssertTrue(capture.truncated)
        XCTAssertEqual(capture.events.count, EventRecorder.maxBufferedEvents)
        // The most recently emitted token should be the last one requested —
        // proof the drop happened at the front, not the back.
        XCTAssertEqual(capture.events.last?.v, tokens.last)
    }
}
