@preconcurrency import XCTest
import SwiftUI
@testable import ManifoldUIModelManagement
@testable import ManifoldInference

/// Verifies the pure verdict→color and recommended-quant→label mappings that back the
/// device-fit badges in the model browser. The SwiftUI layout itself is not unit-testable,
/// but the mapping functions are deterministic and isolated here so the green/yellow/red
/// contract and the quant-naming string cannot silently drift.
@MainActor
final class FitVerdictBadgeTests: XCTestCase {

    // MARK: - FitQuality → tint

    func test_fitTint_excellentAndGood_areGreen() {
        XCTAssertEqual(DownloadableModelRow.fitTint(.excellent), .green)
        XCTAssertEqual(DownloadableModelRow.fitTint(.good), .green)
    }

    func test_fitTint_marginal_isYellow() {
        XCTAssertEqual(DownloadableModelRow.fitTint(.marginal), .yellow)
    }

    func test_fitTint_notRecommended_isRed() {
        XCTAssertEqual(DownloadableModelRow.fitTint(.notRecommended), .red)
        // Sabotage guard: a denied verdict must never read as green/yellow.
        XCTAssertNotEqual(DownloadableModelRow.fitTint(.notRecommended), .green)
    }

    func test_fitTint_coversAllCases() {
        // CaseIterable tripwire: a new FitQuality case must get an explicit tint.
        for quality in FitQuality.allCases {
            let tint = DownloadableModelRow.fitTint(quality)
            XCTAssertTrue(
                [.green, .yellow, .red].contains(tint),
                "FitQuality.\(quality) mapped to an unexpected tint"
            )
        }
    }

    // MARK: - Recommended-quant naming

    func test_bestForDeviceLabel_namesQuant_whenPresent() {
        let label = HuggingFaceBrowserView.bestForDeviceLabel(
            noVariantFits: false,
            recommendedQuant: "Q4_K_M",
            isRecommendedSort: true
        )
        XCTAssertEqual(label, "Best for your device: Q4_K_M")
    }

    func test_bestForDeviceLabel_omitsQuant_whenMissingOrEmpty() {
        XCTAssertEqual(
            HuggingFaceBrowserView.bestForDeviceLabel(
                noVariantFits: false, recommendedQuant: nil, isRecommendedSort: true
            ),
            "Best for your device"
        )
        XCTAssertEqual(
            HuggingFaceBrowserView.bestForDeviceLabel(
                noVariantFits: false, recommendedQuant: "", isRecommendedSort: true
            ),
            "Best for your device"
        )
    }

    func test_bestForDeviceLabel_nonRecommendedSort_usesRecommendedBase() {
        XCTAssertEqual(
            HuggingFaceBrowserView.bestForDeviceLabel(
                noVariantFits: false, recommendedQuant: "Q5_K_M", isRecommendedSort: false
            ),
            "Recommended: Q5_K_M"
        )
    }

    func test_bestForDeviceLabel_noVariantFits_usesSmallestBase() {
        XCTAssertEqual(
            HuggingFaceBrowserView.bestForDeviceLabel(
                noVariantFits: true, recommendedQuant: "Q3_K_S", isRecommendedSort: true
            ),
            "Smallest available: Q3_K_S"
        )
    }
}
