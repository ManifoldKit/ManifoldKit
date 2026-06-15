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
            // arithmetic inside the lock to keep it fast.
            let gapNs = Int64((now - last).components.attoseconds / 1_000_000_000)
            interTokenGapsNs.append(gapNs)
        }
        lastTokenInstant = now
    }

    package func buildMetric(
        provider: String,
        model: String,
        promptTokens: Int,
        cachedPromptTokens: Int,
        completionTokens: Int,
        estimatedCostUSD: Double,
        isCostApproximate: Bool,
        costTableDate: String,
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
            estimatedCostUSD: estimatedCostUSD,
            isCostApproximate: isCostApproximate,
            costTableDate: costTableDate,
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
    ///
    /// Cost fields are passed explicitly so this method remains in
    /// `ManifoldInference` without a dependency on `InferenceCostEstimator`,
    /// which lives in `ManifoldCloudCore`. Cloud backends compute cost before
    /// calling this method; local backends (Foundation) pass zero cost with
    /// `isCostApproximate: true`.
    package static func record(
        to sink: any InferenceMetricSink,
        tracker: GenerationMetricTracker,
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        cachedPromptTokens: Int = 0,
        estimatedCostUSD: Double,
        isCostApproximate: Bool,
        costTableDate: String,
        errorClass: String?
    ) {
        let metric = tracker.buildMetric(
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            completionTokens: completionTokens,
            estimatedCostUSD: estimatedCostUSD,
            isCostApproximate: isCostApproximate,
            costTableDate: costTableDate,
            errorClass: errorClass
        )
        Task { await sink.record(metric) }
    }
}
