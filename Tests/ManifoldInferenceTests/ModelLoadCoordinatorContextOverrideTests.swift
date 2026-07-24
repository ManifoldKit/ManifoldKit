import XCTest
@testable import ManifoldInference
import ManifoldHardware
import ManifoldTestSupport

/// Tripwire for the per-session context-size override wiring.
///
/// `ChatSession.contextSizeOverride` (schema V9) is read by `ContextEstimator`
/// for the token-budget display, but until this wiring it never reached the
/// model load — so an explicit override silently failed to enlarge the backend's
/// real context window (the classic "compiles but does nothing" trap). These
/// tests exercise the real seam → ``ModelLoadPlan`` path so a regression that
/// drops the override (returns the surface to inert) fails the suite.
@MainActor
final class ModelLoadCoordinatorContextOverrideTests: XCTestCase {

    private func makeService(mock: MockInferenceBackend) -> InferenceService {
        let service = InferenceService()
        // The coordinator computes the plan from `modelType`; the factory just has
        // to vend a backend so the load reaches `loadModel(from:plan:)`.
        service.registerBackendFactory { _ in mock }
        return service
    }

    private func makeFoundationModel(detectedContext: Int?) -> ModelInfo {
        // `.foundation` → `systemManaged` plan, which is unconditionally `.allow`
        // and carries `requestedContextSize` through verbatim, so the assertion
        // isolates the override resolution from any memory-fit clamping.
        ModelInfo(
            name: "ctx-test.foundation",
            fileName: "ctx-test.foundation",
            url: URL(fileURLWithPath: "/virtual/ctx-test"),
            fileSize: 0,
            modelType: .foundation,
            detectedContextLength: detectedContext
        )
    }

    func test_override_raisesRequestedContextAboveConservativeDefaultCeiling() async {
        let mock = MockInferenceBackend()
        let coordinator = makeService(mock: mock).modelLoadCoordinator
        coordinator.currentContextSizeOverride = { 32_768 }

        await coordinator.loadLocalModel(makeFoundationModel(detectedContext: 65_536), generation: nil)

        XCTAssertEqual(
            mock.lastLoadPlan?.inputs.requestedContextSize,
            32_768,
            "An explicit session contextSizeOverride must raise the requested context above the 8192 default ceiling."
        )
    }

    func test_override_isClampedToModelDetectedMax() async {
        let mock = MockInferenceBackend()
        let coordinator = makeService(mock: mock).modelLoadCoordinator
        coordinator.currentContextSizeOverride = { 1_000_000 }

        await coordinator.loadLocalModel(makeFoundationModel(detectedContext: 16_384), generation: nil)

        XCTAssertEqual(
            mock.lastLoadPlan?.inputs.requestedContextSize,
            16_384,
            "An override larger than the model's detected native max must be capped at the detected max."
        )
    }

    func test_noOverride_keepsConservativeDefaultCeiling() async {
        let mock = MockInferenceBackend()
        // Seam left at its default (nil) — mirrors a headless load with no session.
        let coordinator = makeService(mock: mock).modelLoadCoordinator

        await coordinator.loadLocalModel(makeFoundationModel(detectedContext: 65_536), generation: nil)

        XCTAssertEqual(
            mock.lastLoadPlan?.inputs.requestedContextSize,
            8_192,
            "Without an override the conservative Metal-safe ceiling must stand."
        )
    }

    // MARK: - #2348: MLX models must honor a real detectedContextLength

    private func makeMLXModel(detectedContext: Int?, fileSize: UInt64 = 1) -> ModelInfo {
        // `.mlx` → `ModelLoadPlan.compute(for:strategy:.resident,...)`, which
        // *does* apply memory-fit clamping to `outcome.effectiveContextSize`
        // — but `inputs.requestedContextSize` (what these assertions read, same
        // as the `.foundation` tests above) is recorded before that clamp runs,
        // so a tiny `fileSize` here isolates the override-resolution assertion
        // from memory-fit behavior without needing to fake `Environment`.
        ModelInfo(
            name: "ctx-test.mlx",
            fileName: "ctx-test.mlx",
            url: URL(fileURLWithPath: "/virtual/ctx-test-mlx"),
            fileSize: fileSize,
            modelType: .mlx,
            detectedContextLength: detectedContext
        )
    }

    /// The #2348 regression: before MLX `ModelInfo`s carried a real
    /// `detectedContextLength` (populated from `config.json`'s
    /// `max_position_embeddings`, see `ModelInfoCapabilityFlagsTests`), this
    /// path's `detected` fell back to the hardcoded 8192 for every MLX model,
    /// silently re-imposing the ceiling regardless of a session override. This
    /// test simulates the now-correctly-populated `detectedContextLength` and
    /// asserts the override survives `min(override, detected)` for `.mlx`
    /// exactly as it already does for `.foundation`.
    func test_mlx_override_raisesRequestedContextAboveConservativeDefaultCeiling() async {
        let mock = MockInferenceBackend()
        let coordinator = makeService(mock: mock).modelLoadCoordinator
        coordinator.currentContextSizeOverride = { 32_768 }

        await coordinator.loadLocalModel(makeMLXModel(detectedContext: 131_072), generation: nil)

        XCTAssertEqual(
            mock.lastLoadPlan?.inputs.requestedContextSize,
            32_768,
            "An MLX model with a real detected context length must let the override raise requestedContextSize above 8192."
        )
    }

    func test_mlx_noDetectedContextLength_staysAtHardcodedFallback() async {
        let mock = MockInferenceBackend()
        let coordinator = makeService(mock: mock).modelLoadCoordinator
        coordinator.currentContextSizeOverride = { 32_768 }

        // Mirrors the pre-#2348 state (detectedContextLength never populated for MLX):
        // the override is still clamped to the hardcoded 8192 fallback, matching
        // ModelLoadCoordinator.swift's `model.detectedContextLength ?? 8_192`.
        await coordinator.loadLocalModel(makeMLXModel(detectedContext: nil), generation: nil)

        XCTAssertEqual(
            mock.lastLoadPlan?.inputs.requestedContextSize,
            8_192,
            "Without a detected context length, MLX must fall back to the same 8192 ceiling as before #2348."
        )
    }
}
