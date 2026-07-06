import ManifoldRuntime

/// An app-supplied hook that lets a checkpoint scorer see state
/// ``EvalRunOutput`` cannot carry — a SwiftData-backed executor's extracted
/// graph, a vector store's current document count, anything the app's own
/// composition root owns that isn't part of the turn-loop trace.
///
/// This is the fix for the wave-1 design's original blocker (design v1 →
/// v2, finding 1): a `custom` JSON payload alone can't reach live app state,
/// because ``EvalScorer`` only receives ``EvalRunOutput``. ``GoldenTaskRunner``
/// calls ``snapshot(after:runResult:)`` once per checkpoint, after driving the
/// turns up through that checkpoint's `afterTurnIndex` — the app awaits its
/// own settling (e.g. pending async extraction) before returning.
///
/// No probe registered → checkpoints that need a snapshot score
/// `.unavailable`, never a fabricated pass or a zero (absence is never
/// silently equal to "correct" or "wrong").
public protocol ScenarioStateProbe: Sendable {
    /// Returns an opaque, `Sendable` snapshot of app state as of `checkpoint`,
    /// or `nil` if the app has nothing to report for this checkpoint (distinct
    /// from "no prober registered at all" — a registered prober can still
    /// decline to snapshot a specific checkpoint).
    func snapshot(
        after checkpoint: GoldenCheckpoint,
        runResult: RuntimeScenarioRunner.Result
    ) async -> (any Sendable)?
}
