import XCTest
@testable import ManifoldInference

/// Tests for the multi-observer headless load-status surface on the
/// service-vended `ModelLoadCoordinator`.
///
/// The decision under test: `InferenceService` vends a single coordinator, and
/// multiple observers (simulating `ChatViewModel` AND a headless `ModelSelection`
/// façade) watch the SAME load via independent `statusUpdates()` streams without
/// cross-contaminating each other.
@MainActor
final class ModelLoadCoordinatorStatusTests: XCTestCase {

    // MARK: - One coordinator per service

    func test_modelLoadCoordinator_isSameInstanceAcrossAccesses() {
        let service = InferenceService()
        let a = service.modelLoadCoordinator
        let b = service.modelLoadCoordinator
        XCTAssertTrue(a === b, "InferenceService must vend a single shared coordinator")
    }

    // MARK: - Multi-observer fan-out

    func test_twoObservers_seeSameLoadStatus_withoutCrossContamination() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let coordinator = service.modelLoadCoordinator
        coordinator.currentActivityPhase = { .modelLoading(progress: nil) }
        // Accept the phase transitions the coordinator drives so its internal
        // `.modelLoading` gate stays satisfied for the progress bridge.
        coordinator.onTransitionPhase = { _ in true }

        // Two independent observers, as a chat VM and a headless façade would be.
        let chatObserver = StatusCollector(coordinator.statusUpdates())
        let headlessObserver = StatusCollector(coordinator.statusUpdates())

        // Both must immediately receive the current status (.idle) so a late
        // subscriber is never stuck on nothing.
        try await chatObserver.waitForLatest(.idle)
        try await headlessObserver.waitForLatest(.idle)

        let loadTask = Task { await coordinator.loadLocalModel(makeModel(), generation: nil) }
        await backend.waitUntilLoadStarted()

        // Both observers see the SAME loading transition.
        try await chatObserver.waitForLatest(.loading(progress: 0.0))
        try await headlessObserver.waitForLatest(.loading(progress: 0.0))

        await backend.releaseLoadSuccess()
        await loadTask.value

        // Both observers see the terminal loaded status — neither clobbered the other.
        try await chatObserver.waitForLatest(.loaded)
        try await headlessObserver.waitForLatest(.loaded)

        chatObserver.finish()
        headlessObserver.finish()
    }

    func test_oneObserverCancelling_doesNotStarveTheOther() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let coordinator = service.modelLoadCoordinator
        coordinator.currentActivityPhase = { .modelLoading(progress: nil) }
        coordinator.onTransitionPhase = { _ in true }

        let survivor = StatusCollector(coordinator.statusUpdates())
        try await survivor.waitForLatest(.idle)

        // A second observer subscribes then immediately tears down its stream.
        do {
            let transient = StatusCollector(coordinator.statusUpdates())
            transient.finish()
        }
        // Let the transient observer's onTermination cleanup hop back to the actor.
        await Task.yield()

        let loadTask = Task { await coordinator.loadLocalModel(makeModel(), generation: nil) }
        await backend.waitUntilLoadStarted()
        try await survivor.waitForLatest(.loading(progress: 0.0))

        await backend.releaseLoadSuccess()
        await loadTask.value
        try await survivor.waitForLatest(.loaded)

        survivor.finish()
    }

    func test_failedLoad_publishesFailureToAllObservers() async throws {
        let service = InferenceService()
        let backend = GatedLoadBackend()
        service.registerBackendFactory { type in type == .gguf ? backend : nil }

        let coordinator = service.modelLoadCoordinator
        coordinator.currentActivityPhase = { .modelLoading(progress: nil) }
        coordinator.onTransitionPhase = { _ in true }

        let a = StatusCollector(coordinator.statusUpdates())
        let b = StatusCollector(coordinator.statusUpdates())
        try await a.waitForLatest(.idle)
        try await b.waitForLatest(.idle)

        let loadTask = Task { await coordinator.loadLocalModel(makeModel(), generation: nil) }
        await backend.waitUntilLoadStarted()
        await backend.releaseLoadFailure(StatusTestError.planned)
        await loadTask.value

        try await a.waitForFailure()
        try await b.waitForFailure()

        a.finish()
        b.finish()
    }

    // MARK: - Fixtures

    private func makeModel(name: String = "Gated") -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).Q4_K_M.gguf",
            url: URL(fileURLWithPath: "/virtual/\(name).gguf"),
            fileSize: 1_024,
            modelType: .gguf
        )
    }
}

// MARK: - Status collector

/// Drains a `statusUpdates()` stream into an array, with a tight-deadline poll
/// helper so tests assert on the *latest* delivered status deterministically.
@MainActor
private final class StatusCollector {
    private(set) var received: [ModelLoadStatus] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<ModelLoadStatus>) {
        task = Task { @MainActor in
            for await status in stream {
                received.append(status)
            }
        }
    }

    func finish() {
        task?.cancel()
        task = nil
    }

    func waitForLatest(
        _ expected: ModelLoadStatus,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if received.last == expected { return }
            await Task.yield()
        }
        XCTFail("Did not observe \(expected); saw \(received)", file: file, line: line)
    }

    func waitForFailure(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if case .failed = received.last { return }
            await Task.yield()
        }
        XCTFail("Did not observe a .failed status; saw \(received)", file: file, line: line)
    }
}

// MARK: - Gated backend

private enum StatusTestError: Error, Sendable { case planned }

/// A backend that blocks inside `loadModel` until the test releases it, so the
/// coordinator's load-status transitions can be observed mid-flight.
private final class GatedLoadBackend: InferenceBackend, @unchecked Sendable {
    private let gate = GateBox()

    var isModelLoaded = false
    var isGenerating = false

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func waitUntilLoadStarted() async { await gate.waitUntilStarted() }
    func releaseLoadSuccess() async { await gate.releaseSuccess() }
    func releaseLoadFailure(_ error: any Error & Sendable) async { await gate.releaseFailure(error) }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        await gate.markStarted()
        switch await gate.waitForRelease() {
        case .success: isModelLoaded = true
        case .failure(let error): throw error
        }
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        GenerationStream(AsyncThrowingStream { $0.finish() })
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }
}

/// A small async gate: the loader signals "started", the test releases it.
private actor GateBox {
    enum Release { case success, failure(any Error & Sendable) }

    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: Release?
    private var releaseWaiters: [CheckedContinuation<Release, Never>] = []

    func markStarted() {
        started = true
        for w in startedWaiters { w.resume() }
        startedWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitForRelease() async -> Release {
        if let release { return release }
        return await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func releaseSuccess() { deliver(.success) }
    func releaseFailure(_ error: any Error & Sendable) { deliver(.failure(error)) }

    private func deliver(_ r: Release) {
        release = r
        for w in releaseWaiters { w.resume(returning: r) }
        releaseWaiters.removeAll()
    }
}
