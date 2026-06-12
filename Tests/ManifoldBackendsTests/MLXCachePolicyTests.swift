#if MLX
import XCTest
@_spi(Testing) import ManifoldMLX
import ManifoldBackends

/// Pure-logic tests for `MLXCachePolicy.resolvedBytes()`.
///
/// These do not exercise MLX's `Memory.cacheLimit` global directly — that
/// would require the MLX runtime and a way to read the value back, which
/// isn't worth the surface area for verifying one assignment. Instead we
/// test that the policy resolver returns sensible byte counts across the
/// four cases. Integration with the actual MLX backend is covered by the
/// existing `MLXBackendTests` suite.
final class MLXCachePolicyTests: XCTestCase {

    func test_minimal_returnsTwentyMegabytes() {
        XCTAssertEqual(MLXCachePolicy.minimal.resolvedBytes(), 20 * 1024 * 1024)
    }

    func test_explicit_returnsRequestedBytes() {
        XCTAssertEqual(
            MLXCachePolicy.explicit(bytes: 123_456).resolvedBytes(),
            123_456
        )
    }

    func test_explicit_clampsNegativeToZero() {
        XCTAssertEqual(MLXCachePolicy.explicit(bytes: -1).resolvedBytes(), 0)
    }

    /// `.auto`'s smallest bucket is 64 MB; any test machine should be at
    /// least there. This guards against the resolver returning the historical
    /// 20 MB value or accidentally returning zero.
    func test_auto_isAtLeastSixtyFourMegabytes() {
        XCTAssertGreaterThanOrEqual(
            MLXCachePolicy.auto.resolvedBytes(),
            64 * 1024 * 1024
        )
    }

    /// `.auto`'s largest bucket is 1 GB. This guards against the resolver
    /// accidentally returning physical RAM directly.
    func test_auto_isAtMostOneGigabyte() {
        XCTAssertLessThanOrEqual(
            MLXCachePolicy.auto.resolvedBytes(),
            1024 * 1024 * 1024
        )
    }

    func test_generous_isLargerThanMinimal() {
        XCTAssertGreaterThan(
            MLXCachePolicy.generous.resolvedBytes(),
            MLXCachePolicy.minimal.resolvedBytes()
        )
    }

    /// `.generous` is capped at 4 GB regardless of physical RAM. This guards
    /// against allocating absurd amounts on Mac Studio-class machines.
    func test_generous_isCappedAtFourGigabytes() {
        XCTAssertLessThanOrEqual(
            MLXCachePolicy.generous.resolvedBytes(),
            4 * 1024 * 1024 * 1024
        )
    }

    func test_equatable() {
        XCTAssertEqual(MLXCachePolicy.auto, MLXCachePolicy.auto)
        XCTAssertEqual(MLXCachePolicy.explicit(bytes: 100), MLXCachePolicy.explicit(bytes: 100))
        XCTAssertNotEqual(MLXCachePolicy.auto, MLXCachePolicy.minimal)
        XCTAssertNotEqual(MLXCachePolicy.explicit(bytes: 100), MLXCachePolicy.explicit(bytes: 200))
    }
}
#endif
