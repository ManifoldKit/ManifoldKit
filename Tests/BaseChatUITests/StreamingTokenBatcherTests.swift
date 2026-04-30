@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatInference

final class StreamingTokenBatcherTests: XCTestCase {

    func test_append_defersFlushUntilIntervalOrSizeBoundary() {
        let start = ContinuousClock.now
        var batcher = StreamingTokenBatcher(
            interval: .milliseconds(100),
            maxBufferedCharacters: 10,
            now: start
        )

        let first = batcher.append("abc", now: start + .milliseconds(20))
        XCTAssertNil(first)

        let second = batcher.append("def", now: start + .milliseconds(80))
        XCTAssertNil(second)

        let third = batcher.append("g", now: start + .milliseconds(120))
        XCTAssertEqual(third, "abcdefg")
    }

    func test_append_flushesImmediatelyWhenSizeLimitReached() {
        let start = ContinuousClock.now
        var batcher = StreamingTokenBatcher(
            interval: .seconds(1),
            maxBufferedCharacters: 5,
            now: start
        )

        XCTAssertNil(batcher.append("ab", now: start + .milliseconds(10)))
        let flushed = batcher.append("cde", now: start + .milliseconds(15))
        XCTAssertEqual(flushed, "abcde")
    }

    func test_flush_returnsRemainingBufferedTokens() {
        let start = ContinuousClock.now
        var batcher = StreamingTokenBatcher(
            interval: .seconds(1),
            maxBufferedCharacters: 100,
            now: start
        )

        XCTAssertNil(batcher.append("hello", now: start + .milliseconds(10)))
        XCTAssertEqual(batcher.flush(now: start + .milliseconds(11)), "hello")
        XCTAssertNil(batcher.flush(now: start + .milliseconds(12)))
    }
}
