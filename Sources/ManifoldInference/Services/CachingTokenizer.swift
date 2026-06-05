import Foundation

/// A ``TokenizerProvider`` that memoizes token counts. Messages whose content
/// does not change between subsystem calls pay the tokenization cost exactly
/// once — subsequent lookups for the same string return the cached count.
///
/// The cache may be reused across generation cycles (identity-based
/// invalidation on model swap is the caller's job); it is therefore bounded by
/// ``maxEntries`` so a long-lived session can't grow it without limit.
///
/// Thread-safe: concurrent reads and writes from different actors are safe.
///
/// ## Usage
/// ```swift
/// let tok = CachingTokenizer(wrapping: activeTokenizer ?? HeuristicTokenizer())
/// // Pass tok wherever a TokenizerProvider is accepted.
/// ```
package final class CachingTokenizer: TokenizerProvider, @unchecked Sendable {

    /// Upper bound on memoized entries. Keys are raw message content, so without
    /// a cap a long-lived (reused) instance grows unbounded. On overflow we
    /// flush wholesale rather than track recency: token counting tolerates a
    /// cold cache, and the flush is amortized O(1) across `maxEntries` inserts.
    static let maxEntries = 10_000

    private let base: TokenizerProvider
    private var cache: [String: Int] = [:]
    private let lock = NSLock()

    package init(wrapping base: TokenizerProvider) {
        self.base = base
    }

    package func tokenCount(_ text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        let count = base.tokenCount(text)
        if cache.count >= Self.maxEntries {
            cache.removeAll(keepingCapacity: true)
        }
        cache[text] = count
        return count
    }
}
