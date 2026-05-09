import XCTest
@testable import ManifoldInference

// MARK: - Helpers

private func collectVisible(_ events: [GenerationEvent]) -> String {
    events.compactMap { if case .token(let t) = $0 { return t } else { return nil } }.joined()
}

private func collectThinking(_ events: [GenerationEvent]) -> String {
    events.compactMap { if case .thinkingToken(let t) = $0 { return t } else { return nil } }.joined()
}

private func countCompletions(_ events: [GenerationEvent]) -> Int {
    events.filter { if case .thinkingComplete = $0 { return true } else { return false } }.count
}

/// Tests for `ThinkingParser` — the chunk-safe reasoning block separator.
///
/// Each test processes one or more chunks and verifies both the visible text
/// (.token events) and the thinking text (.thinkingToken events) emitted.
final class ThinkingBlockFilterTests: XCTestCase {

    // MARK: - Passthrough (no tags)

    func test_passthrough_noTags_returnsAllAsVisible() {
        var parser = ThinkingParser()
        let events = parser.process("Hello, world!")
        // No '<' in "Hello, world!" so no suffix can be a prefix of "<think>".
        // All 13 chars are emitted immediately; finalize() is a no-op.
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertEqual(collectVisible(allEvents), "Hello, world!",
            "All text with no tags should be emitted as .token events")
        XCTAssertEqual(collectThinking(allEvents), "",
            "No thinking events should be emitted when no tags are present")
        XCTAssertEqual(countCompletions(allEvents), 0)

        // Sabotage check: if ThinkingParser treated every chunk as thinking content,
        // collectVisible would return "" and this test would fail.
    }

    // MARK: - Single block

    func test_singleBlock_emitsThinkingAndVisible() {
        var parser = ThinkingParser()
        let events = parser.process("<think>reason</think>answer")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertEqual(collectThinking(allEvents), "reason",
            "Content inside <think>…</think> should be emitted as .thinkingToken")
        XCTAssertEqual(collectVisible(allEvents), "answer",
            "Content after </think> should be emitted as .token")
        XCTAssertEqual(countCompletions(allEvents), 1,
            "Exactly one .thinkingComplete event should fire on block close")

        // Sabotage check: removing the depth transition in ThinkingParser causes
        // "reason" to also appear in visible output and .thinkingComplete to not fire.
    }

    // MARK: - Split tags

    func test_splitOpenTag_acrossChunks_emitsCorrectly() {
        var parser = ThinkingParser()
        let events1 = parser.process("<thi")
        let events2 = parser.process("nk>reason</think>answer")
        let finalEvents = parser.finalize()
        let allEvents = events1 + events2 + finalEvents

        XCTAssertEqual(collectThinking(allEvents), "reason",
            "ThinkingParser must handle <think> split across chunk boundaries")
        XCTAssertEqual(collectVisible(allEvents), "answer")
        XCTAssertEqual(countCompletions(allEvents), 1)

        // Sabotage check: without holdback buffering, "<thi" would be flushed as
        // .token("< thi") before the tag is completed, corrupting visible text.
    }

    func test_splitCloseTag_acrossChunks_emitsCorrectly() {
        var parser = ThinkingParser()
        let events1 = parser.process("<think>reason</thi")
        let events2 = parser.process("nk>answer")
        let finalEvents = parser.finalize()
        let allEvents = events1 + events2 + finalEvents

        XCTAssertEqual(collectThinking(allEvents), "reason",
            "ThinkingParser must handle </think> split across chunk boundaries")
        XCTAssertEqual(collectVisible(allEvents), "answer")
        XCTAssertEqual(countCompletions(allEvents), 1)
    }

    // MARK: - Nested blocks

