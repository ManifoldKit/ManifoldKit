import Foundation

/// Helpers for constructing a Run → Turn → span tree with correct parent/child
/// correlation, without threading IDs through every backend signature.
///
/// A host (or the turn loop, once IDs are threaded) opens a Run span, then a
/// Turn span under it, then records one `.llm` span per model generation and
/// one `.tool` span per tool invocation as children of the Turn. Each helper
/// returns the child ``SpanContext`` so callers can keep building deeper.
public enum GenSpanTree {
    /// Opens a Run-level `.chain` span — the trace root.
    /// - Parameter traceID: Trace to anchor the run under; defaults to a fresh one.
    /// - Returns: The run span (status `.unset`; the caller closes it by setting
    ///   `end`/`status`) and its context for parenting Turn spans.
    public static func run(
        name: String = "run",
        traceID: TraceID = .random(),
        start: Date = Date(),
        attributes: [String: AttributeValue] = [:]
    ) -> (span: GenSpan, context: SpanContext) {
        let context = SpanContext.root(traceID: traceID)
        let span = GenSpan(
            context: context, kind: .chain, name: name, start: start, attributes: attributes
        )
        return (span, context)
    }

    /// Opens a Turn-level `.chain` span under a Run.
    public static func turn(
        under run: SpanContext,
        name: String = "turn",
        start: Date = Date(),
        attributes: [String: AttributeValue] = [:]
    ) -> (span: GenSpan, context: SpanContext) {
        let context = run.child()
        let span = GenSpan(
            context: context, kind: .chain, name: name, start: start, attributes: attributes
        )
        return (span, context)
    }

    /// Records a model generation as an `.llm` child of a Turn, adapted from an
    /// existing ``InferenceMetric`` so the attribute map stays lossless.
    public static func generation(
        _ metric: InferenceMetric,
        under turn: SpanContext,
        name: String? = nil
    ) -> GenSpan {
        metric.asGenSpan(context: turn.child(), name: name)
    }

    /// Opens a `.tool` child of a Turn.
    public static func tool(
        under turn: SpanContext,
        name: String,
        start: Date = Date(),
        attributes: [String: AttributeValue] = [:]
    ) -> (span: GenSpan, context: SpanContext) {
        let context = turn.child()
        let span = GenSpan(
            context: context, kind: .tool, name: name, start: start, attributes: attributes
        )
        return (span, context)
    }
}
