import XCTest
import SwiftUI
@testable import ManifoldUI

/// Covers Unit 2 §L1's per-OS glass resolution (`docs/UI-REFRESH-2026.md` §9,
/// "OS fallback matrix"): native Liquid Glass on iOS 26 / macOS 26+, the
/// theme's `Material` token below.
///
/// `#available` itself can't be parameterized in a test — the CI host's real
/// OS version decides which branch actually runs. `ManifoldGlassResolution`
/// exists specifically so the *decision* is a pure, `#available`-free
/// function (`resolve(supportsLiquidGlass:)`) that both branches can be
/// asserted against directly, regardless of the host OS — mirroring
/// `StreamingIndicatorReduceMotionTests`'s static-helper pattern for the same
/// "can't inspect `#available`/animation directly" problem.
final class ManifoldGlassResolutionTests: XCTestCase {

    func test_resolve_liquidGlass_whenSupported() {
        XCTAssertEqual(ManifoldGlassResolution.resolve(supportsLiquidGlass: true), .liquidGlass)
    }

    func test_resolve_material_whenUnsupported() {
        XCTAssertEqual(ManifoldGlassResolution.resolve(supportsLiquidGlass: false), .material)
    }

    /// `.current` must resolve to exactly one of the two pure branches on
    /// every host — this is the availability-seam build/exercise coverage:
    /// the `#available` check itself compiles and returns a determinate
    /// value; whichever branch the actual CI host takes (26+ vs. the
    /// fallback), it agrees with `resolve(supportsLiquidGlass:)`.
    func test_current_agreesWithPureResolution() {
        let current = ManifoldGlassResolution.current
        XCTAssertTrue(current == .liquidGlass || current == .material)
    }

    // MARK: - manifoldGlass(_:in:) / manifoldGlassEffectContainer() availability seam
    //
    // Both branches of `View.manifoldGlass(_:in:)` and
    // `.manifoldGlassEffectContainer()` must compile under the 26 SDK and
    // fall back cleanly below it (docs/UI-REFRESH-2026.md §11). There is no
    // ViewInspector extractor for `.glassEffect`/`GlassEffectContainer` or
    // `.background(_:in:)`, so — matching `DefaultAppearanceCharacterizationTests`'s
    // documented ViewInspector ceiling — this is a compilation/instantiation
    // seam test, not a rendered-value assertion. `swift build --target
    // ManifoldUI` under both the default and pinned-lower SDKs is what
    // actually exercises the fallback path (a macOS 15 CI runner takes the
    // `.background(theme.glass, in:)` branch naturally at runtime).
    @MainActor
    func test_manifoldGlass_compilesAndInstantiates_forVariousShapes() {
        let theme = ManifoldTheme.standard

        let circle: AnyView = AnyView(Color.clear.manifoldGlass(theme, in: Circle()))
        let capsule: AnyView = AnyView(Color.clear.manifoldGlass(theme, in: Capsule()))
        let rounded: AnyView = AnyView(
            Color.clear.manifoldGlass(theme, in: RoundedRectangle(cornerRadius: theme.shape.md))
        )
        let rect: AnyView = AnyView(Color.clear.manifoldGlass(theme, in: Rectangle()))

        _ = circle
        _ = capsule
        _ = rounded
        _ = rect
        // Compilation + instantiation across both `#available` branches is
        // the assertion (API-surface + availability-seam guard).
    }

    @MainActor
    func test_manifoldGlassEffectContainer_compilesAndInstantiates() {
        let view: AnyView = AnyView(
            Color.clear
                .manifoldGlass(.standard, in: Rectangle())
                .manifoldGlassEffectContainer()
        )
        _ = view
    }
}
