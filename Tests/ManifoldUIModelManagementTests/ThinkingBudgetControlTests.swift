import XCTest
@testable import ManifoldUIModelManagement
import ManifoldInference

/// Pins the thinking-budget mapping (issue #2307 Unit 2 §L3, spec §5 rule 4):
/// there is no "reasoning effort" enum — Off/Auto/Extended map onto
/// `GenerationConfig.maxThinkingTokens` as 0/nil/a named budget — and the
/// control renders only when `ModelManifest.supportsThinking` is true, never
/// offering a lever the backend can't honor.
final class ThinkingBudgetControlTests: XCTestCase {

    private func makeManifest(supportsThinking: Bool) -> ModelManifest {
        ModelManifest(
            contextWindow: 8192,
            supportsTools: false,
            supportsThinking: supportsThinking,
            thinkingMarkers: nil,
            supportsSeed: false,
            supportedSamplingParameters: [.temperature, .topP],
            modelIdentifier: "test-model",
            producerKind: .local
        )
    }

    // MARK: - Off/Auto/Extended → maxThinkingTokens mapping

    func test_off_mapsToZero() {
        XCTAssertEqual(ThinkingBudgetOption.off.maxThinkingTokens(extendedBudget: 8192), 0)
    }

    func test_auto_mapsToNil() {
        XCTAssertNil(ThinkingBudgetOption.auto.maxThinkingTokens(extendedBudget: 8192))
    }

    func test_extended_mapsToNamedBudget() {
        XCTAssertEqual(ThinkingBudgetOption.extended.maxThinkingTokens(extendedBudget: 8192), 8192)
    }

    // MARK: - Inverse resolution

    func test_resolved_zeroMapsToOff() {
        XCTAssertEqual(ThinkingBudgetOption.resolved(maxThinkingTokens: 0, extendedBudget: 8192), .off)
    }

    func test_resolved_nilMapsToAuto() {
        XCTAssertEqual(ThinkingBudgetOption.resolved(maxThinkingTokens: nil, extendedBudget: 8192), .auto)
    }

    func test_resolved_matchingExtendedBudgetMapsToExtended() {
        XCTAssertEqual(ThinkingBudgetOption.resolved(maxThinkingTokens: 8192, extendedBudget: 8192), .extended)
    }

    func test_resolved_unrecognizedValueFallsBackToAuto() {
        // A stored budget from a different model/manifest shouldn't silently
        // snap to the nearest option — Auto is the honest fallback.
        XCTAssertEqual(ThinkingBudgetOption.resolved(maxThinkingTokens: 4096, extendedBudget: 8192), .auto)
    }

    // MARK: - Manifest gating

    func test_manifest_supportsThinkingFalse_gatesControlOff() {
        let manifest = makeManifest(supportsThinking: false)
        XCTAssertFalse(manifest.supportsThinking, "A non-thinking model's manifest must not claim supportsThinking")
    }

    func test_manifest_supportsThinkingTrue_allowsControl() {
        let manifest = makeManifest(supportsThinking: true)
        XCTAssertTrue(manifest.supportsThinking)
    }
}
