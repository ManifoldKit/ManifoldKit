@preconcurrency import XCTest
import SwiftUI
import ViewInspector
import ManifoldRuntime
import ManifoldInference
@testable import ManifoldUI

/// Visual-contract tests for the Unit 2 §L4 state-screen components
/// (`docs/UI-REFRESH-2026.md` §6A/§4A/§12): first-run funnel, milestone-named
/// bootstrap loading, the in-transcript turn-failure card, the composer
/// fault banner, and the branch-origin chip. Each of these views only reads
/// `@Environment(\.manifoldTheme)` (which resolves to `.standard` by
/// default), so — unlike ``MessagePartsView`` — no `ChatViewModel`
/// environment setup is required to render them.
@MainActor
final class StateScreensTests: XCTestCase {

    // MARK: - FirstRunFunnelView

    func test_firstRunFunnel_exposesBothCTAsAndInvokesClosures() throws {
        var browsedModels = false
        var configuredEndpoint = false
        let view = FirstRunFunnelView(
            appName: "Sample Chat",
            onBrowseModels: { browsedModels = true },
            onConfigureEndpoint: { configuredEndpoint = true }
        )

        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "first-run-funnel")
        try view.inspect().find(viewWithAccessibilityIdentifier: "first-run-browse-models-button").button().tap()
        try view.inspect().find(viewWithAccessibilityIdentifier: "first-run-configure-endpoint-button").button().tap()

        XCTAssertTrue(browsedModels)
        XCTAssertTrue(configuredEndpoint)
    }

    // MARK: - BootstrapLoadingView

    func test_bootstrapLoading_rendersEachMilestonesDescription() throws {
        for milestone in RuntimeBootstrapMilestone.allCases {
            let view = BootstrapLoadingView(milestone: milestone)
            _ = try view.inspect().find(text: milestone.description)
        }
    }

    // MARK: - TurnFailureCardView

    func test_turnFailureCard_rendersRetryAndDetails_whenBothSupplied() throws {
        var retried = false
        var showedDetails = false
        let view = TurnFailureCardView(
            message: "Generation failed.",
            onRetry: { retried = true },
            onDetails: { showedDetails = true }
        )

        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "turn-failure-card")
        try view.inspect().find(viewWithAccessibilityIdentifier: "turn-failure-retry-button").button().tap()
        try view.inspect().find(viewWithAccessibilityIdentifier: "turn-failure-details-button").button().tap()

        XCTAssertTrue(retried)
        XCTAssertTrue(showedDetails)
    }

    func test_turnFailureCard_omitsActions_whenClosuresNil() throws {
        let view = TurnFailureCardView(message: "Generation failed.")

        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "turn-failure-retry-button")
        )
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "turn-failure-details-button")
        )
    }

    // MARK: - ComposerFaultBannerView

    func test_composerFaultBanner_rendersFixButton_whenSupplied() throws {
        var fixed = false
        let view = ComposerFaultBannerView(
            message: "Microphone access is off.",
            fixLabel: "Open Settings",
            onFix: { fixed = true }
        )

        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "composer-fault-banner")
        try view.inspect().find(viewWithAccessibilityIdentifier: "composer-fault-fix-button").button().tap()
        XCTAssertTrue(fixed)
    }

    func test_composerFaultBanner_omitsFixButton_whenNotSupplied() throws {
        let view = ComposerFaultBannerView(message: "Attachment could not be staged.")
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "composer-fault-fix-button")
        )
    }

    // MARK: - BranchOriginChipView

    func test_branchOriginChip_rendersOriginTitle_whenPresent() throws {
        let view = BranchOriginChipView(originSessionTitle: "Planning the Q3 roadmap")
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "branch-origin-chip")
        _ = try view.inspect().find(text: "Branched from Planning the Q3 roadmap")
    }

    func test_branchOriginChip_suppressed_whenOriginTitleNil() throws {
        let view = BranchOriginChipView(originSessionTitle: nil)
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "branch-origin-chip")
        )
    }

    // MARK: - GeneratedMediaProgressCardView

    func test_generatedMediaProgressCard_image_rendersStepLabelAndInvokesCancel() throws {
        var cancelled = false
        let view = GeneratedMediaProgressCardView(
            prompt: "a lighthouse at dusk",
            progress: .image(step: 3, totalSteps: 10, previewImage: nil),
            onCancel: { cancelled = true }
        )

        _ = try view.inspect().find(text: "Step 3 of 10")
        try view.inspect().find(viewWithAccessibilityIdentifier: "generated-media-progress-cancel").button().tap()
        XCTAssertTrue(cancelled)
    }

    func test_generatedMediaProgressCard_video_rendersPercentLabel() throws {
        let view = GeneratedMediaProgressCardView(
            prompt: "a drone shot over the ocean",
            progress: .video(fractionComplete: 0.5),
            onCancel: {}
        )
        _ = try view.inspect().find(text: "50%")
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "generated-media-progress-video")
    }

    /// Audio was the one modality the 2026 UI refresh (#2307) left out of
    /// `GeneratedMediaProgressCardView.Progress` — see `MessagePartsView`'s
    /// `activeAudioGenerationProgress` wiring (gap C of the UI-honesty audit,
    /// #2356).
    func test_generatedMediaProgressCard_audio_rendersPercentLabelAndInvokesCancel() throws {
        var cancelled = false
        let view = GeneratedMediaProgressCardView(
            prompt: "read the summary aloud",
            progress: .audio(fractionComplete: 0.65),
            onCancel: { cancelled = true }
        )
        _ = try view.inspect().find(text: "65%")
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "generated-media-progress-audio")
        try view.inspect().find(viewWithAccessibilityIdentifier: "generated-media-progress-cancel").button().tap()
        XCTAssertTrue(cancelled)
    }

    // MARK: - EmptySessionSuggestionsView

    func test_emptySessionSuggestions_tappingChip_invokesOnSelectWithSuggestionText() throws {
        var selected: String?
        let view = EmptySessionSuggestionsView(
            suggestions: ["Summarize this document"],
            onSelectSuggestion: { selected = $0 }
        )

        try view.inspect().find(viewWithAccessibilityIdentifier: "empty-session-suggestion-chip").button().tap()

        XCTAssertEqual(selected, "Summarize this document")
    }

    func test_emptySessionSuggestions_rendersNoChips_whenSuggestionsEmpty() throws {
        let view = EmptySessionSuggestionsView(suggestions: [])
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "empty-session-suggestion-chip")
        )
    }
}
