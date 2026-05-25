import Foundation
import ManifoldInference

/// Accumulates per-token timing data for a single generation call.
///
/// Thread-safety via `NSLock`. Updated from the generation task (arbitrary
/// thread); read after the task completes to build the final ``InferenceMetric``.
final class GenerationMetricTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var wallStart: ContinuousClock.Instant = ContinuousClock.now
    private var dispatchDate: Date = Date()
    private var firstTokenInstant: ContinuousClock.Instant?
    private var lastTokenInstant: ContinuousClock.Instant?
    private var interTokenGapsNs: [Int64] = []

    func start() {
        lock.lock()
        defer { lock.unlock() }
        wallStart = ContinuousClock.now
        // Capture a Date alongside ContinuousClock so InferenceMetric carries an
        // absolute timestamp for time-series storage and log correlation.
        dispatchDate = Date()
    }

    func recordToken() {
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

    func buildMetric(
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

enum SSEGenerationMetrics {
    static func observing(
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

    static func record(
        to sink: any InferenceMetricSink,
        tracker: GenerationMetricTracker,
        provider: String,
        model: String,
        usage: (promptTokens: Int, completionTokens: Int)?,
        errorClass: String?
    ) {
        let promptTokens = usage?.promptTokens ?? 0
        let completionTokens = usage?.completionTokens ?? 0
        let (costUSD, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
        let metric = tracker.buildMetric(
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            cachedPromptTokens: 0,
            completionTokens: completionTokens,
            estimatedCostUSD: costUSD,
            isCostApproximate: isApprox,
            costTableDate: InferenceCostEstimator.costTableDate,
            errorClass: errorClass
        )
        Task { await sink.record(metric) }
    }
}
