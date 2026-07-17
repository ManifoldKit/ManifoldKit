@preconcurrency import XCTest
import SwiftUI
@testable import ManifoldUIModelManagement
@testable import ManifoldInference

/// Companion to `Tests/ManifoldUITests/DefaultAppearanceCharacterizationTests.swift`
/// for the `ManifoldUIModelManagement`-module anchors named in issue #2307
/// §1.1 (`docs/UI-REFRESH-2026-PLAN.md`): `ModelPicker.swift:256-259` and
/// `DownloadableModelRow.swift:165-229`. Split into its own file/target
/// because `ManifoldUITests` cannot import `ManifoldUIModelManagement`
/// (dependency direction: mmgmt depends on UI, never the reverse).
///
/// Lands, and must pass, **before** `T1-migrate-mmgmt` routes these literals
/// through `ManifoldTheme` — the plan's sync point 1.
///
/// ## Coverage vs. anchor
///
/// - `DownloadableModelRow.fitTint(_:)` (`:165-171`) is `static`/non-`private`,
///   so it's directly callable and already fully pinned by
///   `Tests/ManifoldUIModelManagementTests/FitVerdictBadgeTests.swift`
///   (`test_fitTint_*`). `test_downloadableModelRow_fitTint_matchesHistoricalMapping`
///   below re-asserts the same mapping from this characterization file so the
///   pin survives independently of that feature-test file's lifecycle.
/// - `DownloadableModelRow.speedTint(_:)` / `.badgeColor(canRun:isBorderline:)`
///   (`:194-229`) and `ModelPicker.typeBadge(for:isCompatible:)` (`:253-273`)
///   are all `private` — uncallable from this file — and render through
///   `@Environment(ModelManagementViewModel.self)` /
///   `@Environment(FrameworkCapabilityService.self)`, which this test target
///   has no `ViewInspector` dependency to render and inspect (see
///   `Package.swift`'s `ManifoldUIModelManagementTests` target — no
///   `ViewInspector` product listed). These three are **not** runtime-pinned
///   here. `HardcodedColorAuditTest` (§1.4) still polices their literal text
///   against silent drift via source scanning; the `T1-migrate-mmgmt` tranche
///   carries the burden of proving the resolved colors are unchanged.
///   Flagged for the orchestrator — a real coverage gap, not an oversight.
@MainActor
final class DefaultAppearanceCharacterizationTests: XCTestCase {

    func test_downloadableModelRow_fitTint_matchesHistoricalMapping() {
        XCTAssertEqual(DownloadableModelRow.fitTint(.excellent), .green, "DownloadableModelRow.swift:167")
        XCTAssertEqual(DownloadableModelRow.fitTint(.good), .green, "DownloadableModelRow.swift:167")
        XCTAssertEqual(DownloadableModelRow.fitTint(.marginal), .yellow, "DownloadableModelRow.swift:168")
        XCTAssertEqual(DownloadableModelRow.fitTint(.notRecommended), .red, "DownloadableModelRow.swift:169")
    }
}
