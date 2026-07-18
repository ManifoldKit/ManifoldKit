@preconcurrency import XCTest
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
@testable import ManifoldTestSupport

/// Pins the "+" menu's flag mapping (issue #2307 Unit 2 §L3): every affordance
/// maps 1:1 to its existing `ManifoldConfiguration.Features` flag and
/// capability check, unchanged by the composer redesign
/// (`ChatInputBar.swift:87-99`'s gating comment, preserved item-by-item).
///
/// Mirrors ``ChatInputBarLogicTests``'s precedent: the conditions are asserted
/// directly against the same properties `ChatInputBar`'s `@ViewBuilder`
/// bodies gate on, since the view itself is a thin projection of this state.
@MainActor
final class ComposerAffordanceMappingTests: XCTestCase {

    private nonisolated(unsafe) var harnesses: [TestChatViewModelHarness] = []
    private var savedFeatures: ManifoldConfiguration.Features!

    override func setUp() {
        super.setUp()
        savedFeatures = ManifoldConfiguration.shared.features
    }

    override func tearDown() async throws {
        ManifoldConfiguration.shared.features = savedFeatures
        for harness in harnesses { harness.cleanup() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeViewModel(mock: MockInferenceBackend) -> ChatViewModel {
        let harness = try! makeTestChatViewModel(mock: mock, activateSession: true)
        harnesses.append(harness)
        return harness.vm
    }

    // MARK: - Attach-image affordance: ChatInputBar.swift:87
    // `features.showImageAttachment && viewModel.supportsImageAttachments`

    func test_attachImageAffordance_absentWhenFlagOff_evenIfBackendSupportsVision() {
        ManifoldConfiguration.shared.features.showImageAttachment = false
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: true))
        let vm = makeViewModel(mock: mock)
        XCTAssertTrue(vm.supportsImageAttachments, "Precondition: backend supports vision")
        XCTAssertFalse(
            ManifoldConfiguration.shared.features.showImageAttachment && vm.supportsImageAttachments,
            "Attach-image affordance must be absent when the feature flag is off, even with a vision-capable backend"
        )
    }

    func test_attachImageAffordance_absentWhenBackendLacksVision_evenIfFlagOn() {
        ManifoldConfiguration.shared.features.showImageAttachment = true
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: false))
        let vm = makeViewModel(mock: mock)
        XCTAssertFalse(
            ManifoldConfiguration.shared.features.showImageAttachment && vm.supportsImageAttachments,
            "Attach-image affordance must be absent when the backend lacks vision support, even with the flag on"
        )
    }

    func test_attachImageAffordance_presentWhenFlagOnAndBackendSupportsVision() {
        ManifoldConfiguration.shared.features.showImageAttachment = true
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: true))
        let vm = makeViewModel(mock: mock)
        XCTAssertTrue(
            ManifoldConfiguration.shared.features.showImageAttachment && vm.supportsImageAttachments,
            "Attach-image affordance must be present when the flag is on and the backend supports vision"
        )
    }

    // MARK: - Record-audio affordance (iOS): ChatInputBar.swift:96
    // `ComposerPermissionGate.shouldShowAudioInput(features:)` alone — no
    // second, independently-computed condition should creep in.

    func test_recordAudioAffordance_mapsThroughComposerPermissionGateAlone() {
        let bundleWithoutKeys = Bundle(for: ComposerAffordanceMappingTests.self)

        let onFeatures = ManifoldConfiguration.Features(showAudioInput: true)
        let offFeatures = ManifoldConfiguration.Features(showAudioInput: false)

        // The test bundle declares no NSMicrophoneUsageDescription, so the
        // flag alone can never force `true` — this is the SIGABRT guard
        // ComposerPermissionGateTests already pins; re-asserted here against
        // the mapping the "+" menu actually consumes.
        XCTAssertFalse(ComposerPermissionGate.shouldShowAudioInput(features: onFeatures, bundle: bundleWithoutKeys))
        XCTAssertFalse(ComposerPermissionGate.shouldShowAudioInput(features: offFeatures, bundle: bundleWithoutKeys))
    }

    // MARK: - Regenerate affordance: ChatInputBar.swift's showRegenerateButton
    // `!isGenerating && !messages.isEmpty && messages.last?.role == .assistant`

    func test_regenerateAffordance_absentWhenNoMessages() {
        let mock = MockInferenceBackend()
        let vm = makeViewModel(mock: mock)
        let showRegenerate = !vm.isGenerating && !vm.messages.isEmpty && vm.messages.last?.role == .assistant
        XCTAssertFalse(showRegenerate, "Regenerate must be absent with no prior messages")
    }
}
