import XCTest
@testable import ManifoldInference

// MARK: - Test double

/// Counts every call to tokenCount so tests can verify cache behaviour.
private final class CountingTokenizer: TokenizerProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func tokenCount(_ text: String) -> Int {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return max(1, text.count / 4)
    }
}

// MARK: - Tests

final class CachingTokenizerTests: XCTestCase {

    // MARK: Correctness

    func test_returnsCorrectCount() {
        let base = CountingTokenizer()
        let cache = CachingTokenizer(wrapping: base)
        XCTAssertEqual(cache.tokenCount("hello world"), base.tokenCount("hello world"))
    }

    // Sabotage: if caching always returned 0 this would fail.
    func test_returnsCorrectCount_sabotage() {
        let base = HeuristicTokenizer()
        let cache = CachingTokenizer(wrapping: base)
        XCTAssertEqual(cache.tokenCount("abcdefgh"), 2) // 8 chars / 4
    }

    // MARK: Cache hits

    func test_sameString_callsBaseOnce() {
        let base = CountingTokenizer()
        let cache = CachingTokenizer(wrapping: base)
        let text = "The quick brown fox"

        _ = cache.tokenCount(text)
        _ = cache.tokenCount(text)
        _ = cache.tokenCount(text)

        // base should be called exactly once; the other two are cache hits.
        XCTAssertEqual(base.callCount, 1)
    }

    // Sabotage: if every call went to base this would be 3, not 1.
    func test_sameString_callsBaseOnce_sabotage() {
        let base = CountingTokenizer()
        let cache = CachingTokenizer(wrapping: base)
        _ = cache.tokenCount("abc")
        _ = cache.tokenCount("abc")
        XCTAssertLessThan(base.callCount, 2)
    }

    func test_differentStrings_callsBaseForEach() {
        let base = CountingTokenizer()
        let cache = CachingTokenizer(wrapping: base)

        _ = cache.tokenCount("apple")
        _ = cache.tokenCount("banana")
        _ = cache.tokenCount("cherry")

        XCTAssertEqual(base.callCount, 3)
    }

    func test_emptyString_cached() {
        let base = CountingTokenizer()
        let cache = CachingTokenizer(wrapping: base)

        _ = cache.tokenCount("")
        _ = cache.tokenCount("")

        XCTAssertEqual(base.callCount, 1)
    }

    // MARK: Isolation between instances

    func test_separateInstances_doNotShareCache() {
        let base = CountingTokenizer()
        let cacheA = CachingTokenizer(wrapping: base)
        let cacheB = CachingTokenizer(wrapping: base)
        let text = "shared text"

        _ = cacheA.tokenCount(text)
        _ = cacheB.tokenCount(text)

        // Each instance has its own cache, so base is called twice.
        XCTAssertEqual(base.callCount, 2)
    }

    // MARK: Thread safety

    func test_concurrentReads_doNotCrash() {
        let cache = CachingTokenizer(wrapping: HeuristicTokenizer())
        let group = DispatchGroup()

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                _ = cache.tokenCount("token \(i % 10)") // reuse 10 strings to exercise caching
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent reads timed out — possible deadlock")
    }

    func test_concurrentReadWrite_noDuplicateCalls() {
        let base = CountingTokenizer()
        let cache = CachingTokenizer(wrapping: base)
        let text = "concurrent text"
        let group = DispatchGroup()

        for _ in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                _ = cache.tokenCount(text)
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent writes timed out — possible deadlock")
        // With a lock, base should be called exactly once.
        XCTAssertEqual(base.callCount, 1)
    }

    // MARK: Protocol conformance

    func test_conformsToTokenizerProvider() {
        let provider: any TokenizerProvider = CachingTokenizer(wrapping: HeuristicTokenizer())
        XCTAssertEqual(provider.tokenCount("abcdefgh"), 2)
    }

    // MARK: Bounded cache

    /// The single-use contract was relaxed to reusable, so the cache is no
    /// longer naturally lifetime-bounded. It must flush wholesale at
    /// `maxEntries` so a long-lived instance can't grow without limit.
    func test_cacheIsBoundedAndFlushesAtMaxEntries() {
        let base = CountingTokenizer()
        let cache = CachingTokenizer(wrapping: base)

        // Fill exactly to the cap — each distinct string is a miss.
        for i in 0..<CachingTokenizer.maxEntries {
            _ = cache.tokenCount("s\(i)")
        }
        XCTAssertEqual(base.callCount, CachingTokenizer.maxEntries)

        // At the cap (not over) the earliest key is still cached.
        _ = cache.tokenCount("s0")
        XCTAssertEqual(base.callCount, CachingTokenizer.maxEntries, "s0 should still be cached at the cap")

        // One more distinct key trips the wholesale flush (count >= maxEntries),
        // evicting s0 — re-querying it recomputes, proving the bound holds.
        _ = cache.tokenCount("overflow")
        _ = cache.tokenCount("s0")
        XCTAssertEqual(
            base.callCount, CachingTokenizer.maxEntries + 2,
            "'overflow' and the re-query of evicted 's0' both recompute after the flush"
        )
    }
}
