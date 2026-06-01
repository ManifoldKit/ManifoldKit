import XCTest
@testable import ManifoldInference

/// Unit tests for the honest qualitative abstractions layered on `ModelFitScore`:
/// `SpeedClass`, `FitQuality`, and `rationale`.
///
/// These guard the *presentation contract* — coarse buckets and a factual one-liner —
/// not the underlying scoring math (covered by `ModelFitScorerTests`). All scores are
/// constructed directly so the boundaries are tested without a device dependency.
final class ModelFitScoreHonestPresentationTests: XCTestCase {

    private let oneGB: UInt64 = 1_073_741_824

    /// Builds a score with only the fields a given assertion cares about; the rest are
    /// neutral placeholders. `composite`/`tps`/`willRun` are the load-bearing inputs.
    private func score(
        composite: Double = 0.5,
        tps: Double = 20,
        willRun: Bool = true,
        quality: Double = 0.5,
        fit: Double = 1.0
    ) -> ModelFitScore {
        ModelFitScore(
            quality: quality,
            speed: 0.5,
            fit: fit,
            context: 0.5,
            composite: composite,
            estimatedTokensPerSecond: tps,
            memoryBytes: 4 * oneGB,
            willRun: willRun
        )
    }

    // MARK: - SpeedClass thresholds

    func test_speedClass_boundaries() {
        XCTAssertEqual(SpeedClass(tokensPerSecond: 60), .fast)
        XCTAssertEqual(SpeedClass(tokensPerSecond: 30), .fast, "30 is the inclusive lower bound of fast")
        XCTAssertEqual(SpeedClass(tokensPerSecond: 29.999), .usable)
        XCTAssertEqual(SpeedClass(tokensPerSecond: 12), .usable, "12 is the inclusive lower bound of usable")
        XCTAssertEqual(SpeedClass(tokensPerSecond: 11.999), .sluggish)
        XCTAssertEqual(SpeedClass(tokensPerSecond: 5), .sluggish, "5 is the inclusive lower bound of sluggish")
        XCTAssertEqual(SpeedClass(tokensPerSecond: 4.999), .tooSlow)
        XCTAssertEqual(SpeedClass(tokensPerSecond: 0), .tooSlow)
    }

    func test_speedClass_derivedFromScore() {
        XCTAssertEqual(score(tps: 45).speedClass, .fast)
        XCTAssertEqual(score(tps: 8).speedClass, .sluggish)
    }

    // MARK: - FitQuality buckets

    func test_fitQuality_boundaries() {
        XCTAssertEqual(FitQuality(composite: 0.85), .excellent)
        XCTAssertEqual(FitQuality(composite: 0.70), .excellent, "0.70 is the inclusive lower bound of excellent")
        XCTAssertEqual(FitQuality(composite: 0.699), .good)
        XCTAssertEqual(FitQuality(composite: 0.50), .good, "0.50 is the inclusive lower bound of good")
        XCTAssertEqual(FitQuality(composite: 0.499), .marginal)
        XCTAssertEqual(FitQuality(composite: 0.30), .marginal, "0.30 is the inclusive lower bound of marginal")
        XCTAssertEqual(FitQuality(composite: 0.299), .notRecommended)
        XCTAssertEqual(FitQuality(composite: 0.0), .notRecommended)
    }

    func test_fitQuality_wontRun_alwaysNotRecommended() {
        // Even with a high composite, a non-runnable model must read as notRecommended.
        let wontRun = score(composite: 0.9, willRun: false)
        XCTAssertEqual(
            wontRun.fitQuality, .notRecommended,
            "a model that won't load is never excellent/good/marginal"
        )
    }

    // MARK: - rationale content

    func test_rationale_wontRun_statesItPlainly() {
        let r = score(composite: 0.9, tps: 60, willRun: false).rationale
        XCTAssertEqual(r, "Too large to run well on this device")
        XCTAssertFalse(r.contains("!"), "no exclamation marks — factual tone")
    }

    func test_rationale_fastFitting_capableModel() {
        // Fast (tps 50), comfortable fit (1.0), strong quality (0.8).
        let r = score(composite: 0.8, tps: 50, willRun: true, quality: 0.8, fit: 1.0).rationale
        XCTAssertTrue(r.lowercased().contains("fast"), "fast model should say so: \(r)")
        XCTAssertTrue(r.lowercased().contains("comfort"), "comfortable fit should be mentioned: \(r)")
        XCTAssertTrue(r.lowercased().contains("strong"), "strong capability should be mentioned: \(r)")
        XCTAssertFalse(r.contains("!"))
    }

    func test_rationale_slowFitting_limitedModel() {
        // Sluggish (tps 7), tight fit (0.5), limited quality (0.2).
        let r = score(composite: 0.4, tps: 7, willRun: true, quality: 0.2, fit: 0.5).rationale
        XCTAssertTrue(r.lowercased().contains("slow"), "sluggish model should read as slower: \(r)")
        XCTAssertTrue(r.lowercased().contains("tight"), "tight memory fit should be mentioned: \(r)")
        XCTAssertTrue(r.lowercased().contains("limited"), "limited capability should be mentioned: \(r)")
    }

    func test_rationale_startsCapitalised_andHasNoRawNumbers() {
        let r = score(composite: 0.7, tps: 35, willRun: true, quality: 0.7, fit: 1.0).rationale
        let first = r.first
        XCTAssertNotNil(first)
        XCTAssertTrue(first!.isUppercase, "rationale should be sentence-cased: \(r)")
        // Honesty contract: no raw decimals leak into the human line.
        XCTAssertFalse(
            r.contains(where: { $0.isNumber }),
            "rationale must not surface raw numeric estimates: \(r)"
        )
    }
}
