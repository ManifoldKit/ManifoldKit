#if Llama
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// Quality baseline: compares deterministic token-id output against stored fixtures.
///
/// Uses token IDs (not decoded strings) to isolate model drift from tokenizer changes.
/// Baseline files live at `tests/fixtures/quality/<backend>/<prompt-hash>.tokenids.json`.
///
/// ## Setup
///
/// Requires `RUN_OPERATIONAL_TESTS=1` and `MID_THINKING` fixture.
@MainActor
final class QualityBaselineTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_OPERATIONAL_TESTS"] == "1",
            "Set RUN_OPERATIONAL_TESTS=1 to run quality baseline"
        )
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "Requires Metal")
    }

    func test_qualityBaseline_fixedPromptTokenIdsMatch() throws {
        throw XCTSkip("QualityBaselineTests stub — install MID_THINKING fixture to enable")
    }
}
#endif
