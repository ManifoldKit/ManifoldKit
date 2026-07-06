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
    public var exitCode: Int32 {
        switch self {
        case .pass: return 0
        case .fail: return 1
        case .error: return 2
        }
    }

    /// Derives a verdict from a set of scores: any failing `.bool(false)`
    /// (or a `.number` that the caller has already reduced to fail/pass —
    /// this harness's built-in scorers only ever produce `.bool`) yields
    /// ``fail``; `.unavailable` is absence, not failure, and does not by
    /// itself downgrade ``pass``.
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
