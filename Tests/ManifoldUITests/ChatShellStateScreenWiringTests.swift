@preconcurrency import XCTest
import SwiftUI
import ViewInspector
import ManifoldRuntime
import ManifoldInference
@testable import ManifoldUI

/// Proves the Unit 2 §6A state screens are actually reachable from real
/// `ChatView`/`ChatHistoryView`/`ChatComposerSection` state — not just
/// standalone components nobody calls (the #2064 "read path with no
/// writer" lesson, Principle 10).
@MainActor
final class ChatShellStateScreenWiringTests: XCTestCase {

    // MARK: - First-run funnel (ChatNoModelLoadedContent)

    func test_noModelLoadedContent_rendersFirstRunFunnel_whenFirstRunAndNoModels() throws {
        let view = ChatNoModelLoadedContent(
            appName: "Sample Chat",
            hasAvailableModels: false,
            isFirstRun: true,
            showModelManagement: .constant(false),
            showAPIConfiguration: .constant(false)
        )
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "first-run-funnel")
    }

    func test_noModelLoadedContent_fallsBackToWelcomePrompt_whenNotFirstRun() throws {
        let view = ChatNoModelLoadedContent(
            appName: "Sample Chat",
            hasAvailableModels: false,
            isFirstRun: false,
            showModelManagement: .constant(false),
            showAPIConfiguration: .constant(false)
        )
        // Returning visitor with no models configured (deleted models, fresh
        // restore, etc.) — should NOT re-run the first-run funnel copy.
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "first-run-funnel")
        )
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "chat-model-management-button")
    }

    func test_firstRunFunnel_browseModelsCTA_flipsShowModelManagementBinding() throws {
        var showModelManagement = false
        var showAPIConfiguration = false
        let view = ChatNoModelLoadedContent(
            appName: "Sample Chat",
            hasAvailableModels: false,
            isFirstRun: true,
            showModelManagement: Binding(get: { showModelManagement }, set: { showModelManagement = $0 }),
            showAPIConfiguration: Binding(get: { showAPIConfiguration }, set: { showAPIConfiguration = $0 })
        )

        try view.inspect().find(viewWithAccessibilityIdentifier: "first-run-browse-models-button").button().tap()
        XCTAssertTrue(showModelManagement)
        XCTAssertFalse(showAPIConfiguration)
    }

    func test_firstRunFunnel_configureEndpointCTA_flipsShowAPIConfigurationBinding() throws {
        var showModelManagement = false
        var showAPIConfiguration = false
        let view = ChatNoModelLoadedContent(
            appName: "Sample Chat",
            hasAvailableModels: false,
            isFirstRun: true,
            showModelManagement: Binding(get: { showModelManagement }, set: { showModelManagement = $0 }),
            showAPIConfiguration: Binding(get: { showAPIConfiguration }, set: { showAPIConfiguration = $0 })
        )

        try view.inspect().find(viewWithAccessibilityIdentifier: "first-run-configure-endpoint-button").button().tap()
        XCTAssertTrue(showAPIConfiguration)
        XCTAssertFalse(showModelManagement)
    }

    // MARK: - In-transcript turn-failure card (ChatHistoryView)

    // Rendering `ChatHistoryView`/`ChatErrorRecoveryBanner` directly via
    // ViewInspector isn't viable here: both read `@Environment(ChatViewModel.self)`
    // with no default, and ViewInspector's `.environment(_:)` does not
    // actually satisfy Observation-based `@Environment(Type.self)` reads
    // during inspection in this setup — confirmed by reproducing a process
    // abort (`Fatal error: No Observable object of type ChatViewModel found`)
    // when attempting exactly that. `ChatError.rendersAsTurnLevelFailure`
    // (`ChatShellViews.swift`) is the pure boolean both call sites' `if`
    // conditions are written against, specifically so the scope-routing
    // logic has a testable seam that doesn't require rendering either view.
    // `StateScreensTests` separately proves `TurnFailureCardView` itself
    // renders correctly in isolation.
    func test_rendersAsTurnLevelFailure_trueForGenerationKind() {
        let error = ChatError(kind: .generation, message: "The model ran out of context.")
        XCTAssertTrue(error.rendersAsTurnLevelFailure)
    }

    func test_rendersAsTurnLevelFailure_falseForEveryOtherKind() {
        for kind: ChatError.Kind in [.persistence, .configuration, .memoryPressure] {
            let error = ChatError(kind: kind, message: "x")
            XCTAssertFalse(
                error.rendersAsTurnLevelFailure,
                "\(kind) must stay session-level (the banner), not the in-transcript card"
            )
        }
    }

    // MARK: - Composer fault banner gating (pure helper)

    /// An empty-Info.plist bundle (a bare temp directory) — guaranteed to
    /// lack `NSMicrophoneUsageDescription`, unlike the SwiftPM test-runner's
    /// own `Bundle.main`, which the default-parameter form would resolve to.
    private var bundleWithoutMicrophoneUsageDescription: Bundle {
        Bundle(path: NSTemporaryDirectory())!
    }

    func test_voiceInputSilentlyWithheld_trueWhenEnabledButPermissionKeyMissing() {
        var features = ManifoldConfiguration.Features()
        features.showAudioInput = true

        XCTAssertTrue(
            ChatComposerSection.voiceInputSilentlyWithheld(
                features: features,
                bundle: bundleWithoutMicrophoneUsageDescription
            )
        )
    }

    func test_voiceInputSilentlyWithheld_falseWhenFeatureDisabled() {
        var features = ManifoldConfiguration.Features()
        features.showAudioInput = false

        XCTAssertFalse(
            ChatComposerSection.voiceInputSilentlyWithheld(
                features: features,
                bundle: bundleWithoutMicrophoneUsageDescription
            )
        )
    }

    // MARK: - Default empty state (EmptySessionSuggestionsView)

    func test_chatHistoryEmptyPlaceholder_rendersSuggestionChips_whenNoHostOverride() throws {
        let harness = try makeTestChatViewModel()
        defer { harness.cleanup() }

        let view = ChatHistoryEmptyPlaceholder(customContentBuilder: nil, viewModel: harness.vm)
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "empty-session-suggestions")
    }

    func test_chatHistoryEmptyPlaceholder_respectsHostOverride() throws {
        let harness = try makeTestChatViewModel()
        defer { harness.cleanup() }

        let view = ChatHistoryEmptyPlaceholder(
            customContentBuilder: { AnyView(Text("Custom empty state").accessibilityIdentifier("custom-empty-state")) },
            viewModel: harness.vm
        )
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "custom-empty-state")
        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "empty-session-suggestions")
        )
    }

    // MARK: - Pin glyph moved into the metadata row

    func test_messageBubble_pinGlyph_rendersInMetadataRow_whenPinned() throws {
        let msg = ChatMessage(role: .assistant, content: "Hello", sessionID: UUID())
        let view = MessageBubbleView(message: msg, isStreaming: false, isPinned: true)
            .environment(ChatViewModel())

        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "message-pin-glyph-\(msg.id.uuidString)")
    }

    func test_messageBubble_pinGlyph_absent_whenNotPinned() throws {
        let msg = ChatMessage(role: .assistant, content: "Hello", sessionID: UUID())
        let view = MessageBubbleView(message: msg, isStreaming: false, isPinned: false)
            .environment(ChatViewModel())

        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: "message-pin-glyph-\(msg.id.uuidString)")
        )
    }
}
