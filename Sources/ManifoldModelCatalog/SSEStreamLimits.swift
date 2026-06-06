import Foundation

/// Configurable caps applied to SSE (and NDJSON) parsing to defend against
/// hostile or misconfigured upstream servers.
///
/// The parser enforces three separate bounds:
///
/// - ``maxEventBytes`` caps the size of a single event payload buffer. A
///   malicious server cannot make the client swallow a 100 MB `data:` line.
/// - ``maxTotalBytes`` caps cumulative bytes across the whole stream. This
///   stops a server that drips just-small-enough events forever.
/// - ``maxEventsPerSecond`` caps the yield rate. A flood of 1-byte events is
///   rejected before it can starve the consumer.
///
/// Defaults (``default``) are intentionally well above any realistic provider
/// throughput — OpenAI, Anthropic, and Ollama all emit events far smaller
/// than 1 MB and well under 5,000 events per second — so legitimate traffic is
/// never throttled.
///
/// ## Tuning
///
/// Most apps never need to change these. Raise a cap only if you observe
/// legitimate traffic failing — for example, a provider that ships a
/// multi-megabyte tool-use result in a single event. Lower a cap when you
/// point a backend at an untrusted endpoint and want to narrow the attack
/// surface further.
///
/// ```swift
/// // App-wide: applies to every SSECloudBackend at launch.
/// ManifoldConfiguration.shared.sseStreamLimits = SSEStreamLimits(
///     maxEventBytes: 500_000,
///     maxTotalBytes: 10_000_000,
///     maxEventsPerSecond: 2_000
/// )
///
/// // Per backend: leaves OpenAI/Anthropic at defaults while tightening an
/// // untrusted CustomEndpoint.
/// let backend = OpenAIBackend(endpoint: untrusted)
/// backend.sseStreamLimits = SSEStreamLimits(
///     maxEventBytes: 64_000,
///     maxTotalBytes: 1_000_000,
///     maxEventsPerSecond: 500
/// )
/// ```
///
/// There is deliberately no "unlimited" option: bounded caps are the point.
///
/// Extracted from ManifoldInference into ManifoldModelCatalog in P1d (#1611)
/// so ManifoldConfiguration (which references this type) compiles at the
/// ManifoldModelCatalog level without a ManifoldInference import.
public struct SSEStreamLimits: Sendable, Equatable {

    /// Maximum byte size of a single event payload buffer, including bytes
    /// that have not yet reached a newline.
    public var maxEventBytes: Int

    /// Maximum cumulative byte count across the entire stream, counting all
    /// bytes the parser consumes (including control and ignored lines).
    public var maxTotalBytes: Int

    /// Maximum events the parser may yield within a one-second rate window.
    ///
    /// The window is fixed (not sliding): it opens on the first event and
    /// resets once at least one wall-clock second has elapsed. A burst that
    /// exceeds this count within the active window finishes the stream with
    /// ``SSEStreamError/eventRateExceeded(_:)``.
    public var maxEventsPerSecond: Int

    public init(
        maxEventBytes: Int,
        maxTotalBytes: Int,
        maxEventsPerSecond: Int
    ) {
        self.maxEventBytes = maxEventBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxEventsPerSecond = maxEventsPerSecond
    }

    /// Conservative defaults suitable for every mainstream provider.
    ///
    /// - 1 MB per event: large enough for chunked usage payloads and tool
    ///   call metadata, small enough to reject a pathological upstream.
    /// - 50 MB per stream: covers hours of conversation tokens without
    ///   allowing unbounded streams.
    /// - 5,000 events/s: roughly 100x real provider throughput; a healthy
    ///   LLM tops out at a few hundred tokens/s.
    public static let `default` = SSEStreamLimits(
        maxEventBytes: 1_000_000,
        maxTotalBytes: 50_000_000,
        maxEventsPerSecond: 5_000
    )
}

/// Errors thrown by ``SSEStreamParser`` when a stream violates its limits.
///
/// These surface through the existing `AsyncThrowingStream` failure channel
/// exactly like any other parsing error, so backend retry/error UI continues
/// to work unchanged.
public enum SSEStreamError: Error, Equatable, Sendable {
    /// A single event exceeded ``SSEStreamLimits/maxEventBytes``. The
    /// associated value is the observed size in bytes.
    case eventTooLarge(Int)

    /// Cumulative bytes across the stream exceeded
    /// ``SSEStreamLimits/maxTotalBytes``. The associated value is the total
    /// bytes consumed before the limit tripped.
    case streamTooLarge(Int)

    /// More events than ``SSEStreamLimits/maxEventsPerSecond`` were produced
    /// within a single one-second window. The associated value is the event
    /// count observed in that window.
    case eventRateExceeded(Int)
}
