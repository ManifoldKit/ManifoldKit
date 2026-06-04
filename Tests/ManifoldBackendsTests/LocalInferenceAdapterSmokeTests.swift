import XCTest
import ManifoldInference
#if Llama
@testable import ManifoldLlama
#endif
#if MLX
@testable import ManifoldMLX
#endif

/// Smoke conformance test for `LocalInferenceAdapter`.
///
/// Asserts that each shipping driver:
///   1. Declares a non-empty `adapterName`.
///   2. Composes a `LocalToolCallShape` whose `shapeName` matches the
///      inline-XML witness shipped today.
///   3. Reports a `thinkingMarkerStrategy` consistent with how the driver
///      actually engages `ThinkingTransform`.
///   4. Publishes a `declaredCapabilities` payload that is internally
///      coherent (e.g. `cancellationStyle == .cooperative` and
///      `isRemote == false`).
///
/// This is the structural counterpart to `InferenceBackendContractTests` —
/// it catches a driver landing without its conformance metadata aligned
/// with the backend's claimed capabilities.
final class LocalInferenceAdapterSmokeTests: XCTestCase {

    #if Llama
    func test_llamaGenerationDriverConformsToProtocol() {
        let driver = LlamaGenerationDriver()
        assertAdapterShape(driver, expectedName: "llama.generation")
    }
    #endif

    #if MLX
    @MainActor
    func test_mlxGenerationDriverConformsToProtocol() {
        let driver = MLXGenerationDriver()
        assertAdapterShape(driver, expectedName: "mlx.generation")
        XCTAssertTrue(
            driver.declaredCapabilities.sharesMLXProcessResources,
            "MLX driver must advertise shared process-global resources"
        )
    }
    #endif

    // MARK: - Helper

    private func assertAdapterShape(
        _ adapter: any LocalInferenceAdapter,
        expectedName: String
    ) {
        XCTAssertEqual(adapter.adapterName, expectedName)
        XCTAssertEqual(adapter.toolCallShape.shapeName, "local.inline-xml")
        XCTAssertEqual(adapter.thinkingMarkerStrategy, .eagerWhenMarkersPresent)

        let caps = adapter.declaredCapabilities
        XCTAssertFalse(caps.isRemote, "Local adapter cannot claim isRemote=true")
        XCTAssertEqual(caps.cancellationStyle, .cooperative,
                       "Both shipping local drivers use cooperative cancellation")
        XCTAssertTrue(caps.supportsStreaming, "Local drivers always stream")
        XCTAssertTrue(caps.supportsThinking,
                      "Driver advertises thinking via thinkingMarkerStrategy = .eagerWhenMarkersPresent")
    }
}
