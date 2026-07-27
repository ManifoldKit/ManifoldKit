import Foundation

/// Accumulates per-token timing data for a single generation call.
///
/// Thread-safety via `NSLock`. Updated from the generation task (arbitrary
/// thread); read after the task completes to build the final ``InferenceMetric``.
package final class GenerationMetricTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var wallStart: ContinuousClock.Instant = ContinuousClock.now
    private var dispatchDate: Date = Date()
    private var firstTokenInstant: ContinuousClock.Instant?
    private var lastTokenInstant: ContinuousClock.Instant?
    private var interTokenGapsNs: [Int64] = []

    package init() {}

    package func start() {
        lock.lock()
        defer { lock.unlock() }
        wallStart = ContinuousClock.now
        // Capture a Date alongside ContinuousClock so InferenceMetric carries an
        // absolute timestamp for time-series storage and log correlation.
        dispatchDate = Date()
    }

    package func recordToken() {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if firstTokenInstant == nil {
            firstTokenInstant = now
        } else if let last = lastTokenInstant {
            // Nanosecond precision is sufficient for display; avoid Duration
            // arithmetic inside the lock to keep it fast. Read both
            // `components.seconds` and `components.attoseconds` — the latter
            // is only the sub-second remainder, so ignoring seconds silently
            // truncates any gap ≥ 1s (and reports exactly 0 at whole-second
            // boundaries). See #2382.
            interTokenGapsNs.append(Self.gapNanoseconds(from: last, to: now))
        }
        lastTokenInstant = now
    }

    /// Converts a `ContinuousClock` interval to nanoseconds, preserving whole seconds.
    ///
    /// Package-visible so unit tests can pin the conversion without sleeping a
    /// full second through the tracker (the only path that previously discarded
    /// `components.seconds` and made multi-second gaps report as sub-second).
    package static func gapNanoseconds(
        from last: ContinuousClock.Instant,
        to now: ContinuousClock.Instant
    ) -> Int64 {
        nanoseconds(for: now - last)
    }

    /// Duration → nanoseconds including whole seconds.
    ///
    /// `Duration.components.attoseconds` is the sub-second remainder only;
    /// callers that use it alone under-report every gap ≥ 1s.
    package static func nanoseconds(for duration: Duration) -> Int64 {
        let components = duration.components
        // Int64 nanoseconds saturates around ~292 years — not a practical
        // concern for inter-token gaps. Prefer the wider intermediate over a
        // narrower type that would reintroduce silent truncation.
        return components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
    }

    package func buildMetric(
        provider: String,
        model: String,
        promptTokens: Int,
        cachedPromptTokens: Int,
        completionTokens: Int,
        errorClass: String?
    ) -> InferenceMetric {
        lock.lock()
        defer { lock.unlock() }
        let wallEnd = ContinuousClock.now
        let wallClock: Duration = wallStart <= wallEnd ? wallEnd - wallStart : .zero
        let capturedDate = dispatchDate

        let ttft: Duration
        if let first = firstTokenInstant {
            ttft = wallStart <= first ? first - wallStart : .zero
        } else {
            ttft = .zero
        }

        let meanITL: Duration
        if interTokenGapsNs.isEmpty {
            meanITL = .zero
        } else {
            let sumNs = interTokenGapsNs.reduce(Int64(0), +)
            let avgNs = sumNs / Int64(interTokenGapsNs.count)
            meanITL = .nanoseconds(avgNs)
        }

        return InferenceMetric(
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            completionTokens: completionTokens,
            timeToFirstToken: ttft,
            meanInterTokenLatency: meanITL,
            wallClockDuration: wallClock,
            errorClass: errorClass,
            timestamp: capturedDate
        )
    }
}

package enum SSEGenerationMetrics {
    package static func observing(
        _ stream: AsyncThrowingStream<GenerationEvent, Error>,
        tracker: GenerationMetricTracker,
        enabled: Bool
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard enabled else { return stream }

        return AsyncThrowingStream { outerContinuation in
            let relayTask = Task {
                tracker.start()
                do {
                    for try await event in stream {
                        if case .token = event { tracker.recordToken() }
                        outerContinuation.yield(event)
                    }
                    outerContinuation.finish()
                } catch {
                    outerContinuation.finish(throwing: error)
                }
            }
            outerContinuation.onTermination = { @Sendable _ in
                relayTask.cancel()
            }
        }
    }

    /// Records a metric to `sink` using pre-built tracker data.
    package static func record(
        to sink: any InferenceMetricSink,
        tracker: GenerationMetricTracker,
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        cachedPromptTokens: Int = 0,
        errorClass: String?
    ) {
        let metric = tracker.buildMetric(
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            completionTokens: completionTokens,
            errorClass: errorClass
        )
        Task { await sink.record(metric) }
    }
}