    func test_nestedBlocks_innerOpenTagTreatedAsThinkingText() {
        var parser = ThinkingParser()
        // ThinkingParser uses a flat scan: at depth > 0 it only looks for the close tag.
        // A nested <think> tag is treated as literal thinking text, not a depth increment.
        // Input: <think>outer<think>inner</think>still outer</think>text
        //   → depth 0: find <think>, enter thinking
        //   → depth 1: find </think>, close block at "outer<think>inner", fire .thinkingComplete
        //   → depth 0: "still outer</think>text" — no <think> found → stays in buffer/finalize
        let events = parser.process("<think>outer<think>inner</think>still outer</think>text")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        let thinking = collectThinking(allEvents)
        XCTAssertTrue(thinking.contains("outer"), "Outer block content should be in thinking")
        XCTAssertTrue(thinking.contains("inner"), "Nested <think> tag and inner content should be thinking text")

        // The close tag of the nested block ends the outer block. "still outer</think>text"
        // is emitted as visible text because the parser re-enters depth-0 mode.
        let visible = collectVisible(allEvents)
        XCTAssertTrue(visible.contains("still outer"),
            "Text after the first </think> is emitted as visible (depth returned to 0)")
        XCTAssertTrue(visible.contains("text"),
            "Text after the second </think> is also visible")

        XCTAssertEqual(countCompletions(allEvents), 1,
            "Only one .thinkingComplete fires when depth transitions from 1 to 0")

        // Sabotage check: if the parser switched to nested-depth mode, "still outer" would
        // become thinking text and this test would fail.
    }

    // MARK: - Multiple blocks

    func test_multipleBlocks_bothThinkingContentEmitted() {
        var parser = ThinkingParser()
        let events = parser.process("<think>first</think>between<think>second</think>end")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertEqual(collectThinking(allEvents), "firstsecond",
            "Both thinking blocks should contribute to thinkingToken events")
        XCTAssertEqual(collectVisible(allEvents), "betweenend",
            "Text between and after blocks should be visible")
        XCTAssertEqual(countCompletions(allEvents), 2,
            "Two distinct thinking blocks should each fire .thinkingComplete")

        // Sabotage check: if the parser reset depth incorrectly between blocks,
        // the second block's content might be emitted as .token instead of .thinkingToken.
    }

    // MARK: - Non-think angle bracket

    func test_angleBracketWithoutThink_passedThrough() {
        var parser = ThinkingParser()
        let events = parser.process("Use <b>bold</b> text")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertEqual(collectVisible(allEvents), "Use <b>bold</b> text",
            "Non-think angle brackets should pass through as visible text")
        XCTAssertEqual(collectThinking(allEvents), "")
        XCTAssertEqual(countCompletions(allEvents), 0)
    }

    // MARK: - Partial tag at stream end

    func test_partialOpenTagAtStreamEnd_flushedByFinalize() {
        var parser = ThinkingParser()
        // "<think" is a prefix of "<think>" so the entire 6 chars are held during process()
        let events = parser.process("<think")
        // finalize() must flush the partial tag as .token (still depth 0, no complete tag seen)
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        XCTAssertEqual(collectVisible(allEvents), "<think",
            "Partial <think> tag not completed by stream end should be emitted as visible text")
        XCTAssertEqual(collectThinking(allEvents), "")
        XCTAssertEqual(countCompletions(allEvents), 0)

        // Sabotage check: if finalize() were removed from the generation loop, the
        // partial tag would be silently dropped, producing an empty visible output.
    }

    // MARK: - Visible content before partial tag

    func test_visibleBeforePartialTag_emittedImmediately() {
        var parser = ThinkingParser()
        // "Hello world! " has no suffix that's a prefix of "<think>", so it's emitted
        // immediately. "<think" is a prefix of "<think>" and is held back.
        let events = parser.process("Hello world! <think")
        let finalEvents = parser.finalize()
        let allEvents = events + finalEvents

        let visible = collectVisible(allEvents)
        XCTAssertTrue(visible.hasPrefix("Hello"),
            "Content before the partial tag must be emitted as .token immediately")
        XCTAssertTrue(visible.contains("<think"),
            "The incomplete tag should be flushed by finalize() as visible text")

        // Sabotage check: if the holdback were disabled entirely, the partial tag
        // would be emitted immediately and could corrupt subsequent processing.
    }

