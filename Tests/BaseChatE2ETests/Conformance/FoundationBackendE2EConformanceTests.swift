#if canImport(FoundationModels)
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// Real-hardware conformance suite for ``FoundationBackend``.
///
/// Mirrors the invariants from the T1.1 ``BackendContractChecks`` harness
/// (defined in ``BaseChatBackendsTests``). Because that harness lives in a
/// separate test target it cannot be imported here — the invariants are inlined
/// directly rather than cross-target-imported.
///
/// All tests skip cleanly when:
/// - The OS is below iOS 26 / macOS 26 (FoundationModels framework unavailable).
/// - Apple Intelligence is not enabled on the device
///   (`FoundationBackend.isAvailable == false`).
///
/// No fixture slot is required — ``FoundationBackend`` does not load external
/// model files; the model is owned by the system.
///
/// ## Why `loadModel` is NOT called here
///
/// `FoundationBackend.loadModel` creates a live `LanguageModelSession`. Session
/// creation is expensive and can fail non-deterministically in environments where
/// the on-device model is not yet downloaded. All pre-load invariants are fully
/// exercisable without a live session.
@available(iOS 26, macOS 26, *)
@MainActor
final class FoundationBackendE2EConformanceTests: XCTestCase {

    // MARK: - Availability prerequisites

    private func requireAvailability() throws {
        // The @available annotation on the class enforces the OS floor.
        // This runtime check catches the case where the OS version is met but
        // Apple Intelligence is disabled or not yet downloaded.
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Skipping: Apple Intelligence is not available on this device. " +
            "Enable Apple Intelligence in Settings and ensure the model is downloaded."
        )
    }

    // MARK: - Pre-load invariants

    /// A freshly initialized backend must report `isModelLoaded == false`.
    func test_preLoad_isModelLoaded_isFalse() throws {
        try requireAvailability()
        XCTAssertFalse(
            FoundationBackend().isModelLoaded,
            "FoundationBackend must report isModelLoaded == false before loadModel is called"
        )
    }

    /// A freshly initialized backend must report `isGenerating == false`.
    func test_preLoad_isGenerating_isFalse() throws {
        try requireAvailability()
        XCTAssertFalse(
            FoundationBackend().isGenerating,
            "FoundationBackend must report isGenerating == false before any generation"
        )
    }

    /// `generate()` before `loadModel` must throw — not return a stream.
    func test_preLoad_generateBeforeLoad_throws() throws {
        try requireAvailability()
        XCTAssertThrowsError(
            try FoundationBackend().generate(
                prompt: "hello",
                systemPrompt: nil,
                config: GenerationConfig()
            ),
            "generate() must throw when called before loadModel()"
        )
    }

    /// The backend must advertise at least one supported generation parameter.
    func test_capabilities_supportedParameters_nonEmpty() throws {
        try requireAvailability()
        XCTAssertFalse(
            FoundationBackend().capabilities.supportedParameters.isEmpty,
            "FoundationBackend must advertise at least one supported generation parameter"
        )
    }

    /// `unloadModel()` on an unloaded backend must be idempotent (no crash).
    func test_unloadModel_isIdempotent() throws {
        try requireAvailability()
        let backend = FoundationBackend()
        backend.unloadModel()
        backend.unloadModel()  // second call must not crash
    }

    /// `stopGeneration()` before `loadModel` must not crash.
    func test_preLoad_stopGeneration_doesNotCrash() throws {
        try requireAvailability()
        FoundationBackend().stopGeneration()
    }

    // MARK: - Declared capability flags

    func test_capabilities_supportsToolCalling_isTrue() throws {
        try requireAvailability()
        XCTAssertTrue(
            FoundationBackend().capabilities.supportsToolCalling,
            "FoundationBackend must declare supportsToolCalling = true"
        )
    }

    func test_capabilities_supportsGuidedStructuredOutput_isTrue() throws {
        try requireAvailability()
        XCTAssertTrue(
            FoundationBackend().capabilities.supportsGuidedStructuredOutput,
            "FoundationBackend must declare supportsGuidedStructuredOutput = true"
        )
    }
}
#endif
