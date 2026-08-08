import XCTest
@testable import ManifoldUIModelManagement
import ManifoldInference
import ManifoldModelCatalog
import ManifoldHardware

/// Guards against the `DownloadableModelRow` availability-source regression:
/// the row used to resolve backend compatibility from `CompiledBackends.current`
/// (a compile-time contract that, by construction, never contains `.gguf`/`.mlx`
/// — those register at RUNTIME from the companion packages, #1749). The result
/// was every GGUF/MLX row in the download browser telling the user to install a
/// companion package they had already installed and registered — confirmed live
/// in the shipping app `fireside`.
///
/// The fix threads a `ModelRegistry` into the row and resolves compatibility
/// through `DownloadableModelRow.resolveCompatibility(for:capabilityService:modelRegistry:)`,
/// which reflects live backend registration on `InferenceService`. These tests
/// exercise that seam directly — no app, no companion package, no simulator.
@MainActor
final class DownloadableModelRowCompatibilityTests: XCTestCase {

    private func makeRegistry() -> (InferenceService, ModelRegistry) {
        let inference = InferenceService()
        let storage = ModelStorageService(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadableModelRowCompatibilityTests-\(UUID().uuidString)")
        )
        let registry = ModelRegistry(inferenceService: inference, modelStorage: storage)
        return (inference, registry)
    }

    /// Before the fix, `.gguf` compatibility never changed no matter what the
    /// live `InferenceService` had registered — this test is RED against that
    /// body (see PR description for the captured failure output).
    func test_resolveCompatibility_reflectsRuntimeBackendRegistration() {
        let (inference, registry) = makeRegistry()

        let before = DownloadableModelRow.resolveCompatibility(
            for: .gguf,
            capabilityService: nil,
            modelRegistry: registry
        )
        XCTAssertFalse(before.isSupported, "A fresh InferenceService has no GGUF backend registered")

        // Exactly what LlamaBackends.register(with:) does on the runtime path.
        inference.declareSupport(for: .gguf)

        let after = DownloadableModelRow.resolveCompatibility(
            for: .gguf,
            capabilityService: nil,
            modelRegistry: registry
        )
        XCTAssertEqual(after, .supported)
        XCTAssertNil(after.unavailableReason)
    }

    /// Pins the exact wrong string `CompiledBackends` used to produce
    /// ("...compiled into this build...") so a reintroduced
    /// `?? CompiledBackends.current` fallback fails loudly instead of merely
    /// reporting `.unsupported` for a different (correct) reason.
    func test_resolveCompatibility_neverReportsCompiledBackendsCompanionCopy() {
        let (inference, registry) = makeRegistry()
        inference.declareSupport(for: .mlx)

        let result = DownloadableModelRow.resolveCompatibility(
            for: .mlx,
            capabilityService: nil,
            modelRegistry: registry
        )

        XCTAssertTrue(result.isSupported)
        if let reason = result.unavailableReason {
            XCTAssertFalse(
                reason.contains("compiled into this build"),
                "Must never surface CompiledBackends' compile-time wording: \(reason)"
            )
        }
    }

    /// A host-injected `FrameworkCapabilityService` (basechat's path) wins over
    /// the `modelRegistry` fallback even when the registry disagrees.
    func test_resolveCompatibility_injectedCapabilityServiceTakesPrecedence() {
        let (_, registry) = makeRegistry()
        // The registry's own InferenceService has NOT declared GGUF support...
        let capabilityInference = InferenceService()
        capabilityInference.declareSupport(for: .gguf)
        // ...but the injected capability service is backed by one that HAS.
        let capabilityService = FrameworkCapabilityService(inferenceService: capabilityInference)

        let result = DownloadableModelRow.resolveCompatibility(
            for: .gguf,
            capabilityService: capabilityService,
            modelRegistry: registry
        )

        XCTAssertTrue(result.isSupported, "The injected capability service must win over the registry fallback")
    }
}
