import XCTest
@testable import ManifoldInference

private func collectVisible(_ events: [GenerationEvent]) -> String {
    events.compactMap { if case .token(let t) = $0 { return t } else { return nil } }.joined()
}

private func collectThinking(_ events: [GenerationEvent]) -> String {
    events.compactMap { if case .thinkingToken(let t) = $0 { return t } else { return nil } }.joined()
}

private func countCompletions(_ events: [GenerationEvent]) -> Int {
    events.filter { if case .thinkingComplete = $0 { return true } else { return false } }.count
}

/// Edge-case tests for `ThinkingParser` covering boundary conditions,
/// empty blocks, finalize behaviour, and depth tracking.
final class ThinkingParserEdgeCaseTests: XCTestCase {

    // MARK: - 1. Unclosed block at stream end

    func test_unclosedBlockAtStreamEnd_flushedAsThinkingByFinalize() {
        var parser = ThinkingParser()
        let events = parser.process("<think>partial")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertFalse(allEvents.isEmpty,
            "finalize() must return at least one event for an unclosed block")
        XCTAssertTrue(collectThinking(allEvents).contains("partial"),
            "Unclosed block content must be emitted as .thinkingToken by finalize()")
        XCTAssertEqual(countCompletions(allEvents), 0,
            "An unclosed block must NOT emit .thinkingComplete")

        // Sabotage check: if finalize() returned [] for non-empty buffers, the
        // partial content would be silently discarded and this test would fail.
    }

    // MARK: - 2. Empty think block

    func test_emptyThinkBlock_emitsThinkingCompleteButNoThinkingToken() {
        var parser = ThinkingParser()
        let events = parser.process("<think></think>text")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertEqual(collectThinking(allEvents), "",
            "An empty <think></think> block should emit no .thinkingToken events")
        XCTAssertEqual(countCompletions(allEvents), 1,
            "An empty think block must still fire .thinkingComplete")
        XCTAssertEqual(collectVisible(allEvents), "text",
            "Text after the empty block should be visible")

        // Sabotage check: if the parser skipped .thinkingComplete for empty blocks,
        // the UI would never finalize an in-progress thinking accumulator.
    }

    // MARK: - 3. Multiple blocks — thinkingComplete count

    func test_multipleThinkBlocks_thinkingCompleteCountEquals2() {
        var parser = ThinkingParser()
        let events = parser.process("<think>a</think><think>b</think>")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertEqual(countCompletions(allEvents), 2,
            "Two sequential think blocks must each fire .thinkingComplete (total = 2)")
        XCTAssertEqual(collectThinking(allEvents), "ab",
            "Thinking content from both blocks must be collected")

        // Sabotage check: a parser that only fired .thinkingComplete once would
        // cause the UI to finalize after the first block, leaving the second orphaned.
    }

    // MARK: - 4. finalize on fresh parser

    func test_finalizeEmptyBuffer_returnsEmptyArray() {
        var parser = ThinkingParser()
        let finalEvents = parser.finalize()

        XCTAssertEqual(finalEvents, [],
            "finalize() on a fresh (never-processed) parser must return an empty array")

        // Sabotage check: if finalize() always emitted a placeholder event,
        // the generation loop would spuriously append empty text to the message.
    }

    // MARK: - 5. Whitespace preserved in thinking

    func test_whitespacePreservedInThinking() {
        var parser = ThinkingParser()
        let content = "  line one\n  line two\n\ttabbed"
        let events = parser.process("<think>\(content)</think>")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertEqual(collectThinking(allEvents), content,
            "Whitespace and newlines inside a think block must be preserved verbatim")

        // Sabotage check: stripping whitespace inside blocks would cause this
        // equality check to fail, breaking faithful reasoning display in the UI.
    }

    // MARK: - 6. Depth tracking — nested open tag is literal thinking text

    func test_depthTracking_nestedOpenThenClose_oneThinkingComplete() {
        var parser = ThinkingParser()
        // ThinkingParser uses a flat (non-recursive) scan: at depth > 0 it only looks for the
        // close tag. A nested <think> is treated as literal thinking text, not a depth increment.
        // Input: <think><think>inner</think>outer</think>text
        //   - depth 0: finds <think>, enters thinking mode (depth=1)
        //   - depth 1: finds first </think>; before it: "<think>inner" → .thinkingToken
        //     depth returns to 0, .thinkingComplete fires
        //   - depth 0: "outer</think>text" — no open tag found, emitted via finalize as visible
        let events = parser.process("<think><think>inner</think>outer</think>text")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        let thinking = collectThinking(allEvents)
        XCTAssertTrue(thinking.contains("inner"),
            "Content before the first </think> (including nested <think>) must be thinking")

        // After the first </think>, depth = 0. "outer</think>text" has no <think> open tag
        // so it is emitted as visible text.
        let visible = collectVisible(allEvents)
        XCTAssertTrue(visible.contains("outer"),
            "Text after the first </think> must be visible (depth is now 0)")
        XCTAssertTrue(visible.contains("text"),
            "Text at end of stream must be visible")

        XCTAssertEqual(countCompletions(allEvents), 1,
            "Exactly one .thinkingComplete fires on the single 1→0 depth transition")

        // Sabotage check: a recursive-depth implementation would require TWO </think> to reach
        // depth 0, yielding no visible text and keeping 2 completions — this test would fail.
    }
}
