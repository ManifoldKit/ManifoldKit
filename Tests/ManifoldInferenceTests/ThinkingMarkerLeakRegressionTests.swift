import XCTest
@testable import ManifoldInference

/// Regression tests for the non-ChatML thinking-marker leak — DeepSeek-R1 GGUFs
/// and similar reasoning models using the Llama3 prompt template still emit
/// `<think>…</think>` blocks. The driver originally ran a 64-byte sniff window
/// at generate time; that has been replaced by load-time auto-detection
/// (`LlamaModelLoader.readChatTemplateMetadata` + `ThinkingMarkers.fromChatTemplate`).
/// These tests still pin the underlying `ThinkingParser` semantics that both
/// the old sniff replay and the new explicit-markers path depend on.
final class ThinkingMarkerLeakRegressionTests: XCTestCase {

    // MARK: - Helpers

    private func collectVisible(_ events: [GenerationEvent]) -> String {
        events.compactMap { if case .token(let t) = $0 { return t } else { return nil } }.joined()
    }

    private func collectThinking(_ events: [GenerationEvent]) -> String {
        events.compactMap { if case .thinkingToken(let t) = $0 { return t } else { return nil } }.joined()
    }

    private func countCompletions(_ events: [GenerationEvent]) -> Int {
        events.filter { if case .thinkingCompleted = $0 { return true } else { return false } }.count
    }

    // MARK: - Sniff-Replay Contract

    /// Core regression: a reasoning model using the Llama3 template emits
    /// "<think>reasoning</think>visible answer". When the driver buffers that
    /// prefix in sniff mode and replays it through `ThinkingParser(.qwen3)`,
    /// the parser must separate `reasoning` into `.thinkingToken` events,
    /// emit one `.thinkingCompleted`, and yield `visible answer` as `.token`.
    ///
    /// Before the fix, the Llama3 template disabled `ThinkingParser` entirely
    /// (`PromptTemplate.llama3.thinkingMarkers == nil`) and the raw `<think>`
    /// bytes leaked into `.token` events, rendering as literal tags in the UI.
    ///
    /// Sabotage check: change the feed below to `.token(...)` unconditionally
    /// (simulating the pre-fix driver). `collectThinking` returns "" and this
    /// assertion fails — proving the test catches the regression the fix was
    /// written for.
    func test_sniffBufferReplay_splitsThinkingFromVisible_singleChunk() {
        // Fresh parser for `.qwen3` markers — the markers the driver replays with
        // when the sniffer fires on a template that reported nil markers.
        var parser = ThinkingParser(markers: .qwen3)
        // The exact combined chunk the driver would replay from its 64-byte
        // sniff buffer after detecting `<think>`.
        let chunk = "<think>reasoning</think>visible answer"
        let events = parser.process(chunk)
        let finalEvents = parser.finalize()
        let all = events + finalEvents

        XCTAssertEqual(collectThinking(all), "reasoning",
                       "The content between <think> and </think> must be routed to .thinkingToken")
        XCTAssertEqual(collectVisible(all), "visible answer",
                       "Content after </think> must be routed to .token — not leaked as raw tags")
        XCTAssertEqual(countCompletions(all), 1,
                       "Exactly one .thinkingCompleted must fire on the 1→0 depth transition")
        XCTAssertFalse(collectVisible(all).contains("<think>"),
                       "Raw <think> must NEVER appear in visible tokens — that is the leak we are preventing")
        XCTAssertFalse(collectVisible(all).contains("</think>"),
                       "Raw </think> must NEVER appear in visible tokens")
    }

    /// Replay with a non-tag prefix: the sniff window may have accumulated
    /// plain text before `<think>` (e.g. "The answer is <think>...</think>").
    /// That prefix must flow to `.token`, not get lost or duplicated.
    ///
    /// Sabotage check: change `ThinkingParser.process`'s "before the tag"
    /// branch to drop the pre-tag text. `collectVisible` no longer contains
    /// "Prefix. " and this assertion fails.
    func test_sniffBufferReplay_preservesTextBeforeThinkOpenTag() {
        var parser = ThinkingParser(markers: .qwen3)
        let chunk = "Prefix. <think>analysis</think>Final."
        let events = parser.process(chunk)
        let finalEvents = parser.finalize()
        let all = events + finalEvents

        XCTAssertTrue(collectVisible(all).contains("Prefix. "),
                      "Text before <think> must appear in visible output")
        XCTAssertEqual(collectThinking(all), "analysis")
        XCTAssertTrue(collectVisible(all).contains("Final."),
                      "Text after </think> must appear in visible output")
    }

    /// Simulated streamed replay: the driver replays the sniff buffer in a
    /// single `process()` call, but the post-sniff tokens still stream one at
    /// a time. The parser must remain open across subsequent `.process` calls
    /// and correctly close when `</think>` arrives in a later chunk.
    ///
    /// Sabotage check: reset the parser between chunks (delete the `var` and
    /// make it `let` per chunk). `<think>` never closes, `.thinkingCompleted`
    /// never fires, and the assertion `completions == 1` fails.
    func test_sniffBufferReplay_thenStreamedTail_closesAcrossChunks() {
        var parser = ThinkingParser(markers: .qwen3)

        // Replay from the sniff buffer — contains the open tag mid-stream.
        var events = parser.process("start <think>rea")
        // Post-sniff tokens arriving one at a time.
        events += parser.process("son</think>")
        events += parser.process("visible")
        events += parser.finalize()

        XCTAssertEqual(collectThinking(events), "reason")
        XCTAssertTrue(collectVisible(events).hasPrefix("start "),
                      "Pre-<think> text must still be visible after streamed tail")
        XCTAssertTrue(collectVisible(events).contains("visible"))
        XCTAssertEqual(countCompletions(events), 1,
                       "Close tag arriving in a later chunk must still fire .thinkingCompleted exactly once")
        XCTAssertFalse(collectVisible(events).contains("<think>"))
        XCTAssertFalse(collectVisible(events).contains("</think>"))
    }

    // MARK: - Budget Exhaustion (no <think> present)

    /// Counter-case: the model emits normal text with no `<think>` marker. The
    /// sniffer's 64-byte budget will expire and the driver flushes the buffer
    /// as visible text. At the ThinkingParser level, the equivalent is:
    /// parser is never engaged, no events beyond `.token` are produced.
    ///
    /// Pinning this here ensures the parser itself is safe to invoke on
    /// never-thinking content — a precondition for the driver's passthrough
    /// mode once the sniffer gives up.
    func test_parser_onPlainPassthrough_producesNoThinkingEvents() {
        var parser = ThinkingParser(markers: .qwen3)
        let events = parser.process("The quick brown fox jumps over the lazy dog.")
        let finalEvents = parser.finalize()
        let all = events + finalEvents

        XCTAssertEqual(collectThinking(all), "",
                       "Non-reasoning text must never produce .thinkingToken events")
        XCTAssertEqual(countCompletions(all), 0,
                       "No .thinkingCompleted without a <think> open tag")
    }
}
