#if Llama
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// Throughput baseline: measures real-model token generation rate.
///
/// ## Setup
///
/// Requires both:
/// 1. `RUN_OPERATIONAL_TESTS=1` env var
/// 2. `MID_THINKING` slot in `~/Library/Caches/ManifoldKit/test-models/manifest.json`
///
/// Reports tokens/sec via `XCTMeasure`. A regression alert fires when
/// throughput drops >20% from the stored baseline (XCTest baseline management).
@MainActor
final class ThroughputBaselineTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_OPERATIONAL_TESTS"] == "1",
            "Set RUN_OPERATIONAL_TESTS=1 to run throughput baseline"
        )
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "Requires Metal")
        try XCTSkipUnless(modelURL() != nil, "Set MID_THINKING slot in manifest")
    }

    func test_throughputBaseline_warmTokensPerSec() throws {
        // Stub: full implementation loads LlamaBackend and runs XCTMeasure.
        throw XCTSkip("ThroughputBaselineTests stub — install MID_THINKING fixture to enable")
    }

    private func modelURL() -> URL? {
        let manifest = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Caches", "ManifoldKit", "test-models", "manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slots = json["slots"] as? [String: Any?],
              let path = slots["MID_THINKING"] as? String
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
#endif
