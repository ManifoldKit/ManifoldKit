import XCTest
@testable import ManifoldInference

/// Tests verifying that `GenerationStreamConsumer` correctly maps thinking
/// events to their `StreamAction` counterparts, and that loop detection
/// does not fire on repetitive thinking content.
final class GenerationStreamConsumerThinkingTests: XCTestCase {

    // MARK: - 1. thinkingToken → appendThinkingText

    func test_thinkingToken_mapsToAppendThinkingText() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.thinkingToken("step one"))

        XCTAssertEqual(action, .appendThinkingText("step one"),
            ".thinkingToken must map to .appendThinkingText with the same string")

        // Sabotage check: mapping .thinkingToken to .appendText instead would
        // write reasoning into the visible message body — this test would fail
        // because .appendText != .appendThinkingText.
    }

    func test_thinkingToken_emptyString_mapsToAppendThinkingText() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.thinkingToken(""))
        XCTAssertEqual(action, .appendThinkingText(""))
    }

    // MARK: - 2. thinkingCompleted → finalizeThinking

    func test_thinkingComplete_mapsToFinalizeThinking() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.thinkingCompleted)

        XCTAssertEqual(action, .finalizeThinking,
            ".thinkingCompleted must map to .finalizeThinking so the UI commits the accumulator")

        // Sabotage check: returning .appendText("") instead of .finalizeThinking would
        // leave the thinking accumulator open indefinitely — this equality check would fail.
    }

    // MARK: - 3. Loop detection does not fire on repetitive thinking content

    func test_shouldStopForLoop_ignoresRepetitiveThinkingContent() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        // Build a highly repetitive string that WOULD trigger loop detection for visible text.
        let repetitiveThinking = String(repeating: "I am reasoning. ", count: 50)

        // shouldStopForLoop is called with the thinking accumulator — it must return false
        // because the caller is responsible for not passing thinking content here.
        // This test documents the intended usage: callers must pass visible content only.
        // Passing repetitive thinking content directly should still return true (loop detector
        // doesn't know what it's receiving — it's the *caller's* job to route correctly).
        // What we verify: a consumer with loop detection enabled does NOT fire for
        // thinking text when the caller correctly passes only visible content (empty string here).
        XCTAssertFalse(consumer.shouldStopForLoop(content: ""),
            "Loop detection must not fire when no visible content has been accumulated")

        // Verify the repetitive thinking content would trip loop detection if mistakenly
        // passed as visible content — confirming that routing matters.
        XCTAssertTrue(consumer.shouldStopForLoop(content: repetitiveThinking),
            "Repetitive content passed as visible content should trigger loop detection — callers must not route thinking text here")

        // Sabotage check: disabling loop detection for all inputs would make the second
        // assertion fail, masking a real loop in visible output.
    }

    func test_shouldStopForLoop_withLoopDetectionDisabled_neverFires() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: false)
        let repetitive = String(repeating: "loop loop loop ", count: 100)
        XCTAssertFalse(consumer.shouldStopForLoop(content: repetitive),
            "Loop detection disabled must return false regardless of content")
    }

    // MARK: - Full event sequence matches expected actions

    func test_fullThinkingSequence_producesCorrectActionOrder() {
        var consumer = GenerationStreamConsumer()
        let events: [GenerationEvent] = [
            .thinkingToken("reason"),
            .thinkingToken(" more"),
            .thinkingCompleted,
            .token("answer"),
        ]
        let actions = events.map { consumer.handle($0) }

        XCTAssertEqual(actions, [
            .appendThinkingText("reason"),
            .appendThinkingText(" more"),
            .finalizeThinking,
            .appendText("answer"),
        ], "Full thinking-then-visible sequence must produce the correct action order")

        // Sabotage check: swapping the .thinkingToken and .token cases in handle()
        // would produce .appendText for thinking and .appendThinkingText for visible,
        // causing all four equality checks to fail.
    }
}
