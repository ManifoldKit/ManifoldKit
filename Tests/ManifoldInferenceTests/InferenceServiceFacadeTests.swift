import XCTest
import Observation
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests that the InferenceService facade correctly dispatches to
/// both coordinators after the decomposition (#279).
@MainActor
final class InferenceServiceFacadeTests: XCTestCase {

    // MARK: - End-to-end roundtrips

    func test_facade_loadAndGenerate_endToEnd() async throws {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " world"]
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? mock : nil }

        try await service.loadModel(from: makeModelInfo(), plan: .testStub())
        XCTAssertTrue(service.isModelLoaded)

        let (_, stream) = try service.enqueue(messages: [("user", "hi")])
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        XCTAssertEqual(tokens, ["Hello", " world"])
        XCTAssertFalse(service.isGenerating)
    }

    func test_facade_unloadCancelsQueue() async throws {
        let mock = GatedBackend()
        let service = InferenceService(backend: mock, name: "Mock")

        let (_, stream1) = try service.enqueue(messages: [("user", "first")])
        let (_, stream2) = try service.enqueue(messages: [("user", "second")])

        service.unloadModel()

        XCTAssertFalse(service.isModelLoaded)
        XCTAssertFalse(service.isGenerating)
        XCTAssertFalse(service.hasQueuedRequests)
        XCTAssertTrue(
            { if case .failed = stream1.phase { return true }; return false }()
        )
        XCTAssertTrue(
            { if case .failed = stream2.phase { return true }; return false }()
        )
    }

    // MARK: - Observable propagation through facade

    func test_facade_observableProperties_propagateFromCoordinators() async throws {
        // isModelLoaded observation through facade
        let mock = MockInferenceBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? mock : nil }

        let loadObserved = expectation(description: "isModelLoaded")
        withObservationTracking {
            _ = service.isModelLoaded
        } onChange: {
            loadObserved.fulfill()
        }

        try await service.loadModel(from: makeModelInfo(), plan: .testStub())
        await fulfillment(of: [loadObserved], timeout: 2)
        XCTAssertTrue(service.isModelLoaded)

        // isGenerating observation through facade
        let gatedMock = GatedBackend()
        let gatedService = InferenceService(backend: gatedMock, name: "Gated")
        let genObserved = expectation(description: "isGenerating")
        withObservationTracking {
            _ = gatedService.isGenerating
        } onChange: {
            genObserved.fulfill()
        }
        _ = try gatedService.enqueue(messages: [("user", "hi")])
        await fulfillment(of: [genObserved], timeout: 2)
        XCTAssertTrue(gatedService.isGenerating)
    }

    // MARK: - Public API compile check

    func test_facade_publicAPICompileCheck() throws {
        let service = InferenceService()

        // Registration
        service.registerBackendFactory { _ in nil }
        service.registerEndpointBackendFactory { _ in nil }
        service.declareSupport(for: .gguf)
        service.declareSupport(for: .ollama)

        // State reads
        _ = service.isModelLoaded
        _ = service.isGenerating
        _ = service.activeBackendName
        _ = service.modelLoadProgress
        _ = service.capabilities
        _ = service.hasQueuedRequests
        _ = service.lastTokenUsage
        _ = service.tokenizer
        _ = service.selectedPromptTemplate
        _ = service.denyPolicy

        // Capability queries
        _ = service.compatibility(for: .gguf)
        _ = service.compatibility(for: .ollama)
        _ = service.registeredBackendSnapshot()

        // Actions (no model loaded, so these just verify compilation)
        service.unloadModel()
        service.resetConversation()
        service.stopGeneration()
    }

    // MARK: - Helpers

    private func makeModelInfo() -> ModelInfo {
        ModelInfo(
            name: "Test",
            fileName: "Test.bin",
            url: URL(fileURLWithPath: "/Test.bin"),
            fileSize: 0,
            modelType: .gguf
        )
    }
}

// MARK: - Test Backends

private final class GatedBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private var activeContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        isGenerating = true
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
            self?.activeContinuation = continuation
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {
        isGenerating = false
        activeContinuation?.finish()
        activeContinuation = nil
    }

    func unloadModel() {
        isModelLoaded = false
        isGenerating = false
        activeContinuation?.finish()
        activeContinuation = nil
    }
}
