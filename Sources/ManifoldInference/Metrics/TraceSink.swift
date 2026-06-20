import Foundation

// MARK: - Sink

/// A type that receives ``GenSpan`` values forming a Run → Turn → span tree.
///
/// The vendor-neutral counterpart to ``InferenceMetricSink``: where a metric
/// sink receives flat post-hoc snapshots, a trace sink receives correlated
/// spans that reconstruct the call hierarchy. Conform to route spans into an
/// OTLP exporter (kept out of core — see the issue's deferred-exporter note),
/// Phoenix/Langfuse/LangSmith, or a local buffer.
///
/// Both sinks coexist: ``InferenceMetricSink`` stays the default backend output,
/// and ``InferenceMetric/asGenSpan(context:)`` adapts any existing metric into
/// a `.llm` span, so trace export works even before Run/Turn IDs are threaded
/// through the turn loop.
public protocol TraceSink: AnyObject, Sendable {
    /// Called once per completed span (whether it succeeded or errored).
    func record(_ span: GenSpan) async
}

// MARK: - In-memory recording sink

/// A thread-safe in-memory ``TraceSink`` that retains every span it receives.
///
/// Intended for tests and debug diagnostics: assert on span tree shape and
/// parent/child correlation without a live collector. Unbounded by design —
/// for production buffering, prefer a bounded host implementation.
public actor RecordingTraceSink: TraceSink {
    private var spans: [GenSpan] = []

    public init() {}

    public func record(_ span: GenSpan) {
        spans.append(span)
    }

    /// All recorded spans in insertion order.
    public func recordedSpans() -> [GenSpan] { spans }

    /// Spans whose `parentSpanID` matches `parent`, in insertion order.
    public func children(of parent: SpanID) -> [GenSpan] {
        spans.filter { $0.context.parentSpanID == parent }
    }

    /// The root spans (no parent) within `traceID`, in insertion order.
    public func roots(in traceID: TraceID) -> [GenSpan] {
        spans.filter { $0.context.traceID == traceID && $0.context.parentSpanID == nil }
    }

    /// Removes all recorded spans.
    public func clear() { spans.removeAll() }
}
