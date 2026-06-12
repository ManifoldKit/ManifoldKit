import XCTest

/// Backend-seam freeze test (v0.48 companion-package split, #1749).
///
/// Like ``PublicSurfaceTests``, the test method does nothing at runtime —
/// the assertion is at **compile time**. `Fixtures/BackendSeamConsumer.swift`
/// consumes the exact public + `@_spi(BackendInternals)` surface the
/// companion family packages (manifold-mlx / manifold-llama) compile
/// against. If a frozen symbol is removed, renamed, demoted from
/// `public`/SPI, or its signature drifts, the fixture fails to compile and
/// this target fails to build.
///
/// Pair with `scripts/split-proof.sh`, which proves the *whole* family
/// source trees compile against core's products out-of-package — the freeze
/// fixture is the cheap per-PR tripwire; the proof script is the full
/// go/no-go gate run at C1.
@MainActor
final class BackendSeamTests: XCTestCase {

    func test_backendSeamCompiles() {
        // Force the consumer body to be linked in; nothing to verify at runtime.
        BackendSeamConsumer.consumeSeam()
        XCTAssertTrue(true, "Compilation is the assertion. See BackendSeamConsumer.swift.")
    }
}
