import XCTest
@testable import ManifoldInference

// MARK: - Helpers

private func visibleTokens(_ events: [GenerationEvent]) -> [String] {
    events.compactMap { if case .token(let t) = $0 { return t } else { return nil } }
}

private func visibleText(_ events: [GenerationEvent]) -> String {
    visibleTokens(events).joined()
}

private func thinkingText(_ events: [GenerationEvent]) -> String {
    events.compactMap { if case .thinkingToken(let t) = $0 { return t } else { return nil } }.joined()
}

private func completions(_ events: [GenerationEvent]) -> Int {
    events.filter { if case .thinkingCompleted = $0 { return true } else { return false } }.count
}

/// Tests for `ThinkingTransform.trimLeadingNewlineAfterClose` (issue #1845).
///
/// Reasoning models (Qwen3, DeepSeek-R1) emit a leading newline run right after
/// `</think>` before the visible answer. The opt-in trim strips that run on the
/// depth 1→0 boundary; the default leaves output byte-for-byte verbatim.
final class ThinkingTransformTrimTests: XCTestCase {

    // MARK: - Option ON: trims a single \r\n run

    func test_trimOn_stripsLeadingCRLF_afterClose() {
        var parser = ThinkingParser(trimLeadingNewlineAfterClose: true)
        let events = parser.process("<think>reasoning</think>\r\nVisible answer")
        let all = events + parser.finalize()

        XCTAssertEqual(visibleText(all), "Visible answer",
            "Leading \\r\\n after </think> must be stripped when trim is enabled")
        XCTAssertEqual(thinkingText(all), "reasoning",
            "Thinking content must be unaffected by the trim")
        XCTAssertEqual(completions(all), 1,
            ".thinkingCompleted must still fire on block close")
    }

    // MARK: - Option ON: strips an entire \n\n run

    func test_trimOn_stripsEntireLeadingNewlineRun() {
        var parser = ThinkingParser(trimLeadingNewlineAfterClose: true)
        let events = parser.process("<think>reasoning</think>\n\nVisible answer")
        let all = events + parser.finalize()

        XCTAssertEqual(visibleText(all), "Visible answer",
            "The whole leading newline run after </think> must be stripped, not just the first newline")
        XCTAssertEqual(thinkingText(all), "reasoning")
        XCTAssertEqual(completions(all), 1)
    }

    // MARK: - Option OFF (default): verbatim regression guard

    func test_trimOff_preservesLeadingCRLF_verbatim() {
        var parser = ThinkingParser()  // default: trimLeadingNewlineAfterClose == false
        let events = parser.process("<think>reasoning</think>\r\nVisible answer")
        let all = events + parser.finalize()

        XCTAssertEqual(visibleText(all), "\r\nVisible answer",
            "Default behaviour must preserve the leading \\r\\n verbatim (no trim)")
        XCTAssertEqual(thinkingText(all), "reasoning")
        XCTAssertEqual(completions(all), 1)
    }

    // MARK: - Trim only touches the close boundary, not other newlines

    func test_trimOn_doesNotStripNewlinesElsewhereInVisible() {
        var parser = ThinkingParser(trimLeadingNewlineAfterClose: true)
        // Newline run AFTER the first visible char must survive — only the run
        // immediately following </think> is trimmed.
        let events = parser.process("<think>reasoning</think>\nLine one\n\nLine two")
        let all = events + parser.finalize()

        XCTAssertEqual(visibleText(all), "Line one\n\nLine two",
            "Only the leading newline run after </think> is trimmed; interior newlines stay")
        XCTAssertEqual(thinkingText(all), "reasoning")
        XCTAssertEqual(completions(all), 1)
    }

    // MARK: - Works across chunk splits

    func test_trimOn_acrossChunkSplits_thinkingUnaffected_andTrimApplied() {
        var parser = ThinkingParser(trimLeadingNewlineAfterClose: true)
        // Thinking content and the close marker straddle chunk boundaries; the
        // newline run is delivered in the same chunk as the close marker (the
        // realistic streaming shape — the close tag and its trailing newline run
        // arrive together).
        let e1 = parser.process("<thi")
        let e2 = parser.process("nk>rea")
        let e3 = parser.process("soning</think>\r\nVisible answer")
        let all = e1 + e2 + e3 + parser.finalize()

        XCTAssertEqual(thinkingText(all), "reasoning",
            "Thinking text must reassemble correctly across split open/close markers")
        XCTAssertEqual(visibleText(all), "Visible answer",
            "Trim must apply on the close boundary even when markers were split across chunks")
        XCTAssertEqual(completions(all), 1)
    }
}
