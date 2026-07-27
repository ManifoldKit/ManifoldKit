import XCTest
@testable import ManifoldInference

final class GenerationMetricTrackerTests: XCTestCase {

    // MARK: - Duration → ns conversion (#2382)

    func test_nanoseconds_includesWholeSeconds_forMultiSecondGap() {
        // Pre-fix: only `.components.attoseconds` was read, so a 2.0s gap
        // reported 0 and a 1.5s gap reported 0.5s. Pin the full conversion.
        let twoSeconds = Duration.seconds(2)
        XCTAssertEqual(
            GenerationMetricTracker.nanoseconds(for: twoSeconds),
            2_000_000_000
        )

        let oneAndHalf = Duration.seconds(1) + Duration.milliseconds(500)
        XCTAssertEqual(
            GenerationMetricTracker.nanoseconds(for: oneAndHalf),
            1_500_000_000
        )
    }

    func test_nanoseconds_subSecondGapsStillCorrect() {
        let quarter = Duration.milliseconds(250)
        XCTAssertEqual(
            GenerationMetricTracker.nanoseconds(for: quarter),
            250_000_000
        )
        XCTAssertEqual(
            GenerationMetricTracker.nanoseconds(for: .zero),
            0
        )
    }

    func test_nanoseconds_wholeSecondBoundaryIsNotZero() {
        // The latent bug reported exactly zero for any exact whole-second
        // gap (attoseconds remainder was 0). That must never return.
        for seconds in [1, 2, 5, 10] as [Int64] {
            let ns = GenerationMetricTracker.nanoseconds(for: .seconds(seconds))
            XCTAssertEqual(ns, seconds * 1_000_000_000, "\(seconds)s gap")
            XCTAssertGreaterThan(ns, 0)
        }
    }

    // MARK: - Tracker mean ITL with a real multi-second gap

    func test_meanInterTokenLatency_includesGapOverOneSecond() {
        // Sleep past the 1s boundary so a real ContinuousClock interval
        // exercises the same path production uses (not only the pure helper).
        let tracker = GenerationMetricTracker()
        tracker.start()
        tracker.recordToken()
        Thread.sleep(forTimeInterval: 1.15)
        tracker.recordToken()

        let metric = tracker.buildMetric(
            provider: "test",
            model: "test",
            promptTokens: 0,
            cachedPromptTokens: 0,
            completionTokens: 2,
            errorClass: nil
        )

        let meanNs = GenerationMetricTracker.nanoseconds(for: metric.meanInterTokenLatency)
        // Floor well under 1s would reintroduce the pre-fix truncation.
        XCTAssertGreaterThan(
            meanNs,
            1_000_000_000,
            "mean ITL for a ~1.15s gap must exceed 1s; got \(meanNs) ns"
        )
        // Upper bound keeps a hung clock from silently passing forever.
        XCTAssertLessThan(meanNs, 3_000_000_000)
    }
}
