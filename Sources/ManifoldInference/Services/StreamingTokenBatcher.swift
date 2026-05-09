import Foundation

// MARK: - StreamingTokenBatcher

/// Buffers streamed tokens and emits coalesced batches to reduce high-frequency
/// mutations that would otherwise trigger excessive UI re-renders.
///
/// Moved from `ManifoldUI/GenerationQueue` to `ManifoldInference` so both
/// `ConversationRuntime` (in `ManifoldRuntime`) and `GenerationQueue` (in
/// `ManifoldUI`) can share the same implementation without a cross-module copy.
public struct StreamingTokenBatcher: Sendable {
    private let interval: Duration
    private let maxBufferedCharacters: Int
    private var buffered = ""
    private var lastFlush: ContinuousClock.Instant

    public init(
        interval: Duration,
        maxBufferedCharacters: Int,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        self.interval = interval
        self.maxBufferedCharacters = maxBufferedCharacters
        self.lastFlush = now
    }

    public mutating func append(_ token: String, now: ContinuousClock.Instant) -> String? {
        buffered += token
        guard shouldFlush(now: now) else { return nil }
        return flush(now: now)
    }

    public mutating func flush(now: ContinuousClock.Instant) -> String? {
        guard !buffered.isEmpty else { return nil }
        let batch = buffered
        buffered = ""
        lastFlush = now
        return batch
    }

    private func shouldFlush(now: ContinuousClock.Instant) -> Bool {
        buffered.count >= maxBufferedCharacters || now - lastFlush >= interval
    }
}
