@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference

@MainActor
final class LoadDispatchCoordinationTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024
    private let criticalMemoryMessage = "Memory pressure is critical. The model was unloaded to prevent the app from being terminated."

    private func makeViewModel(
        handler: MemoryPressureHandler = MemoryPressureHandler(),
        configureService: (InferenceService) -> Void
    ) -> ChatViewModel {
        let service = InferenceService()
        configureService(service)
        return ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: handler
        )
    }

    private func makeModel(
        fileName: String,
        modelType: ModelType,
        detectedPromptTemplate: PromptTemplate? = nil
    ) -> ModelInfo {
        ModelInfo(
            name: fileName,
            fileName: fileName,
            url: URL(fileURLWithPath: "/virtual/\(fileName)"),
            fileSize: 1_024,
            modelType: modelType,
            detectedPromptTemplate: detectedPromptTemplate
        )
    }

    private func makeEndpoint(name: String, provider: APIProvider, modelName: String) -> APIEndpointRecord {
        APIEndpointRecord(
            name: name,
            provider: provider,
            baseURL: provider.defaultBaseURL,
            modelName: modelName
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if condition() { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            await Task.yield()
            if condition() { return }
        }
        XCTFail("Condition not met before timeout", file: file, line: line)
    }

    func test_dispatchSelectedLoad_rapidModelToggle_resolvesLatestSelectionAndBackend() async {
        let firstBackend = ControlledLoadBackend()
        let secondBackend = ControlledLoadBackend()
        let vm = makeViewModel { service in
            service.registerBackendFactory { modelType in
                switch modelType {
                case .gguf:
                    firstBackend
                case .foundation:
                    secondBackend
                case .mlx:
                    nil
                }
            }
        }

        let firstModel = makeModel(fileName: "first.gguf", modelType: .gguf, detectedPromptTemplate: .llama3)
        let secondModel = makeModel(fileName: "second.foundation", modelType: .foundation)

        vm.selectedModel = firstModel
        vm.dispatchSelectedLoad()
        await firstBackend.waitUntilLoadStarted()

        vm.selectedModel = secondModel
        vm.dispatchSelectedLoad()
        await secondBackend.waitUntilLoadStarted()

        await secondBackend.releaseLoadSuccess()
        await waitUntil {
            vm.isModelLoaded
            && vm.activeBackendName == BackendName.foundation.rawValue
            && vm.activityPhase == .idle
        }

        await firstBackend.releaseLoadSuccess()
        await waitUntil { firstBackend.unloadCallCount == 1 }

        XCTAssertEqual(vm.selectedModel?.id, secondModel.id)
        XCTAssertTrue(vm.isModelLoaded)
        XCTAssertEqual(vm.activeBackendName, BackendName.foundation.rawValue)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertEqual(secondBackend.unloadCallCount, 0)
    }

    func test_dispatchSelectedLoad_rapidEndpointToggle_resolvesLatestSelectionAndBackend() async {
        let firstBackend = ControlledLoadBackend()
        let secondBackend = ControlledLoadBackend()
        let vm = makeViewModel { service in
            service.registerCloudBackendFactory { provider in
                switch provider {
                case .ollama:
                    firstBackend
                case .lmStudio:
                    secondBackend
                default:
                    nil
                }
            }
        }

        let firstEndpoint = makeEndpoint(name: "First Endpoint", provider: .ollama, modelName: "first")
        let secondEndpoint = makeEndpoint(name: "Second Endpoint", provider: .lmStudio, modelName: "second")

        vm.selectedEndpoint = firstEndpoint
        vm.dispatchSelectedLoad()
        await firstBackend.waitUntilLoadStarted()

        vm.selectedEndpoint = secondEndpoint
        vm.dispatchSelectedLoad()
        await secondBackend.waitUntilLoadStarted()

        await secondBackend.releaseLoadSuccess()
        await waitUntil {
            vm.isModelLoaded
            && vm.activeBackendName == APIProvider.lmStudio.rawValue
            && vm.activityPhase == .idle
        }

        await firstBackend.releaseLoadSuccess()
        await waitUntil { firstBackend.unloadCallCount == 1 }

        XCTAssertEqual(vm.selectedEndpoint?.id, secondEndpoint.id)
        XCTAssertTrue(vm.isModelLoaded)
        XCTAssertEqual(vm.activeBackendName, APIProvider.lmStudio.rawValue)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertEqual(secondBackend.unloadCallCount, 0)
    }

    func test_dispatchSelectedLoad_staleCompletionSuppressesErrorAndActivitySideEffects() async {
        let firstBackend = ControlledLoadBackend()
        let secondBackend = ControlledLoadBackend()
        let vm = makeViewModel { service in
            service.registerBackendFactory { modelType in
                switch modelType {
                case .gguf:
                    firstBackend
                case .foundation:
                    secondBackend
                case .mlx:
                    nil
                }
            }
        }

        let failingModel = makeModel(fileName: "failing.gguf", modelType: .gguf)
        let succeedingModel = makeModel(fileName: "succeeding.foundation", modelType: .foundation)

        vm.selectedModel = failingModel
        vm.dispatchSelectedLoad()
        await firstBackend.waitUntilLoadStarted()

        vm.selectedModel = succeedingModel
        vm.dispatchSelectedLoad()
        await secondBackend.waitUntilLoadStarted()

        await secondBackend.releaseLoadSuccess()
        await waitUntil { vm.isModelLoaded && vm.activeBackendName == BackendName.foundation.rawValue }

        await firstBackend.releaseLoadFailure(ControlledLoadTestError.plannedFailure)
        // Wait for the stale failure's cleanup task to run — the losing backend must
        // be unloaded even though its failure is suppressed from UI state.
        await waitUntil { firstBackend.unloadCallCount == 1 }

        XCTAssertTrue(vm.isModelLoaded, "Stale failure must not unload the newer successful backend")
        XCTAssertEqual(vm.activeBackendName, BackendName.foundation.rawValue)
        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertNil(vm.errorMessage, "Stale failure must not surface an error")
        XCTAssertEqual(firstBackend.unloadCallCount, 1)
    }

    func test_handleMemoryPressureCritical_preemptsPendingLoadAndSuppressesLateCompletion() async {
        let handler = MemoryPressureHandler()
        let backend = ControlledLoadBackend()
        let vm = await makeViewModel(handler: handler) { service in
            service.registerBackendFactory { modelType in
                guard modelType == .gguf else { return nil }
                return backend
            }
        }

        let model = makeModel(fileName: "inflight.gguf", modelType: .gguf)
        vm.selectedModel = model
        vm.dispatchSelectedLoad()
        await backend.waitUntilLoadStarted()
        await waitUntil { vm.isLoading }

        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        XCTAssertFalse(vm.isModelLoaded)
        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertEqual(vm.errorMessage, criticalMemoryMessage)

        await backend.releaseLoadSuccess()
        await waitUntil { backend.unloadCallCount == 1 }

        XCTAssertFalse(vm.isModelLoaded)
        XCTAssertEqual(vm.activityPhase, .idle)
        XCTAssertEqual(vm.errorMessage, criticalMemoryMessage)
    }
}

