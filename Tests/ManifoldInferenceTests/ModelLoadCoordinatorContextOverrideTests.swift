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
}
