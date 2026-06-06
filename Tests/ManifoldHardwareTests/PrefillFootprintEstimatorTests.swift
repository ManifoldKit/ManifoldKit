import XCTest
@testable import ManifoldHardware

/// Unit tests for `PrefillFootprintEstimator` (issue #1592).
///
/// The estimator is a pure value type, so every behaviour — EWMA convergence,
/// negative-delta rejection, first-sample fallback, and the pre-chunk abort
/// guard — is exercised with synthetic delta sequences and no real model.
final class PrefillFootprintEstimatorTests: XCTestCase {

    // MARK: - First-sample fallback

    func test_emptyEstimator_hasNoEstimate_andGuardStaysDormant() {
        let estimator = PrefillFootprintEstimator()
        XCTAssertNil(estimator.estimatedBytesPerToken, "No samples → no estimate")
        XCTAssertNil(estimator.predictedTransientBytes(forTokens: 512))
        // Guard must never fire before the first sample, regardless of how tight
        // the supplied headroom is.
        XCTAssertFalse(
            estimator.wouldExceedHeadroom(remainingBytes: 0, nextChunkTokens: 512),
            "Guard must stay dormant until a sample exists"
        )
    }

    func test_singleSample_seedsEstimateExactly() {
        var estimator = PrefillFootprintEstimator()
        // 1,024,000 bytes over 1000 tokens = 1024 bytes/token.
        estimator.record(residentBytesDelta: 1_024_000, tokensProcessed: 1000)
        XCTAssertEqual(estimator.estimatedBytesPerToken, 1024)
        XCTAssertEqual(estimator.sampleCount, 1)
    }

    func test_recordFromBeforeAfterReadings() {
        var estimator = PrefillFootprintEstimator()
        estimator.record(beforeBytes: 1_000_000, afterBytes: 1_512_000, tokensProcessed: 512)
        // 512_000 / 512 = 1000 bytes/token.
        XCTAssertEqual(estimator.estimatedBytesPerToken, 1000)
    }

    func test_nilReadings_areIgnored() {
        var estimator = PrefillFootprintEstimator()
        estimator.record(beforeBytes: nil, afterBytes: 1_000_000, tokensProcessed: 512)
        estimator.record(beforeBytes: 1_000_000, afterBytes: nil, tokensProcessed: 512)
        XCTAssertNil(estimator.estimatedBytesPerToken, "Failed Mach reads must not produce a sample")
        XCTAssertEqual(estimator.sampleCount, 0)
    }

    // MARK: - EWMA convergence

    func test_ewma_tracksTowardSteadyState() {
        var estimator = PrefillFootprintEstimator(smoothingFactor: 0.5)
        // Seed at 1000/tok, then feed steady 2000/tok samples; the EWMA should
        // climb monotonically toward 2000 without ever exceeding it.
        estimator.record(residentBytesDelta: 1000, tokensProcessed: 1)
        var previous = estimator.estimatedBytesPerToken!
        for _ in 0..<8 {
            estimator.record(residentBytesDelta: 2000, tokensProcessed: 1)
            let current = estimator.estimatedBytesPerToken!
            XCTAssertGreaterThan(current, previous, "EWMA should climb toward the new steady state")
            XCTAssertLessThanOrEqual(current, 2000, "EWMA must not overshoot the steady-state value")
            previous = current
        }
        XCTAssertGreaterThan(previous, 1900, "After several samples the estimate should be near 2000")
    }

    // MARK: - Negative-delta rejection

    func test_negativeDelta_isRejected_andDoesNotDragEstimateDown() {
        var estimator = PrefillFootprintEstimator(smoothingFactor: 0.5)
        estimator.record(residentBytesDelta: 100_000, tokensProcessed: 100) // 1000/tok
        let beforeReclaim = estimator.estimatedBytesPerToken
        XCTAssertEqual(beforeReclaim, 1000)

        // A cache-pool reclaim larger than the chunk's allocation: negative delta.
        estimator.record(residentBytesDelta: -5_000_000, tokensProcessed: 100)

        XCTAssertEqual(
            estimator.estimatedBytesPerToken, beforeReclaim,
            "A negative (reclaim) delta must NOT move the estimate"
        )
        XCTAssertEqual(estimator.rejectedSampleCount, 1)
        XCTAssertEqual(estimator.sampleCount, 1, "Rejected sample must not count as accepted")
    }

    func test_allNegativeSamples_yieldNoEstimate() {
        var estimator = PrefillFootprintEstimator()
        estimator.record(residentBytesDelta: -1000, tokensProcessed: 100)
        estimator.record(residentBytesDelta: -2000, tokensProcessed: 100)
        XCTAssertNil(estimator.estimatedBytesPerToken, "All-reclaim run produces no estimate, not zero")
        XCTAssertEqual(estimator.rejectedSampleCount, 2)
    }

    func test_zeroTokens_isRejected() {
        var estimator = PrefillFootprintEstimator()
        estimator.record(residentBytesDelta: 100_000, tokensProcessed: 0)
        XCTAssertNil(estimator.estimatedBytesPerToken)
        XCTAssertEqual(estimator.rejectedSampleCount, 1)
    }

    // MARK: - Pre-chunk abort guard

    func test_guard_firesWhenPredictedTransientExceedsHeadroom() {
        var estimator = PrefillFootprintEstimator()
        estimator.record(residentBytesDelta: 10_000, tokensProcessed: 10) // 1000/tok

        // Next chunk = 512 tokens, safety 1.5 → predicted 768_000 bytes.
        XCTAssertEqual(estimator.predictedTransientBytes(forTokens: 512, safetyFactor: 1.5), 768_000)

        // Headroom below the prediction → abort.
        XCTAssertTrue(
            estimator.wouldExceedHeadroom(remainingBytes: 500_000, nextChunkTokens: 512, safetyFactor: 1.5),
            "Guard must fire when predicted transient exceeds remaining headroom"
        )
    }

    func test_guard_doesNotFireUnderAmpleHeadroom() {
        var estimator = PrefillFootprintEstimator()
        estimator.record(residentBytesDelta: 10_000, tokensProcessed: 10) // 1000/tok
        // Predicted 768_000; headroom well above → proceed.
        XCTAssertFalse(
            estimator.wouldExceedHeadroom(remainingBytes: 5_000_000, nextChunkTokens: 512, safetyFactor: 1.5),
            "Guard must not fire when headroom comfortably covers the prediction"
        )
    }

    func test_safetyFactor_inflatesPrediction() {
        var estimator = PrefillFootprintEstimator()
        estimator.record(residentBytesDelta: 10_000, tokensProcessed: 10) // 1000/tok
        let safe = estimator.predictedTransientBytes(forTokens: 100, safetyFactor: 2.0)!
        let raw = estimator.predictedTransientBytes(forTokens: 100, safetyFactor: 1.0)!
        XCTAssertEqual(raw, 100_000)
        XCTAssertEqual(safe, 200_000, "A 2× safety factor must double the predicted transient")
    }
}