private enum ControlledLoadTestError: Error, Sendable {
    case plannedFailure
}

private actor ControlledLoadGate {
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
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if didStart {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async -> Release {
        if let releaseDecision {
            return releaseDecision
        }

        return await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseSuccess() {
        release(.success)
    }

    func releaseFailure(_ error: any Error & Sendable) {
        release(.failure(error))
    }

    private func release(_ decision: Release) {
        guard releaseDecision == nil else { return }
        releaseDecision = decision
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: decision)
        }
    }
}

private final class ControlledLoadBackend: InferenceBackend,
                                           CloudBackendURLModelConfigurable,
                                           @unchecked Sendable {
    private let stateLock = NSLock()
    private let gate = ControlledLoadGate()

    private var _isModelLoaded = false
    private var _isGenerating = false
    private var _unloadCallCount = 0

    var isModelLoaded: Bool {
        get { withLock { _isModelLoaded } }
        set { withLock { _isModelLoaded = newValue } }
    }

    var isGenerating: Bool {
        get { withLock { _isGenerating } }
        set { withLock { _isGenerating = newValue } }
    }

    var unloadCallCount: Int {
        withLock { _unloadCallCount }
    }

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func configure(baseURL: URL, modelName: String) {}

    func waitUntilLoadStarted() async {
        await gate.waitUntilStarted()
    }

    func releaseLoadSuccess() async {
        await gate.releaseSuccess()
    }

    func releaseLoadFailure(_ error: any Error & Sendable) async {
        await gate.releaseFailure(error)
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        await gate.markStarted()

        switch await gate.waitForRelease() {
        case .success:
            isModelLoaded = true
        case .failure(let error):
            throw error
        }
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard isModelLoaded else {
            throw InferenceError.inferenceFailure("No model loaded")
        }
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {
        isGenerating = false
    }

    func unloadModel() {
        withLock {
            _unloadCallCount += 1
            _isModelLoaded = false
            _isGenerating = false
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
