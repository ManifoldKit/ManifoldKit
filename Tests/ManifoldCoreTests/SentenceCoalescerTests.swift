import XCTest
import ManifoldInference // re-exports ManifoldContract (SentenceCoalescer, GenerationEvent)

/// Tests for ``SentenceCoalescer`` — opt-in token→sentence coalescing for
/// accessibility readback (#1828). Verifies that arbitrary fragment splits
/// (mid-word, mid-sentence, boundary split across two `push` calls) coalesce
/// into the same completed sentences, and that `flush()` / the AsyncSequence
/// wrappers surface the trailing partial.
final class SentenceCoalescerTests: XCTestCase {

    /// Reconstructs the full sentence sequence from a fragment list by feeding
    /// fragments one at a time, then flushing.
    private func segments(from fragments: [String]) -> [String] {
        var coalescer = SentenceCoalescer()
        var out: [String] = []
        for fragment in fragments {
            out.append(contentsOf: coalescer.push(fragment))
        }
        if let tail = coalescer.flush() {
            out.append(tail)
        }
        return out
    }

    func testFragmentSplittingIsInvariant() {
        // Same text, three different fragmentations including mid-word and a
        // boundary ("world." / " How") split across two push calls.
        let perChar = "Hello world. How are you? I am fine.".map(String.init)
        let chunky = ["Hello wor", "ld. How a", "re you? I a", "m fine."]
        let boundarySplit = ["Hello world", ".", " How are you?", " I am fine."]

        let expected = ["Hello world. ", "How are you? ", "I am fine."]

        XCTAssertEqual(segments(from: perChar), expected)
        XCTAssertEqual(segments(from: chunky), expected)
        XCTAssertEqual(segments(from: boundarySplit), expected)
    }

    func testFlushReturnsTrailingPartial() {
        var coalescer = SentenceCoalescer()
        var completed: [String] = []
        completed.append(contentsOf: coalescer.push("First sentence. Second one "))
        completed.append(contentsOf: coalescer.push("is incomplete"))

        // "First sentence. " is confirmed; the rest is buffered.
        XCTAssertEqual(completed, ["First sentence. "])
        XCTAssertEqual(coalescer.flush(), "Second one is incomplete")
        // Buffer drained: a second flush yields nil.
        XCTAssertNil(coalescer.flush())
    }

    func testLosslessRejoin() {
        let fragments = ["Alpha. ", "Beta? ", "Gamma!"]
        let joined = segments(from: fragments).joined()
        XCTAssertEqual(joined, "Alpha. Beta? Gamma!")
    }

    func testStringAsyncSequenceYieldsSentencesAndFlushes() async throws {
        let fragments = ["The cat sat", " on the mat.", " It was warm.", " End"]
        let stream = AsyncStream<String> { continuation in
            for f in fragments { continuation.yield(f) }
            continuation.finish()
        }

        var out: [String] = []
        for try await sentence in stream.coalescedSentences() {
            out.append(sentence)
        }
        XCTAssertEqual(out, ["The cat sat on the mat. ", "It was warm. ", "End"])
    }

    func testGenerationEventAsyncSequenceExtractsTokensAndIgnoresOthers() async throws {
        let events: [GenerationEvent] = [
            .token("One. "),
            .thinkingToken("(ignored reasoning) "),
            .token("Two. "),
            .usage(TokenUsage(promptTokens: 1, completionTokens: 2)),
            .token("Three"),
        ]
        let stream = AsyncStream<GenerationEvent> { continuation in
            for e in events { continuation.yield(e) }
            continuation.finish()
        }

        var out: [String] = []
        for try await sentence in stream.coalescedSentences() {
            out.append(sentence)
        }
        // Non-token events do not contribute text or boundaries.
        XCTAssertEqual(out, ["One. ", "Two. ", "Three"])
    }
}
