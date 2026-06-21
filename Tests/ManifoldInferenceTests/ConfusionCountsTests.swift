import XCTest
@testable import ManifoldInference

final class ConfusionCountsTests: XCTestCase {

    private let accuracy = 1e-9

    func testNormalCasePrecisionRecallF1() {
        let counts = ConfusionCounts(tp: 3, fp: 1, fn: 2)
        XCTAssertEqual(counts.predicted, 4)
        XCTAssertEqual(counts.relevant, 5)
        XCTAssertEqual(counts.precision, 0.75, accuracy: accuracy)
        XCTAssertEqual(counts.recall, 0.6, accuracy: accuracy)
        // 2 * 0.75 * 0.6 / (0.75 + 0.6) = 0.9 / 1.35 = 0.66666...
        XCTAssertEqual(counts.f1, 2.0 / 3.0, accuracy: accuracy)
    }

    func testEmptyIsAllZero() {
        let counts = ConfusionCounts.empty
        XCTAssertEqual(counts.precision, 0.0, accuracy: accuracy)
        XCTAssertEqual(counts.recall, 0.0, accuracy: accuracy)
        XCTAssertEqual(counts.f1, 0.0, accuracy: accuracy)
    }

    func testPredictedZeroButFnPositive() {
        let counts = ConfusionCounts(tp: 0, fp: 0, fn: 4)
        XCTAssertEqual(counts.precision, 0.0, accuracy: accuracy)
        XCTAssertEqual(counts.recall, 0.0, accuracy: accuracy)
        XCTAssertEqual(counts.f1, 0.0, accuracy: accuracy)
    }

    func testRelevantZeroButFpPositive() {
        let counts = ConfusionCounts(tp: 0, fp: 4, fn: 0)
        XCTAssertEqual(counts.recall, 0.0, accuracy: accuracy)
        XCTAssertEqual(counts.precision, 0.0, accuracy: accuracy)
        XCTAssertEqual(counts.f1, 0.0, accuracy: accuracy)
    }

    func testComputeOverlappingSets() {
        let actual: Set<String> = ["a", "b", "c", "d"]
        let expected: Set<String> = ["b", "c", "e"]
        let counts = ConfusionCounts.compute(actual: actual, expected: expected)
        XCTAssertEqual(counts.tp, 2) // b, c
        XCTAssertEqual(counts.fp, 2) // a, d
        XCTAssertEqual(counts.fn, 1) // e
    }

    func testComputeDisjointSets() {
        let counts = ConfusionCounts.compute(actual: ["x", "y"], expected: ["z"])
        XCTAssertEqual(counts.tp, 0)
        XCTAssertEqual(counts.fp, 2)
        XCTAssertEqual(counts.fn, 1)
    }

    func testComputeEmptySets() {
        let counts = ConfusionCounts.compute(actual: [], expected: [])
        XCTAssertEqual(counts, ConfusionCounts.empty)
    }

    // MARK: - MacroAveragedMetrics

    func testMacroAverageMeanAcrossClasses() {
        // Class 1: tp=1, fp=1, fn=1 -> precision 0.5, recall 0.5, f1 0.5
        let class1 = ConfusionCounts(tp: 1, fp: 1, fn: 1)
        // Class 2: tp=2, fp=0, fn=0 -> precision 1.0, recall 1.0, f1 1.0
        let class2 = ConfusionCounts(tp: 2, fp: 0, fn: 0)
        let macro = MacroAveragedMetrics(perClass: [class1, class2])
        XCTAssertEqual(macro.precision, 0.75, accuracy: accuracy)
        XCTAssertEqual(macro.recall, 0.75, accuracy: accuracy)
        XCTAssertEqual(macro.f1, 0.75, accuracy: accuracy)
    }

    /// Discriminates a *true* macro-average from a (wrong) micro/pooled average
    /// and from the common mistake of recomputing macro-F1 from the mean
    /// precision and mean recall.
    ///
    /// Classes chosen so the three results are all distinct:
    ///   - Class A: tp=1, fp=0, fn=0  → P=1.0,    R=1.0, f1=1.0
    ///   - Class B: tp=1, fp=9, fn=0  → P=0.1,    R=1.0, f1≈0.1818
    ///
    /// True macro:                 P=0.55,   R=1.0, f1≈0.5909
    /// Micro (pooled tp/fp/fn):    P≈0.1818, R=1.0, f1≈0.3077   ← must NOT match
    /// macroF1 from mean(P),mean(R): ≈0.7097                    ← must NOT match
    func testMacroAverageIsTrueMacroNotMicroNorRecomputedF1() {
        let classA = ConfusionCounts(tp: 1, fp: 0, fn: 0)
        let classB = ConfusionCounts(tp: 1, fp: 9, fn: 0)
        let macro = MacroAveragedMetrics(perClass: [classA, classB])

        XCTAssertEqual(macro.precision, 0.55, accuracy: accuracy)
        XCTAssertEqual(macro.recall, 1.0, accuracy: accuracy)

        // Mean of per-class f1 getters: (1.0 + 2/11) / 2.
        let expectedMacroF1 = (1.0 + (2.0 / 11.0)) / 2.0
        XCTAssertEqual(macro.f1, expectedMacroF1, accuracy: accuracy)

        // Guard against the two regressions this test exists to catch.
        let microF1 = 2.0 * (2.0 / 11.0) / (2.0 / 11.0 + 1.0) // 0.3077
        XCTAssertNotEqual(macro.f1, microF1, accuracy: accuracy)
        let recomputedFromMeans = 2 * 0.55 * 1.0 / (0.55 + 1.0) // 0.7097
        XCTAssertNotEqual(macro.f1, recomputedFromMeans, accuracy: accuracy)
    }

    func testMacroAverageEmptyInputIsAllZero() {
        let macro = MacroAveragedMetrics(perClass: [])
        XCTAssertEqual(macro.precision, 0.0, accuracy: accuracy)
        XCTAssertEqual(macro.recall, 0.0, accuracy: accuracy)
        XCTAssertEqual(macro.f1, 0.0, accuracy: accuracy)
    }

    func testMacroAverageExplicitInit() {
        let macro = MacroAveragedMetrics(precision: 0.1, recall: 0.2, f1: 0.3)
        XCTAssertEqual(macro.precision, 0.1, accuracy: accuracy)
        XCTAssertEqual(macro.recall, 0.2, accuracy: accuracy)
        XCTAssertEqual(macro.f1, 0.3, accuracy: accuracy)
    }
}
