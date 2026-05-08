#if MLX
import XCTest
import BaseChatInference
@testable import BaseChatTestSupport
@testable import BaseChatBackends

/// Real-hardware conformance suite for ``MLXBackend``.
///
/// Mirrors the invariants from the T1.1 ``BackendContractChecks`` harness
/// (defined in ``BaseChatBackendsTests``). Because that harness lives in a
/// separate test target it cannot be imported here — the invariants are inlined
/// directly rather than cross-target-imported.
///
/// All tests skip cleanly when:
/// - The host is not Apple Silicon (MLX requires arm64 + Metal).
/// - The test environment is the iOS Simulator (no Metal compute).
/// - The `MID_THINKING` fixture slot in
///   `~/Library/Caches/BaseChatKit/test-models/manifest.json` is `null` or
///   the manifest file is absent.
///
/// ## Why `loadModel` is NOT called here
///
/// MLX model loading requires Metal shader compilation from `.metallib` files
/// embedded in the Xcode framework bundle. SwiftPM builds (including `swift test`)
/// do not produce a `.app` bundle, so Metal shader compilation fails with
/// "Metal library not found". Loading an MLX model requires Xcode and is exercised
/// separately via `scripts/test-mlx-integration.sh`.
@MainActor
final class MLXBackendE2EConformanceTests: XCTestCase {

    // Fixture slot used by this suite.
    private static let fixtureSlot = "MID_THINKING"

    // MARK: - Fixture discovery

    /// Reads `~/Library/Caches/BaseChatKit/test-models/manifest.json` and returns
    /// the URL for the given fixture slot, or `nil` when the slot is absent, null,
    /// or the manifest does not exist.
    private static func modelURL(forSlot slot: String) -> URL? {
        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Caches", "BaseChatKit", "test-models", "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slots = json["slots"] as? [String: Any?],
              let pathValue = slots[slot] as? String
        else { return nil }
        return URL(fileURLWithPath: pathValue)
    }

    // MARK: - Hardware prerequisites

    private func requireHardware() throws {
        try XCTSkipUnless(
            HardwareRequirements.isAppleSilicon,
            "MLXBackend requires Apple Silicon"
        )
        try XCTSkipUnless(
            HardwareRequirements.isPhysicalDevice,
            "MLXBackend requires Metal (unavailable in simulator)"
        )
        try XCTSkipUnless(
            Self.modelURL(forSlot: Self.fixtureSlot) != nil,
            "Skipping: \(Self.fixtureSlot) slot absent from manifest. " +
            "Install an MLX model directory and set the path in ~/Library/Caches/BaseChatKit/test-models/manifest.json"
        )
    }

    // MARK: - Pre-load invariants

    /// A freshly initialized backend must report `isModelLoaded == false`.
    func test_preLoad_isModelLoaded_isFalse() throws {
        try requireHardware()
        XCTAssertFalse(
            MLXBackend().isModelLoaded,
            "MLXBackend must report isModelLoaded == false before loadModel is called"
        )
    }

    /// A freshly initialized backend must report `isGenerating == false`.
    func test_preLoad_isGenerating_isFalse() throws {
        try requireHardware()
        XCTAssertFalse(
            MLXBackend().isGenerating,
            "MLXBackend must report isGenerating == false before any generation"
        )
    }

    /// `generate()` before `loadModel` must throw — not return a stream.
    func test_preLoad_generateBeforeLoad_throws() throws {
        try requireHardware()
        XCTAssertThrowsError(
            try MLXBackend().generate(
                prompt: "hello",
                systemPrompt: nil,
                config: GenerationConfig()
            ),
            "generate() must throw when called before loadModel()"
        )
    }

    /// The backend must advertise at least one supported generation parameter.
    func test_capabilities_supportedParameters_nonEmpty() throws {
        try requireHardware()
        XCTAssertFalse(
            MLXBackend().capabilities.supportedParameters.isEmpty,
            "MLXBackend must advertise at least one supported generation parameter"
        )
    }

    /// `unloadModel()` on an unloaded backend must be idempotent (no crash).
    func test_unloadModel_isIdempotent() throws {
        try requireHardware()
        let backend = MLXBackend()
        backend.unloadModel()
        backend.unloadModel()  // second call must not crash
    }

    /// `stopGeneration()` before `loadModel` must not crash.
    func test_preLoad_stopGeneration_doesNotCrash() throws {
        try requireHardware()
        MLXBackend().stopGeneration()
    }

    // MARK: - Declared capability flags
    //
    // A default MLXBackend() (cachePolicy: .auto, enableKVCacheReuse: false)
    // has supportsVision=false and supportsKVCachePersistence=false; these
    // assertions cover the static declared-true flags only.

    func test_capabilities_supportsToolCalling_isTrue() throws {
        try requireHardware()
        XCTAssertTrue(
            MLXBackend().capabilities.supportsToolCalling,
            "MLXBackend must declare supportsToolCalling = true"
        )
    }

    func test_capabilities_supportsThinking_isTrue() throws {
        try requireHardware()
        XCTAssertTrue(
            MLXBackend().capabilities.supportsThinking,
            "MLXBackend must declare supportsThinking = true"
        )
    }

    func test_capabilities_supportsTokenCounting_isTrue() throws {
        try requireHardware()
        XCTAssertTrue(
            MLXBackend().capabilities.supportsTokenCounting,
            "MLXBackend must declare supportsTokenCounting = true"
        )
    }
}
#endif
