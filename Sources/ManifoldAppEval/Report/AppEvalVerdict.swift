import ManifoldInference

/// The gate-shaped verdict of an ``AppEvalOutcome`` — the summary a CI job
/// reads to decide pass/fail, independent of the per-checkpoint detail in the
/// rendered report.
///
/// Mirrors manifold-eval's exit-code convention (design v1 §1, last bullet):
/// `0` pass, `1` actionable failure, `2` usage/config error, `3`+ named
/// intermediate verdicts. This module ships no CLI executable in wave 1 (see
/// the module DocC page), so ``exitCode`` is documented here as the contract
/// a future gate-shaped command adopts — not wired to `exit(_:)` anywhere in
/// this module today.
public enum AppEvalVerdict: Sendable, Equatable {
    /// Every checkpoint scored either a passing bool/number or `.unavailable`
    /// absence — nothing failed outright.
    case pass
    /// At least one checkpoint scored a failing bool or an out-of-tolerance
    /// number.
    case fail
    /// The fixture or run itself could not be evaluated (a `GoldenTaskMapper`/
    /// `GoldenTaskLoader` error, not a scoring failure).
    case error

    /// The exit-code mapping a gate-shaped CLI would use:
    /// - `0`: ``pass``
    /// - `1`: ``fail`` (actionable — a checkpoint's assertion did not hold)
    /// - `2`: ``error`` (usage/config/load error — distinct from a real failure
    ///   so CI can tell "the gate caught something" from "the gate is broken")
    /// - `3`+ (design v2 §3.4, "named intermediate verdicts"): **not
    ///   applicable in-library.** The wave-1 library has no aggregate
    ///   "indeterminate" verdict — per-checkpoint absence is carried as
    ///   first-class `.unavailable` rows inside a ``pass`` outcome rather
    ///   than a distinct top-level verdict. `3`+ is reserved for the future
    ///   gate-shaped CLI (wave 2+), whose named intermediate verdicts get
    ///   codes from 3 up per the manifold-eval convention.
    public var exitCode: Int32 {
        switch self {
        case .pass: return 0
        case .fail: return 1
        case .error: return 2
        }
    }

    /// Derives a verdict from a set of scores: only `.bool(false)` yields
    /// ``fail``; `.unavailable` is absence, not failure, and does not by
    /// itself downgrade ``pass``.
    ///
    /// **Invariant: a raw `.number` carries no verdict weight here.** Every
    /// verdict-bearing scorer in this module reduces to `.bool` before its
    /// score reaches aggregation — the built-ins produce `.bool` directly,
    /// and `JudgedCheckpointScorer` reduces its judge's continuous score
    /// against the payload's required `minScore` bar. A scorer that emitted
    /// a bare `.number` into a gate would be verdict-inert (a `0.0` that
    /// still exits `0`); keep this invariant true when adding scorers, or
    /// extend this aggregation with an explicit threshold policy first.
    public static func aggregate(_ scores: some Sequence<Score>) -> AppEvalVerdict {
        for score in scores {
            switch score.value {
            case .bool(false):
                return .fail
            case .bool, .number, .unavailable:
                continue
            }
        }
        return .pass
    }

    /// Rolls up a set of already-computed verdicts (e.g. one
    /// ``AppEvalOutcome`` aggregating several ``FixtureOutcome`` verdicts):
    /// any ``fail`` wins outright; otherwise any ``error`` wins; otherwise
    /// ``pass``.
    public static func aggregate(verdicts: some Sequence<AppEvalVerdict>) -> AppEvalVerdict {
        var sawError = false
        for verdict in verdicts {
            switch verdict {
            case .fail: return .fail
            case .error: sawError = true
            case .pass: continue
            }
        }
        return sawError ? .error : .pass
    }
}
