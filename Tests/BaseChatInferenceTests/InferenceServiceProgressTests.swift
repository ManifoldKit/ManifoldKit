import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests for `InferenceService.modelLoadProgress` and the `LoadProgressReporting`
/// opt-in protocol.
///
/// These tests verify the progress lifecycle (nil → 0.0 → fractional → nil) and
/// the stale-request suppression that prevents progress from one load corrupting
/// the state of a newer load.
@MainActor
final class InferenceServiceProgressTests: XCTestCase {

    // MARK: - Resting state

    func test_modelLoadProgress_isNilAtRest() {
        let service = InferenceService()
        XCTAssertNil(service.modelLoadProgress)
    }

    // MARK: - Load lifecycle

    func test_modelLoadProgress_zeroOnLoadStart() async throws {
        let service = InferenceService()
        let backend = ProgressReportingBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let task = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()

        XCTAssertEqual(service.modelLoadProgress, 0.0,
                       "modelLoadProgress should be seeded to 0.0 once loadModel begins")

        await backend.releaseLoadSuccess()
        try await task.value
    }

    func test_modelLoadProgress_handlerUpdatesArePublished() async throws {
        let service = InferenceService()
        let backend = ProgressReportingBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let task = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()

        await backend.fireProgress(0.25)
        try await waitForProgress(0.25, on: service)

        await backend.fireProgress(0.75)
        try await waitForProgress(0.75, on: service)

        await backend.releaseLoadSuccess()
        try await task.value
    }

    func test_modelLoadProgress_returnsToNilOnSuccess() async throws {
        let service = InferenceService()
        let backend = ProgressReportingBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let task = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()
        await backend.fireProgress(0.5)
        try await waitForProgress(0.5, on: service)

        await backend.releaseLoadSuccess()
        try await task.value

        XCTAssertTrue(service.isModelLoaded)
        XCTAssertNil(service.modelLoadProgress,
                     "modelLoadProgress should be cleared once isModelLoaded flips true")
    }

    func test_modelLoadProgress_returnsToNilOnFailure() async throws {
        let service = InferenceService()
        let backend = ProgressReportingBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let task = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()
        await backend.fireProgress(0.4)
        try await waitForProgress(0.4, on: service)

        await backend.releaseLoadFailure(ProgressTestError.plannedFailure)
        do {
            try await task.value
            XCTFail("Expected planned failure")
        } catch ProgressTestError.plannedFailure {
            // expected
        }

        XCTAssertFalse(service.isModelLoaded)
        XCTAssertNil(service.modelLoadProgress,
                     "modelLoadProgress should be cleared after a non-stale load failure")
    }

    // MARK: - Stale-request suppression

    func test_modelLoadProgress_staleRequestUpdatesAreDropped() async throws {
        let service = InferenceService()
        let firstBackend = ProgressReportingBackend()
        let secondBackend = ProgressReportingBackend()

        service.registerBackendFactory { type in
            switch type {
            case .gguf: firstBackend
            case .foundation: secondBackend
            case .mlx: nil
            }
        }

        // Start first load and let it report some progress.
        let firstTask = Task {
            try await service.loadModel(from: makeModelInfo(name: "First", modelType: .gguf), plan: .testStub())
        }
        await firstBackend.waitUntilLoadStarted()
        await firstBackend.fireProgress(0.3)
        try await waitForProgress(0.3, on: service)

        // Start a second load that supersedes the first.
        let secondTask = Task {
            try await service.loadModel(from: makeModelInfo(name: "Second", modelType: .foundation), plan: .testStub())
        }
        await secondBackend.waitUntilLoadStarted()

        // Second load is now active — progress should be 0.0 again.
        XCTAssertEqual(service.modelLoadProgress, 0.0,
                       "Newer load should reset modelLoadProgress to 0.0")

        // First backend keeps firing — these MUST NOT touch modelLoadProgress.
        await firstBackend.fireProgress(0.9)
        await firstBackend.fireProgress(0.95)
        // Give the late hops a chance to drain the cooperative queue.
        await Task.yield()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(service.modelLoadProgress, 0.0,
                       "Stale progress from a superseded load must be ignored")

        // Newer load completes normally.
        await secondBackend.fireProgress(0.6)
        try await waitForProgress(0.6, on: service)
        await secondBackend.releaseLoadSuccess()
        try await secondTask.value

        XCTAssertNil(service.modelLoadProgress)

        // Drain the first task to avoid leaks. It will complete as a stale success
        // and be unloaded by the service.
        await firstBackend.releaseLoadSuccess()
        _ = try? await firstTask.value
    }

    // MARK: - Clamping

    func test_modelLoadProgress_clampsToValidRange() async throws {
        let service = InferenceService()
        let backend = ProgressReportingBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let task = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()

        await backend.fireProgress(-0.5)
        try await waitForProgress(0.0, on: service)

        await backend.fireProgress(2.0)
        try await waitForProgress(1.0, on: service)

        await backend.fireProgress(0.5)
        try await waitForProgress(0.5, on: service)

        await backend.releaseLoadSuccess()
        try await task.value
    }

    // MARK: - Handler teardown (leak check)

    func test_setLoadProgressHandler_clearedAfterSuccessfulLoad() async throws {
        let service = InferenceService()
        let backend = ProgressReportingBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let task = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()
        XCTAssertEqual(backend.handlerInstallCount, 1, "Service should install a handler at load start")
        XCTAssertFalse(backend.hasNilHandler, "Handler should be non-nil during load")

        await backend.releaseLoadSuccess()
        try await task.value

        XCTAssertTrue(backend.hasNilHandler,
                      "Service must clear the handler after a successful load to prevent retain leaks")
    }

