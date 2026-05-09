#if Llama
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// Real-hardware conformance suite for ``LlamaBackend``.
///
/// Mirrors the invariants from the T1.1 ``BackendContractChecks`` harness
/// (defined in ``ManifoldBackendsTests``). Because that harness lives in a
/// separate test target it cannot be imported here — the invariants are inlined
/// directly rather than cross-target-imported.
///
/// All tests skip cleanly when:
/// - The host is not Apple Silicon (Metal required by llama.cpp).
/// - The test environment is the iOS Simulator (no Metal compute).
/// - The `MID_THINKING` fixture slot in
///   `~/Library/Caches/ManifoldKit/test-models/manifest.json` is `null` or
///   the manifest file is absent.
///
/// ## Why `loadModel` is NOT called here
///
/// Per CLAUDE.md: "LlamaBackend uses a global `llama_backend_init` — only one
/// instance per process." Calling `loadModel` in a conformance test risks
/// accumulating Metal buffer state alongside the existing `LlamaE2ETests` suite.
/// All invariants below execute correctly without loading a model.
@MainActor
final class LlamaBackendE2EConformanceTests: XCTestCase {

    // Fixture slot used by this suite.
    private static let fixtureSlot = "MID_THINKING"

    // MARK: - Fixture discovery

    /// Reads `~/Library/Caches/ManifoldKit/test-models/manifest.json` and returns
    /// the URL for the given fixture slot, or `nil` when the slot is absent, null,
    /// or the manifest does not exist.
    private static func modelURL(forSlot slot: String) -> URL? {
        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Caches", "ManifoldKit", "test-models", "manifest.json")
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
            "LlamaBackend requires Apple Silicon"
        )
        try XCTSkipUnless(
            HardwareRequirements.isPhysicalDevice,
            "LlamaBackend requires Metal (unavailable in simulator)"
        )
        try XCTSkipUnless(
            Self.modelURL(forSlot: Self.fixtureSlot) != nil,
            "Skipping: \(Self.fixtureSlot) slot absent from manifest. " +
            "Install a GGUF and set the path in ~/Library/Caches/ManifoldKit/test-models/manifest.json"
        )
    }

    // MARK: - Pre-load invariants

    /// A freshly initialized backend must report `isModelLoaded == false`.
    func test_preLoad_isModelLoaded_isFalse() throws {
        try requireHardware()
        XCTAssertFalse(
            LlamaBackend().isModelLoaded,
            "LlamaBackend must report isModelLoaded == false before loadModel is called"
        )
    }

    /// A freshly initialized backend must report `isGenerating == false`.
    func test_preLoad_isGenerating_isFalse() throws {
        try requireHardware()
        XCTAssertFalse(
            LlamaBackend().isGenerating,
            "LlamaBackend must report isGenerating == false before any generation"
        )
    }

    /// `generate()` before `loadModel` must throw — not return a stream.
    func test_preLoad_generateBeforeLoad_throws() throws {
        try requireHardware()
        XCTAssertThrowsError(
            try LlamaBackend().generate(
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
            LlamaBackend().capabilities.supportedParameters.isEmpty,
            "LlamaBackend must advertise at least one supported generation parameter"
        )
    }

    /// `unloadModel()` on an unloaded backend must be idempotent (no crash).
    func test_unloadModel_isIdempotent() throws {
        try requireHardware()
        let backend = LlamaBackend()
        backend.unloadModel()
        backend.unloadModel()  // second call must not crash
    }

    /// `stopGeneration()` before `loadModel` must not crash.
    func test_preLoad_stopGeneration_doesNotCrash() throws {
        try requireHardware()
        LlamaBackend().stopGeneration()
    }

    // MARK: - Declared capability flags
    //
    // LlamaBackend declares these tracked flags as `true`. These tests assert
    // the expected declared values, confirming the capabilities API is stable.
    // Phase C will add real behavioral assertions for each.

    func test_capabilities_supportsGrammarConstrainedSampling_isTrue() throws {
        try requireHardware()
        // LlamaBackend declares supportsGrammarConstrainedSampling = true.
        // The fail-closed assertion (assertGrammarFailClosedContract) is skipped
        // here because its false path calls loadModel, which is avoided to
        // prevent Metal global-state accumulation.
        XCTAssertTrue(
            LlamaBackend().capabilities.supportsGrammarConstrainedSampling,
            "LlamaBackend must declare supportsGrammarConstrainedSampling = true"
        )
    }

    func test_capabilities_supportsThinking_isTrue() throws {
        try requireHardware()
        XCTAssertTrue(
            LlamaBackend().capabilities.supportsThinking,
            "LlamaBackend must declare supportsThinking = true"
        )
    }

    func test_capabilities_supportsToolCalling_isTrue() throws {
        try requireHardware()
        XCTAssertTrue(
            LlamaBackend().capabilities.supportsToolCalling,
            "LlamaBackend must declare supportsToolCalling = true"
        )
    }

    func test_capabilities_supportsKVCachePersistence_isTrue() throws {
        try requireHardware()
        XCTAssertTrue(
            LlamaBackend().capabilities.supportsKVCachePersistence,
            "LlamaBackend must declare supportsKVCachePersistence = true"
        )
    }

    func test_capabilities_supportsTokenCounting_isTrue() throws {
        try requireHardware()
        XCTAssertTrue(
            LlamaBackend().capabilities.supportsTokenCounting,
            "LlamaBackend must declare supportsTokenCounting = true"
        )
    }
}
#endif
