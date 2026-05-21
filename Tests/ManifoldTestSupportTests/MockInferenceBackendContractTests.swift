import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - MockInferenceBackendContractTests

/// Verifies that ``MockInferenceBackend`` satisfies the ``InferenceBackendContract``
/// mixin. This serves two purposes:
///
/// 1. It validates that the contract mixin itself compiles and runs correctly.
/// 2. It locks in the documented behavior of ``MockInferenceBackend`` so that
///    changes to the mock that violate the contract are caught immediately.
@MainActor
final class MockInferenceBackendContractTests: XCTestCase, InferenceBackendContract {

    func makeInferenceBackend() -> any InferenceBackend {
        MockInferenceBackend()
    }

    // MARK: - InferenceBackendContract test methods

    /// A freshly-constructed mock reports `isModelLoaded == false`.
    func test_freshBackend_isNotLoaded() {
        assertInferenceBackend_freshBackendIsNotLoaded()
    }

    /// A freshly-constructed mock reports `isGenerating == false`.
    func test_freshBackend_isNotGenerating() {
        assertInferenceBackend_freshBackendIsNotGenerating()
    }

    /// `loadModel` → `unloadModel` cycle transitions `isModelLoaded` correctly.
    func test_loadUnloadCycle_updatesIsModelLoaded() async throws {
        try await assertInferenceBackend_loadUnloadCycleUpdatesIsModelLoaded()
    }

    /// `BackendCapabilities.maxContextTokens` must be positive.
    func test_capabilities_havePositiveContextWindow() {
        assertInferenceBackend_capabilitiesHavePositiveContextWindow()
    }

    /// `generate()` produces at least one event for a loaded model.
    func test_generate_producesEvents() async throws {
        try await assertInferenceBackend_generateProducesEvents()
    }

    /// `stopGeneration()` satisfies the ready-for-reuse contract.
    func test_stopGeneration_satisfiesContract() async throws {
        try await assertInferenceBackend_stopGenerationContract()
    }

    /// `resetConversation()` is idempotent and does not unload the model.
    func test_resetConversation_isIdempotent() async throws {
        try await assertInferenceBackend_resetConversationIsIdempotent()
    }
}
