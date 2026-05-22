import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Regression lock tests written **before** the InferenceService decomposition (#279).
///
/// These cover previously untested public API surface so that any behavioral change
/// introduced during the coordinator extraction is caught immediately.
@MainActor
final class InferenceServiceRegressionLockTests: XCTestCase {

    // MARK: - resetConversation

    func test_resetConversation_delegatesToBackend() {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "Mock")
        XCTAssertEqual(mock.resetConversationCallCount, 0)

        service.resetConversation()

        XCTAssertEqual(mock.resetConversationCallCount, 1)
    }

    func test_resetConversation_noopWhenNoBackend() {
        let service = InferenceService()
        // Must not crash.
        service.resetConversation()
    }

    // MARK: - registeredBackendSnapshot

    func test_registeredBackendSnapshot_emptyWhenNoFactories() {
        let service = InferenceService()
        let snapshot = service.registeredBackendSnapshot()
        XCTAssertTrue(snapshot.localModelTypes.isEmpty)
        XCTAssertTrue(snapshot.cloudProviders.isEmpty)
    }

    func test_registeredBackendSnapshot_reflectsDeclaredSupport() {
        let service = InferenceService()
        service.registerBackendFactory { _ in nil }
        service.declareSupport(for: .gguf)
        service.registerCloudBackendFactory { _ in nil }
        service.declareSupport(for: .ollama)

        let snapshot = service.registeredBackendSnapshot()
        XCTAssertTrue(snapshot.localModelTypes.contains(.gguf))
        XCTAssertTrue(snapshot.cloudProviders.contains(.ollama))
    }

    // MARK: - compatibility

    func test_compatibility_forModelType_supported() {
        let service = InferenceService()
        service.declareSupport(for: .gguf)

        let result = service.compatibility(for: .gguf)
        XCTAssertEqual(result, .supported)
    }

    func test_compatibility_forModelType_unsupported() {
        let service = InferenceService()
        // No declarations.
        let result = service.compatibility(for: .mlx)
        if case .unsupported(let reason) = result {
            XCTAssertFalse(reason.isEmpty, "Unsupported result should include a reason")
        } else {
            XCTFail("Expected .unsupported, got \(result)")
        }
    }

    func test_compatibility_forAPIProvider_supported() {
        let service = InferenceService()
        service.declareSupport(for: .ollama)

        let result = service.compatibility(for: .ollama)
        XCTAssertEqual(result, .supported)
    }

    func test_compatibility_forAPIProvider_unsupported() {
        let service = InferenceService()
        // No declarations.
        let result = service.compatibility(for: .claude)
        if case .unsupported(let reason) = result {
            XCTAssertFalse(reason.isEmpty, "Unsupported result should include a reason")
        } else {
            XCTFail("Expected .unsupported, got \(result)")
        }
    }

    // MARK: - lastTokenUsage

    func test_lastTokenUsage_nilWhenNoBackend() {
        let service = InferenceService()
        XCTAssertNil(service.lastTokenUsage)
    }

    func test_lastTokenUsage_nilWhenBackendLacksProvider() {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "Mock")
        // MockInferenceBackend does not conform to TokenUsageProvider.
        XCTAssertNil(service.lastTokenUsage)
    }

    // MARK: - declareSupport accumulation

    func test_declareSupport_accumulatesMultipleTypes() {
        let service = InferenceService()
        service.declareSupport(for: .gguf)
        service.declareSupport(for: .mlx)

        let snapshot = service.registeredBackendSnapshot()
        XCTAssertEqual(snapshot.localModelTypes, [.gguf, .mlx])
    }

    func test_declareSupport_accumulatesMultipleProviders() {
        let service = InferenceService()
        service.declareSupport(for: .ollama)
        service.declareSupport(for: .lmStudio)

        let snapshot = service.registeredBackendSnapshot()
        XCTAssertEqual(snapshot.cloudProviders, [.ollama, .lmStudio])
    }
}

// MARK: - Test Helpers

/// Minimal gated backend that blocks generation until explicitly released.
/// Duplicated here (also exists in InferenceServiceQueueTests) to keep test files
/// self-contained without coupling their helpers.
private final class GatedMockBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private var gates: [AsyncThrowingStream<GenerationEvent, Error>.Continuation] = []

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        isGenerating = true
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
            self?.gates.append(continuation)
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {
        isGenerating = false
        for gate in gates { gate.finish() }
    }

    func unloadModel() {
        isModelLoaded = false
        isGenerating = false
        for gate in gates { gate.finish() }
        gates.removeAll()
    }
}
