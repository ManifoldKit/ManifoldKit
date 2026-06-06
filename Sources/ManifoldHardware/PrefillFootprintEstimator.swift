import Foundation

/// Learns a per-model resident-memory cost per prefilled token from real samples
/// taken at prompt-decode chunk boundaries, exponentially weighting recent samples.
///
/// The static `ModelLoadPlan` heuristic (`kvBytesPerToken`) is computed once,
/// before load, from architectural KV math. It cannot see what a given model
/// actually costs during prefill on the current device under current memory
/// pressure. This estimator closes that gap: each chunk's measured resident-byte
/// delta (e.g. via ``AppMemoryUsage/currentBytes()``) feeds an EWMA that two
/// consumers read back —
///
/// 1. a pre-chunk abort guard (``wouldExceedHeadroom(remainingBytes:nextChunkTokens:safetyFactor:)``)
///    that declines the *next* chunk when its predicted transient would overrun
///    remaining headroom, surfacing a thrown error instead of a jetsam kill, and
/// 2. ``ModelLoadPlan`` recompute, which can substitute a measured per-token cost
///    for the heuristic once one exists.
///
/// ### Negative-delta rejection
/// On MLX (and under general OS memory accounting) a chunk can show a *negative*
/// resident delta when a cache-pool reclaim frees more than the chunk allocated.
/// Folding those into the average biases the estimate toward zero, which would
/// make the next prediction an underestimate — exactly the wrong direction for a
/// safety guard. Negative deltas are therefore rejected, not clamped to zero
/// (a clamped 0 still drags an EWMA down). They are counted in
/// ``rejectedSampleCount`` for observability.
///
/// Pure value type — no I/O, no actor isolation. Sampling lives at the call site
/// so the estimator stays fully unit-testable with synthetic delta sequences.
public struct PrefillFootprintEstimator: Sendable, Equatable {

    /// EWMA weight applied to each new sample. Higher = more responsive to the
    /// latest chunk, lower = smoother. 0.3 tracks shifting pressure while damping
    /// single-chunk noise.
    public let smoothingFactor: Double

    /// Number of accepted samples required before ``estimatedBytesPerToken``
    /// returns a value. Until then the estimate is `nil` and consumers fall back
    /// to the static heuristic (default behaviour is unchanged pre-measurement).
    public let minimumSamplesForEstimate: Int

    /// Current EWMA of bytes-per-prefilled-token, or `nil` before the first
    /// accepted sample. Stored as `Double` to avoid integer-rounding drift across
    /// many EWMA updates; exposed rounded via ``estimatedBytesPerToken``.
    public private(set) var smoothedBytesPerToken: Double?

    /// Count of accepted (non-negative) samples folded into the average.
    public private(set) var sampleCount: Int

    /// Count of rejected samples (negative delta or non-positive token count).
    /// Surfaced so a reclaim-heavy run is visible rather than silently ignored.
    public private(set) var rejectedSampleCount: Int

    public init(
        smoothingFactor: Double = 0.3,
        minimumSamplesForEstimate: Int = 1
    ) {
        // Clamp to the open-ish interval (0, 1]; an out-of-range alpha would make
        // the EWMA diverge or freeze. Programmer-supplied constant, so clamp
        // rather than trap.
        self.smoothingFactor = min(max(smoothingFactor, 0.0001), 1.0)
        self.minimumSamplesForEstimate = max(1, minimumSamplesForEstimate)
        self.smoothedBytesPerToken = nil
        self.sampleCount = 0
        self.rejectedSampleCount = 0
    }

    /// Folds a measured resident-byte delta over a prefill chunk into the average.
    ///
    /// - Parameters:
    ///   - residentBytesDelta: `after - before` resident footprint across the
    ///     chunk's decode. **Negative values are rejected** (see type docs).
    ///   - tokensProcessed: number of prompt tokens decoded in the chunk. A
    ///     non-positive count is rejected (nothing to attribute cost to).
    public mutating func record(residentBytesDelta: Int64, tokensProcessed: Int) {
        guard tokensProcessed > 0, residentBytesDelta >= 0 else {
            rejectedSampleCount += 1
            return
        }

        let perToken = Double(residentBytesDelta) / Double(tokensProcessed)
        if let previous = smoothedBytesPerToken {
            smoothedBytesPerToken = smoothingFactor * perToken + (1 - smoothingFactor) * previous
        } else {
            // Seed the EWMA with the first accepted sample rather than blending
            // against an assumed zero, which would halve a correct first reading.
            smoothedBytesPerToken = perToken
        }
        sampleCount += 1
    }

    /// Convenience: record from raw before/after footprint readings. A `nil`
    /// reading (Mach call failed) or a count of zero is treated as no sample.
    public mutating func record(beforeBytes: UInt64?, afterBytes: UInt64?, tokensProcessed: Int) {
        guard let before = beforeBytes, let after = afterBytes else { return }
        record(residentBytesDelta: Int64(after) - Int64(before), tokensProcessed: tokensProcessed)
    }

    /// The learned per-token cost in bytes, or `nil` until the minimum sample
    /// threshold is met. Consumers treat `nil` as "no measurement — use the
    /// static heuristic".
    public var estimatedBytesPerToken: UInt64? {
        guard sampleCount >= minimumSamplesForEstimate,
              let smoothed = smoothedBytesPerToken,
              smoothed > 0 else { return nil }
        return UInt64(smoothed.rounded())
    }

    /// Predicted transient resident growth for decoding `tokens` more tokens,
    /// inflated by `safetyFactor` to leave margin for accounting jitter and
    /// allocator spikes. `nil` when no estimate exists yet.
    public func predictedTransientBytes(forTokens tokens: Int, safetyFactor: Double = 1.5) -> UInt64? {
        guard tokens > 0, let perToken = estimatedBytesPerToken else { return nil }
        let predicted = Double(perToken) * Double(tokens) * max(1.0, safetyFactor)
        // Saturate rather than overflow on absurd inputs.
        guard predicted < Double(UInt64.max) else { return UInt64.max }
        return UInt64(predicted)
    }

    /// Pre-chunk abort decision: would decoding the next chunk's `nextChunkTokens`
    /// tokens predictably overrun `remainingBytes` of headroom?
    ///
    /// Returns `false` whenever no estimate exists yet — the guard stays dormant
    /// until the first sample, so default (pre-measurement) behaviour is unchanged
    /// and a missing sample never causes a spurious abort.
    public func wouldExceedHeadroom(
        remainingBytes: UInt64,
        nextChunkTokens: Int,
        safetyFactor: Double = 1.5
    ) -> Bool {
        guard let predicted = predictedTransientBytes(forTokens: nextChunkTokens, safetyFactor: safetyFactor) else {
            return false
        }
        return predicted > remainingBytes
    }
}
