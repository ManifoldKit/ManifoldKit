import Foundation

/// Per-detector regression contract. Four fixture cases — positive, negative,
/// boundary, adversarial — keep detector logic honest: contract tests are
/// independent of the calibration corpus, so a corpus regression can't
/// silently mask a broken detector.
///
/// The adversarial case is what prevents a detector overfitting to its own
/// fixture shape — it represents input that superficially resembles the bug
/// class but should not fire (e.g., Markdown code fence tokens that look like
/// chat-template fragments to a naive regex).
public protocol DetectorContract {
    /// The detector under test.
    static var detector: any Detector { get }
    /// A record the detector MUST flag.
    static var positiveFixture: RunRecord { get }
    /// A record the detector MUST NOT flag.
    static var negativeFixture: RunRecord { get }
    /// A record on the detector's threshold — must be deterministic
    /// (10 consecutive inspections yield identical findings).
    static var boundaryFixture: RunRecord { get }
    /// A record that superficially resembles the bug class but should not
    /// fire (e.g., Markdown code fence tokens that look like chat-template
    /// fragments to a naive regex).
    static var adversarialFixture: RunRecord { get }
}
