import Foundation

/// A ``TokenizerProvider`` that memoizes token counts for the lifetime of this instance.
///
/// Construct one per generation cycle and discard it afterward. Messages whose content
/// does not change between subsystem calls pay the tokenization cost exactly once —
/// subsequent lookups for the same string return the cached count.
///
/// Thread-safe: concurrent reads and writes from different actors are safe.
///
/// ## Usage
/// ```swift
/// let tok = CachingTokenizer(wrapping: activeTokenizer ?? HeuristicTokenizer())
/// // Pass tok wherever a TokenizerProvider is accepted.
/// ```
package final class CachingTokenizer: TokenizerProvider, @unchecked Sendable {

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
        cache[text] = count
        return count
    }
}