    // MARK: - Post-think holdback flush — regression for issue #557

    /// Verifies that a post-`</think>` visible token delivered as its own chunk is
    /// emitted as a single `.token` event, not split across two events.
    ///
    /// The old fixed-holdback algorithm held back `max(open.count, close.count)` bytes
    /// at every chunk boundary. For qwen3 markers that is 8 bytes, which is larger than
    /// short tokens like "answer" (6 bytes). A 6-byte token arriving after `</think>`
    /// would sit in the buffer until the next chunk arrived, then the two chunks would
    /// be concatenated and split at the holdback boundary — producing "an" then "swermore"
    /// instead of "answer" then "more". This caused `maxOutputTokens` to count "an" as
    /// the first visible token, fire the limit, and flush "swermore" past the cap via
    /// `finalize()`.
    ///
    /// The suffix-prefix holdback (current algorithm) emits "answer" whole because no
    /// suffix of "answer" is a non-empty prefix of `<think>` — holdLength stays zero.
    func test_postThink_visibleToken_emittedAtomically_notSplitByHoldback() {
        var parser = ThinkingParser()

        // Simulate the per-chunk delivery pattern that triggered the split:
        // each token arrives as a separate process() call, exactly as a streaming
        // backend yields individual chunks.
        let e1 = parser.process("<think>")
        let e2 = parser.process("a")
        let e3 = parser.process("b")
        let e4 = parser.process("</think>")
        let e5 = parser.process("answer")   // ← must arrive whole, not split
        let e6 = parser.process("more")
        let finalEvents = parser.finalize()
        let allEvents = e1 + e2 + e3 + e4 + e5 + e6 + finalEvents

        // Collect all .token events in order.
        let visibleTokenEvents = allEvents.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }

        // Exact sequence: "answer" then "more", nothing else. The old fixed-holdback
        // algorithm would produce ["an", "swermore"] — a different count, a different
        // first element, and a spurious split — so any regression fails all three checks.
        XCTAssertEqual(visibleTokenEvents, ["answer", "more"],
            "Post-</think> visible tokens must arrive atomically: expected [\"answer\", \"more\"] but got a split sequence")

        // Sabotage check: restoring the old `let holdLength = markers.holdback` fixed-size
        // algorithm (holdback = 8 for qwen3) would hold "answer" (6 bytes) back entirely,
        // then concatenate it with "more" and emit "an" + "swermore" — causing the
        // XCTAssertEqual to fail with ["an", "swermore"] ≠ ["answer", "more"].
    }

    // MARK: - Stray close tag in visible mode (regression for PR #472)

    /// A bare `</think>` appearing when `depth == 0` (no matching open tag) must
    /// be passed through as visible text, not silently swallowed.
    ///
    /// This guards the fix carried forward from `ThinkingBlockFilter`: the old
    /// implementation had an explicit case that consumed `</think>` in visible
    /// mode without emitting it. `ThinkingParser` avoids the bug by only
    /// searching for `markers.open` at depth 0, so `</think>` never matches and
    /// is eventually flushed by the holdback logic or `finalize()`.
    func test_literalClosingTagInVisibleText_passThrough() {
        var parser = ThinkingParser()
        let events = parser.process("Visible ")
        let events2 = parser.process("</think>")
        let events3 = parser.process(" text")
        let finalEvents = parser.finalize()
        let allEvents = events + events2 + events3 + finalEvents

        XCTAssertEqual(collectVisible(allEvents), "Visible </think> text",
            "A stray </think> at depth 0 must be emitted as .token, not silently discarded")
        XCTAssertEqual(collectThinking(allEvents), "",
            "No thinking content should be emitted when there is no opening <think> tag")
        XCTAssertEqual(countCompletions(allEvents), 0,
            "No .thinkingComplete events should fire without a matching open tag")

        // Sabotage check: if ThinkingParser searched for markers.close when depth == 0,
        // </think> would be consumed and "Visible  text" would be the (wrong) visible output.
    }
}
