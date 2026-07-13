import XCTest
@testable import ManifoldInference

final class GenerationStreamConsumerTests: XCTestCase {

    // MARK: - Token Events

    func test_tokenEvent_returnsAppendText() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.token("Hello"))
        // Sabotage check: returning .appendText("") instead of .appendText(text) in the .token case causes this to fail
        XCTAssertEqual(action, .appendText("Hello"))
    }

    func test_multipleTokens_returnAppendTextEach() {
        var consumer = GenerationStreamConsumer()
        XCTAssertEqual(consumer.handle(.token("Hello")), .appendText("Hello"))
        XCTAssertEqual(consumer.handle(.token(" world")), .appendText(" world"))
    }

    // MARK: - Usage Events

    func test_usageEvent_returnsRecordUsage() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.usage(TokenUsage(promptTokens: 10, completionTokens: 5)))
        // Sabotage check: swapping prompt/completion in the .usage case causes this to fail
        XCTAssertEqual(action, .recordUsage(prompt: 10, completion: 5))
    }

    // MARK: - Loop Detection

    func test_shouldStopForLoop_returnsFalse_whenDisabled() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: false)
        let repeating = String(repeating: "abc ", count: 100)
        XCTAssertFalse(consumer.shouldStopForLoop(content: repeating))
    }

    func test_shouldStopForLoop_returnsFalse_whenContentTooShort() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        XCTAssertFalse(consumer.shouldStopForLoop(content: "short"))
    }

    func test_shouldStopForLoop_returnsFalse_forNormalContent() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        let normal = "The quick brown fox jumps over the lazy dog. This is a perfectly normal sentence that should not trigger any loop detection whatsoever."
        // Sabotage check: always returning true from shouldStopForLoop causes this to fail
        XCTAssertFalse(consumer.shouldStopForLoop(content: normal))
    }

    func test_shouldStopForLoop_returnsTrue_forRepetitiveContent() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        // RepetitionDetector.looksLikeLooping checks for actual repetition patterns.
        // Build a string that clearly loops by repeating a phrase many times.
        let repeating = String(repeating: "I am a fish. ", count: 50)
        // Sabotage check: disabling RepetitionDetector.looksLikeLooping causes this to fail
        XCTAssertTrue(consumer.shouldStopForLoop(content: repeating))
    }

    // MARK: - Repetition-guard tuning (B.3 item 4)

    func test_repetitionGuard_defaultsToHistoricThresholds() {
        let consumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        // Default trigger threshold is 100 chars; 99 chars of repetition must
        // stay below the gate exactly as before the thresholds were exposed.
        let justUnder = String(repeating: "x", count: 99)
        XCTAssertEqual(justUnder.count, 99)
        XCTAssertFalse(consumer.shouldStopForLoop(content: justUnder),
                       "default minimumTriggerCharacters (100) must gate short content")
    }

    func test_repetitionGuard_raisedTriggerThreshold_suppressesShortRepetition() {
        // Content that the default guard WOULD flag, made to slip under a
        // raised trigger threshold — proves the exposed knob is load-bearing,
        // not inert.
        let repeating = String(repeating: "I am a fish. ", count: 20) // ~260 chars
        let defaultConsumer = GenerationStreamConsumer(loopDetectionEnabled: true)
        XCTAssertTrue(defaultConsumer.shouldStopForLoop(content: repeating),
                      "baseline: default guard flags this repetition")

        let raised = GenerationStreamConsumer(
            loopDetectionEnabled: true,
            repetitionGuard: RepetitionGuardConfig(minimumTriggerCharacters: repeating.count + 1)
        )
        // Sabotage check (removed before commit) — would fail if the tuning
        // were ignored and the detector always ran at the default gate:
        // XCTAssertTrue(raised.shouldStopForLoop(content: repeating))
        XCTAssertFalse(raised.shouldStopForLoop(content: repeating),
                       "raising minimumTriggerCharacters past the content length disables the guard for it")
    }

    func test_repetitionDetector_configOverload_matchesDefaultForDefaultConfig() {
        let repeating = String(repeating: "loop loop loop ", count: 40)
        XCTAssertEqual(
            RepetitionDetector.looksLikeLooping(repeating),
            RepetitionDetector.looksLikeLooping(repeating, config: .default),
            "the single-arg form must delegate to the .default config unchanged"
        )
        XCTAssertTrue(RepetitionDetector.looksLikeLooping(repeating, config: .default))
    }

    // MARK: - KV Cache Reuse

    func test_kvCacheReuse_returnsIgnore() {
        var consumer = GenerationStreamConsumer()
        let action = consumer.handle(.kvCacheReuse(promptTokensReused: 42))
        // Sabotage check: mapping .kvCacheReuse to .appendText("") would fail this assertion
        XCTAssertEqual(action, .ignore,
            ".kvCacheReuse is an internal performance event; no UI action is needed")
    }

    func test_kvCacheReuse_doesNotAffectSubsequentTokenHandling() {
        var consumer = GenerationStreamConsumer()
        _ = consumer.handle(.kvCacheReuse(promptTokensReused: 10))
        let tokenAction = consumer.handle(.token("hello"))
        XCTAssertEqual(tokenAction, .appendText("hello"),
            "Processing .kvCacheReuse must not corrupt subsequent .token handling")
    }

    // MARK: - Accumulator

    func test_accumulator_tracksTextUsageAndEmptyState() {
        var accumulator = GenerationStreamAccumulator()

        XCTAssertTrue(accumulator.isEmptyResponse)
        accumulator.recordTextToken()
        accumulator.appendVisibleText("hel")
        accumulator.appendVisibleText("lo")
        accumulator.recordUsage(prompt: 7, completion: 3)

        XCTAssertFalse(accumulator.isEmptyResponse)
        XCTAssertEqual(accumulator.visibleText, "hello")
        XCTAssertEqual(accumulator.tokenUsage?.promptTokens, 7)
        XCTAssertEqual(accumulator.tokenUsage?.completionTokens, 3)
    }

    func test_accumulator_finalizesThinkingWithSignatureAndResets() {
        var accumulator = GenerationStreamAccumulator()

        XCTAssertTrue(accumulator.appendThinkingText("step"))
        XCTAssertFalse(accumulator.appendThinkingText(" two"))
        accumulator.recordThinkingSignature("sig")

        let block = accumulator.finalizeThinking()
        XCTAssertEqual(block, .init(text: "step two", signature: "sig"))
        XCTAssertFalse(accumulator.hasOpenThinkingBlock)
        XCTAssertNil(accumulator.finalizeThinking())
    }
}
