import XCTest
import Observation
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests that `@Observable` property changes on `InferenceService` trigger
/// observation tracking.
///
/// Written **before** the decomposition (#279) so that if the extraction breaks
/// observation propagation through the facade's computed properties, these tests
/// fail immediately.
@MainActor
final class InferenceServiceObservationTests: XCTestCase {

    // MARK: - isModelLoaded

    func test_isModelLoaded_triggersObservation_onLoad() async throws {
        let mock = MockInferenceBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? mock : nil }

        let changed = expectation(description: "isModelLoaded observed")
        withObservationTracking {
            _ = service.isModelLoaded
        } onChange: {
            changed.fulfill()
        }

        try await service.loadModel(from: makeModelInfo(), plan: .testStub())
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertTrue(service.isModelLoaded)
    }

    func test_isModelLoaded_triggersObservation_onUnload() {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "Mock")
        XCTAssertTrue(service.isModelLoaded)

        let changed = expectation(description: "isModelLoaded observed")
        withObservationTracking {
            _ = service.isModelLoaded
        } onChange: {
            changed.fulfill()
        }

        service.unloadModel()
        wait(for: [changed], timeout: 2)
        XCTAssertFalse(service.isModelLoaded)
    }

    // MARK: - isGenerating

    func test_isGenerating_triggersObservation_onEnqueue() throws {
        let mock = GatedBackend()
        let service = InferenceService(backend: mock, name: "Mock")

        let changed = expectation(description: "isGenerating observed")
        withObservationTracking {
            _ = service.isGenerating
        } onChange: {
            changed.fulfill()
        }

        _ = try service.enqueue(messages: [Message.user("hi")], config: GenerationConfig())
        wait(for: [changed], timeout: 2)
        XCTAssertTrue(service.isGenerating)
    }

    // MARK: - activeBackendName

    func test_activeBackendName_triggersObservation_onLoad() async throws {
        let mock = MockInferenceBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? mock : nil }

        let changed = expectation(description: "activeBackendName observed")
        withObservationTracking {
            _ = service.activeBackendName
        } onChange: {
            changed.fulfill()
        }

        try await service.loadModel(from: makeModelInfo(), plan: .testStub())
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertNotNil(service.activeBackendName)
    }

    // MARK: - activeModelName

    func test_activeModelName_triggersObservation_onLoad() async throws {
        let mock = MockInferenceBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in type == .gguf ? mock : nil }

        let changed = expectation(description: "activeModelName observed")
        withObservationTracking {
            _ = service.activeModelName
        } onChange: {
            changed.fulfill()
        }

        try await service.loadModel(from: makeModelInfo(), plan: .testStub())
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(service.activeModelName, "Test")
    }

    // MARK: - modelLoadProgress

    func test_modelLoadProgress_triggersObservation_onLoadStart() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let changed = expectation(description: "modelLoadProgress observed")
        withObservationTracking {
            _ = service.modelLoadProgress
        } onChange: {
            changed.fulfill()
        }

        let loadTask = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()

        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(service.modelLoadProgress, 0.0)

        await backend.releaseLoad()
        try await loadTask.value
    }

    func test_modelLoadProgress_triggersObservation_onComplete() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let loadTask = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()

        // Now modelLoadProgress is 0.0 — observe the transition to nil on completion.
        XCTAssertEqual(service.modelLoadProgress, 0.0)

        let changed = expectation(description: "modelLoadProgress nil on complete")
        withObservationTracking {
            _ = service.modelLoadProgress
        } onChange: {
            changed.fulfill()
        }

        await backend.releaseLoad()
        try await loadTask.value

        await fulfillment(of: [changed], timeout: 2)
        XCTAssertNil(service.modelLoadProgress)
    }

    // MARK: - Model Load Readiness

    func test_modelLoadReadinessUpdates_yieldsCurrentReadyState() async {
        let service = InferenceService(backend: MockInferenceBackend(), name: "Mock")

        var iterator = service.modelLoadReadinessUpdates().makeAsyncIterator()
        let state = await iterator.next()

        XCTAssertEqual(state, .ready)
    }

    func test_modelLoadReadinessUpdates_emitsLoadingAndReadyTransitions() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        var iterator = service.modelLoadReadinessUpdates().makeAsyncIterator()
        // XCTAssertEqual takes non-async autoclosures; extract awaited values first.
        let initialState = await iterator.next()
        XCTAssertEqual(initialState, .idle)

        let loadTask = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()

        let loadingState = await iterator.next()
        XCTAssertEqual(loadingState, .loading(progress: 0.0))

        await backend.releaseLoad()
        try await loadTask.value

        let readyState = await iterator.next()
        XCTAssertEqual(readyState, .ready)
    }

    func test_waitUntilModelReady_returnsFalseWhenIdle() async {
        let service = InferenceService()

        let ready = await service.waitUntilModelReady(maxPollCount: 5, pollIntervalNanoseconds: 0)

        XCTAssertFalse(ready)
    }

    func test_waitUntilModelReady_awaitsInFlightLoad() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let loadTask = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()

        let waitTask = Task { await service.waitUntilModelReady(maxPollCount: 50, pollIntervalNanoseconds: 50_000_000) }
        await backend.releaseLoad()

        let ready = await waitTask.value
        try await loadTask.value

        XCTAssertTrue(ready)
    }

    func test_waitUntilModelReady_timesOutWhenLoadNeverCompletes() async {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let loadTask = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()

        let ready = await service.waitUntilModelReady(maxPollCount: 1, pollIntervalNanoseconds: 1_000_000)

        XCTAssertFalse(ready)
        loadTask.cancel()
        await backend.releaseLoad()
        _ = try? await loadTask.value
    }

    func test_waitUntilModelReady_acceptsSyntheticReadinessStream() async {
        let stream = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.loading(progress: 0.5))
            Task {
                await Task.yield()
                continuation.yield(.ready)
                continuation.finish()
            }
        }

        let ready = await InferenceService.waitUntilModelReady(
            readinessUpdates: stream,
            maxPollCount: 300,
            pollIntervalNanoseconds: 50_000_000
        )

        XCTAssertTrue(ready)
    }

    func test_waitUntilModelReady_withSyntheticStreamCancelsPromptly() async {
        let stream = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.loading(progress: 0.5))
        }
        let task = Task {
            await InferenceService.waitUntilModelReady(
                readinessUpdates: stream,
                maxPollCount: 300,
                pollIntervalNanoseconds: 50_000_000
            )
        }

        await Task.yield()
        let cancelStart = ContinuousClock.now
        task.cancel()
        let ready = await task.value
        let elapsed = ContinuousClock.now - cancelStart

        XCTAssertFalse(ready)
        XCTAssertLessThan(elapsed, .milliseconds(500))
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

/// Blocks generation until explicitly released, for observing isGenerating transitions.
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
        activeContinuation?.finish()
        activeContinuation = nil
    }
}

/// Blocks loadModel until explicitly released, for observing modelLoadProgress transitions.
private final class GatedLoadBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded: Bool = false
    var isGenerating: Bool = false
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private let gate = LoadGate()

    func waitUntilLoadStarted() async { await gate.waitUntilStarted() }
    func releaseLoad() async { await gate.release() }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        await gate.markStarted()
        await gate.waitForRelease()
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}

/// Simple actor-based gate for controlling when loadModel completes.
private actor LoadGate {
    private var started = false
    private var released = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }
}
