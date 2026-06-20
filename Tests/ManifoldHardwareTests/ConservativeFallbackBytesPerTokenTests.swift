import XCTest
// SPI import is needed only here, in the test — the whole point of the public
// `ModelLoadPlan.conservativeFallbackBytesPerToken` constant (#1963) is that app
// code never has to do this.
@_spi(BackendInternals) import ManifoldHardware

/// Guards the single-source-of-truth invariant for the public conservative KV-cache
/// fallback (#1963): `ModelLoadPlan.conservativeFallbackBytesPerToken` must alias the
/// `@_spi(BackendInternals)` heuristic `GGUFKVCacheEstimator.legacyFallbackBytesPerToken`
/// so the public constant and the internal estimator can never drift.
final class ConservativeFallbackBytesPerTokenTests: XCTestCase {

    func testPublicConstantMatchesSPIEstimatorFallback() {
        XCTAssertEqual(
            ModelLoadPlan.conservativeFallbackBytesPerToken,
            GGUFKVCacheEstimator.legacyFallbackBytesPerToken,
            "Public fallback must stay equal to the SPI estimator's legacy fallback — they share a definition, so divergence means the alias was broken."
        )
    }
}
