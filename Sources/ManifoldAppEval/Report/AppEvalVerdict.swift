import ManifoldInference

/// Gate result: measured required assertions must all pass to earn exit 0.
/// Missing required evidence is distinct from a measured assertion failure.
public enum AppEvalVerdict: Sendable, Equatable {
    case pass
    case fail
    case error
    /// Required evidence is unavailable, unassessed, or empty.
    case indeterminate

    /// 0 pass, 1 measured failure, 2 run/configuration error, 3 incomplete evidence.
    public var exitCode: Int32 {
        switch self {
        case .pass: return 0
        case .fail: return 1
        case .error: return 2
        case .indeterminate: return 3
        }
    }

    /// Scores supplied here are required. Reduce numeric measurements against
    /// an explicit app-owned threshold before aggregation, or mark them as
    /// informational on `CheckpointOutcome`. No universal numeric bar applies.
    public static func aggregate(_ scores: some Sequence<EvalScore>) -> AppEvalVerdict {
        var sawScore = false
        var incomplete = false
        for score in scores {
            sawScore = true
            switch score.value {
            case .bool(false): return .fail
            case .bool(true): continue
            case .number, .unavailable: incomplete = true
            }
        }
        return !sawScore || incomplete ? .indeterminate : .pass
    }

    /// Measured failure wins, then run error, then incomplete evidence. An
    /// empty collection cannot establish a pass.
    public static func aggregate(verdicts: some Sequence<AppEvalVerdict>) -> AppEvalVerdict {
        var sawVerdict = false
        var sawError = false
        var incomplete = false
        for verdict in verdicts {
            sawVerdict = true
            switch verdict {
            case .fail: return .fail
            case .error: sawError = true
            case .indeterminate: incomplete = true
            case .pass: continue
            }
        }
        if sawError { return .error }
        return !sawVerdict || incomplete ? .indeterminate : .pass
    }
}
