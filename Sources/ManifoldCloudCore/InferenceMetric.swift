import Foundation

/// A snapshot of latency, cost, and token-count data produced after a single
/// cloud inference call.
///
/// Emitted by ``SSECloudBackend`` after every generation (success or failure)
/// and forwarded to the configured ``InferenceMetricSink``. Consumers use this
/// to power dashboards, cost alerts, and latency regression detection without
/// having to instrument individual backends.
public struct InferenceMetric: Sendable {
    /// Human-readable backend name (e.g. "Claude", "OpenAI").
    public let provider: String
    /// Model identifier used for the call (e.g. "claude-sonnet-4-6").
    public let model: String
    /// Number of tokens in the prompt as reported by the provider.
    public let promptTokens: Int
    /// Number of prompt tokens served from the provider's prompt cache (0 when unavailable).
    public let cachedPromptTokens: Int
    /// Number of tokens in the completion.
    public let completionTokens: Int
    /// Time elapsed between request dispatch and the first `.token` event.
    /// Zero when the stream produced no tokens. `.thinkingToken` events are
    /// intentionally excluded — TTFT measures output latency as perceived by
    /// the end user, not internal reasoning time.
    public let timeToFirstToken: Duration
    /// Average gap between consecutive token events.
    /// Zero when fewer than two tokens were observed.
    public let meanInterTokenLatency: Duration
    /// Wall-clock duration from request dispatch to stream completion or error.
    public let wallClockDuration: Duration
    /// Estimated USD cost for the call based on the static rate table.
    public let estimatedCostUSD: Double
    /// `true` when the model was not in the known rate table and the cost is
    /// therefore zero rather than accurate.
    public let isCostApproximate: Bool
    /// ISO date string of the rate table used for the cost estimate (e.g. "2026-05-24").
    public let costTableDate: String
    /// Short error class name when the call ended in failure, `nil` on success
    /// (e.g. "rateLimited", "networkError", "authenticationFailed").
    public let errorClass: String?
    /// Wall-clock date and time at which the generation request was dispatched.
    /// Useful for time-series storage and correlating metrics with external logs.
    public let timestamp: Date

    public init(
        provider: String,
        model: String,
        promptTokens: Int,
        cachedPromptTokens: Int,
        completionTokens: Int,
        timeToFirstToken: Duration,
        meanInterTokenLatency: Duration,
        wallClockDuration: Duration,
        estimatedCostUSD: Double,
        isCostApproximate: Bool,
        costTableDate: String,
        errorClass: String?,
        timestamp: Date = Date()
    ) {
        self.provider = provider
        self.model = model
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.completionTokens = completionTokens
        self.timeToFirstToken = timeToFirstToken
        self.meanInterTokenLatency = meanInterTokenLatency
        self.wallClockDuration = wallClockDuration
        self.estimatedCostUSD = estimatedCostUSD
        self.isCostApproximate = isCostApproximate
        self.costTableDate = costTableDate
        self.errorClass = errorClass
        self.timestamp = timestamp
    }
}

// MARK: - Sink Protocol

/// A type that receives ``InferenceMetric`` values produced by cloud backends.
///
/// Conform to this protocol to route metrics into observability systems (Datadog,
/// OpenTelemetry, a local ring buffer, etc.) without coupling the backend layer
/// to a specific sink implementation.
public protocol InferenceMetricSink: AnyObject, Sendable {
    /// Called by the backend after every generation, whether or not it succeeded.
    func record(_ metric: InferenceMetric) async
}

// MARK: - In-Memory Ring Buffer

/// A thread-safe, bounded ring buffer of ``InferenceMetric`` values.
///
/// The shared singleton is the default sink wired into ``SSECloudBackend``.
/// Tests and host apps can inject their own sink; this actor is useful as a
/// lightweight diagnostic tool in debug builds.
///
/// When the buffer is full the oldest entry is evicted before the new one is
/// appended, so memory usage stays constant regardless of call volume.
public actor InMemoryMetricSink: InferenceMetricSink {

    /// Shared singleton. ``SSECloudBackend`` defaults to this sink so callers
    /// can read recent metrics without configuring anything.
    public static let shared = InMemoryMetricSink()

    private var metrics: [InferenceMetric] = []
    private let capacity: Int

    /// Creates a sink with a custom buffer capacity.
    /// - Parameter capacity: Maximum number of metrics to retain. Defaults to 100.
    public init(capacity: Int = 100) {
        self.capacity = capacity
    }

    /// Appends `metric`, evicting the oldest entry if the buffer is at capacity.
    public func record(_ metric: InferenceMetric) {
        if metrics.count >= capacity { metrics.removeFirst() }
        metrics.append(metric)
    }

    /// Returns all retained metrics in insertion order.
    public func recentMetrics() -> [InferenceMetric] { metrics }

    /// Removes all retained metrics.
    public func clear() { metrics.removeAll() }
}