    func test_setLoadProgressHandler_clearedAfterFailedLoad() async throws {
        let service = InferenceService()
        let backend = ProgressReportingBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let task = Task { try await service.loadModel(from: makeModelInfo(), plan: .testStub()) }
        await backend.waitUntilLoadStarted()
        await backend.releaseLoadFailure(ProgressTestError.plannedFailure)
        _ = try? await task.value

        XCTAssertTrue(backend.hasNilHandler,
                      "Service must clear the handler after a failed load to prevent retain leaks")
    }

    // MARK: - Cloud backend path

    func test_modelLoadProgress_cloudLoadAlsoPublishesProgress() async throws {
        let service = InferenceService()
        let backend = ProgressReportingCloudBackend()
        service.registerCloudBackendFactory { provider in
            provider == .ollama ? backend : nil
        }

        let endpoint = APIEndpointRecord(name: "Test", provider: .ollama, modelName: "demo")
        let task = Task { try await service.loadCloudBackend(from: endpoint) }
        await backend.waitUntilLoadStarted()

        XCTAssertEqual(service.modelLoadProgress, 0.0)
        await backend.fireProgress(0.5)
        try await waitForProgress(0.5, on: service)

        await backend.releaseLoadSuccess()
        try await task.value
        XCTAssertNil(service.modelLoadProgress)
        XCTAssertTrue(backend.hasNilHandler)
    }

    // MARK: - Helpers

    private func makeModelInfo(name: String = "Test", modelType: ModelType = .gguf) -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).bin",
            url: URL(fileURLWithPath: "/\(name).bin"),
            fileSize: 0,
            modelType: modelType
        )
    }

    /// Polls `service.modelLoadProgress` until it equals `expected` or times out.
    private func waitForProgress(
        _ expected: Double?,
        on service: InferenceService,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if service.modelLoadProgress == expected {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for modelLoadProgress to become \(String(describing: expected)) — current: \(String(describing: service.modelLoadProgress))")
    }
}

// MARK: - Test backends

private enum ProgressTestError: Error, Sendable {
    case plannedFailure
}

private actor ProgressGate {
    enum Release: Sendable {
        case success
        case failure(any Error & Sendable)
    }

    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseDecision: Release?
    private var releaseWaiters: [CheckedContinuation<Release, Never>] = []

    func markStarted() {
        didStart = true
        for w in startWaiters { w.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async -> Release {
        if let releaseDecision { return releaseDecision }
        return await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func releaseSuccess() { release(.success) }
    func releaseFailure(_ error: any Error & Sendable) { release(.failure(error)) }

    private func release(_ decision: Release) {
        guard releaseDecision == nil else { return }
        releaseDecision = decision
        for w in releaseWaiters { w.resume(returning: decision) }
        releaseWaiters.removeAll()
    }
}

/// Test backend that conforms to `LoadProgressReporting` and exposes a manually
/// fireable progress hook plus a gate to control when `loadModel` returns.
private final class ProgressReportingBackend: InferenceBackend,
                                              LoadProgressReporting,
                                              @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private let lock = NSLock()
    private var handler: (@Sendable (Double) async -> Void)?
    private var _handlerInstallCount = 0
    private var _hasNilHandler = true

    var handlerInstallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _handlerInstallCount
    }

    var hasNilHandler: Bool {
        lock.lock(); defer { lock.unlock() }
        return _hasNilHandler
    }

    private let gate = ProgressGate()

    func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?) {
        lock.lock()
        self.handler = handler
        _hasNilHandler = (handler == nil)
        if handler != nil {
            _handlerInstallCount += 1
        }
        lock.unlock()
    }

    func fireProgress(_ value: Double) async {
        let h = lock.withLock { handler }
        await h?(value)
    }

    func waitUntilLoadStarted() async { await gate.waitUntilStarted() }
    func releaseLoadSuccess() async { await gate.releaseSuccess() }
    func releaseLoadFailure(_ error: any Error & Sendable) async { await gate.releaseFailure(error) }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        await gate.markStarted()
        switch await gate.waitForRelease() {
        case .success:
            isModelLoaded = true
        case .failure(let error):
            throw error
        }
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}

/// Cloud variant of `ProgressReportingBackend` that conforms to the
/// URL+model configurable protocol so `loadCloudBackend(from:)` accepts it.
private final class ProgressReportingCloudBackend: InferenceBackend,
                                                   LoadProgressReporting,
                                                   CloudBackendURLModelConfigurable,
                                                   @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    private let lock = NSLock()
    private var handler: (@Sendable (Double) async -> Void)?
    private var _hasNilHandler = true

    var hasNilHandler: Bool {
        lock.lock(); defer { lock.unlock() }
        return _hasNilHandler
    }

    private let gate = ProgressGate()

    func configure(baseURL: URL, modelName: String) {}

    func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?) {
        lock.lock()
        self.handler = handler
        _hasNilHandler = (handler == nil)
        lock.unlock()
    }

    func fireProgress(_ value: Double) async {
        let h = lock.withLock { handler }
        await h?(value)
    }

    func waitUntilLoadStarted() async { await gate.waitUntilStarted() }
    func releaseLoadSuccess() async { await gate.releaseSuccess() }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        await gate.markStarted()
        switch await gate.waitForRelease() {
        case .success:
            isModelLoaded = true
        case .failure(let error):
            throw error
        }
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { $0.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }
}
