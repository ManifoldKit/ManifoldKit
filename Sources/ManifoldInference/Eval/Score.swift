import Foundation

/// The value a scorer assigns to one sample.
///
/// A sum type rather than a bare `Double` because scorers disagree on shape: a
/// similarity scorer yields a continuous number, a structural matcher yields a
/// boolean, and a degenerate run yields *no* signal at all (which must never be
/// confused with a numeric `0`). Future scorers (graded rubric, per-criterion
/// breakdown) will add cases — `category(String)` / `dict([String: Double])` are
/// the obvious next two and slot in additively.
///
/// `EvalScore` is intentionally **not** `Codable` in this phase: nothing persists
/// an `EvalScore` yet, so growing this enum stays a pure source-level
/// (non-breaking) change. Freeze the on-disk shape only when a real persistence
/// consumer exists.
public enum ScoreValue: Sendable, Equatable {
    /// A continuous score (e.g. cosine similarity, a normalized grade).
    case number(Double)
    /// A pass/fail verdict (e.g. structural AST match).
    case bool(Bool)
    /// The scorer could produce no signal for this run — e.g. empty or
    /// unembeddable input. Distinct from `number(0)`: "no signal" must never read
    /// as "maximally wrong". Consumers should skip `unavailable` samples when
    /// aggregating rather than treat them as zero.
    case unavailable

    /// Numeric projection for aggregation: the wrapped value for `number`, `1`/`0`
    /// for `bool`, and `nil` for `unavailable` (and any future non-numeric case),
    /// so a caller can `compactMap(\.value.doubleValue)` to drop no-signal samples.
    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .unavailable: return nil
        }
    }
}

/// One scorer's verdict on one run's output.
///
/// Mirrors the per-sample `Score` shape common to the eval field (Inspect AI et
/// al.): a `value` plus the optional `explanation` that makes a judge/structural
/// verdict debuggable, and free-form `metadata` for scorer-specific detail.
///
/// Named `EvalScore` (not the bare `Score`) — a bare generic public name
/// under the umbrella (N5); the eval namespace already has `ModelFitScore`
/// and `CaseScore`, so this keeps the family consistently suffixed.
public struct EvalScore: Sendable, Equatable {
    /// The verdict.
    public let value: ScoreValue
    /// The answer extracted from the run, if the scorer isolates one.
    public let answer: String?
    /// Why the scorer reached `value` — a failure reason, threshold note, etc.
    public let explanation: String?
    /// Scorer-specific detail (which scorer, threshold used, signal status …).
    public let metadata: [String: String]

    public init(
        value: ScoreValue,
        answer: String? = nil,
        explanation: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.value = value
        self.answer = answer
        self.explanation = explanation
        self.metadata = metadata
    }
}
