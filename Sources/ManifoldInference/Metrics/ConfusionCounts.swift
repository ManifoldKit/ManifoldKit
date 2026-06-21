import Foundation

/// Immutable TP/FP/FN triple with derived precision / recall / F1.
///
/// Empty-input semantics: precision, recall, and f1 all return `0.0` when the
/// corresponding denominator is zero (e.g. an empty `ConfusionCounts`), *not*
/// `1.0`. This is the conservative choice for set-comparison metrics — an empty
/// prediction set is not "trivially perfect". Callers who want "trivially perfect
/// on empty" semantics should wrap this type and override the zero-denominator case.
public struct ConfusionCounts: Sendable, Equatable {
    /// Present in both actual and expected (true positives).
    public let tp: Int
    /// In actual but not expected (false positives).
    public let fp: Int
    /// Expected but missing from actual (false negatives).
    public let fn: Int

    public init(tp: Int, fp: Int, fn: Int) {
        self.tp = tp
        self.fp = fp
        self.fn = fn
    }

    /// Total predicted positives (tp + fp).
    public var predicted: Int { tp + fp }

    /// Total relevant items (tp + fn).
    public var relevant: Int { tp + fn }

    /// Precision = tp / predicted, or `0.0` when nothing was predicted.
    public var precision: Double {
        predicted == 0 ? 0.0 : Double(tp) / Double(predicted)
    }

    /// Recall = tp / relevant, or `0.0` when nothing was relevant.
    public var recall: Double {
        relevant == 0 ? 0.0 : Double(tp) / Double(relevant)
    }

    /// F1 = harmonic mean of precision and recall, or `0.0` when both are zero.
    public var f1: Double {
        let p = precision
        let r = recall
        return (p + r) == 0 ? 0.0 : 2 * p * r / (p + r)
    }

    /// The zero triple (0/0/0).
    public static let empty = ConfusionCounts(tp: 0, fp: 0, fn: 0)

    /// Computes counts by comparing an actual set against an expected set.
    ///
    /// - tp = actual ∩ expected
    /// - fp = actual − expected
    /// - fn = expected − actual
    public static func compute(actual: Set<String>, expected: Set<String>) -> ConfusionCounts {
        let tp = actual.intersection(expected).count
        let fp = actual.subtracting(expected).count
        let fn = expected.subtracting(actual).count
        return ConfusionCounts(tp: tp, fp: fp, fn: fn)
    }
}

/// Macro-averaged precision/recall/F1 — the unweighted mean of the per-class
/// metrics (each class counts equally regardless of support). Empty input → all 0.0.
///
/// This is a macro average: the mean of each class's `precision`/`recall`/`f1`
/// getters, *not* a pooled (micro) average over summed tp/fp/fn.
public struct MacroAveragedMetrics: Sendable, Equatable {
    public let precision: Double
    public let recall: Double
    public let f1: Double

    public init(precision: Double, recall: Double, f1: Double) {
        self.precision = precision
        self.recall = recall
        self.f1 = f1
    }

    public init(perClass: [ConfusionCounts]) {
        guard !perClass.isEmpty else {
            self.init(precision: 0.0, recall: 0.0, f1: 0.0)
            return
        }
        let n = Double(perClass.count)
        let p = perClass.reduce(0.0) { $0 + $1.precision } / n
        let r = perClass.reduce(0.0) { $0 + $1.recall } / n
        let f = perClass.reduce(0.0) { $0 + $1.f1 } / n
        self.init(precision: p, recall: r, f1: f)
    }
}
