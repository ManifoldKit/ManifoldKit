@preconcurrency import XCTest
@testable import ManifoldUI
@testable import ManifoldInference

private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

/// Stage 2 wiring tests: the UI entry point now routes through `ModelLoadPlan`
/// instead of `DeviceCapabilityService.canLoadModel`. These assert the behaviour
/// the plan's verdict must produce end-to-end from `loadSelectedModel()`.
@MainActor
final class ChatViewModelLoadPlanWiringTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a view model with a registered recording backend for the given
    /// model type. `physicalMemory` is deliberately decoupled from the plan
    /// environment: if legacy code paths are reached, `canLoadModel` will
    /// evaluate against it, letting us detect regressions.
    private func makeViewModel(
        modelType: ModelType = .gguf,
        physicalMemory: UInt64,
        planEnvironment: ModelLoadPlan.Environment
    ) -> (ChatViewModel, RecordingBackend) {
        let backend = RecordingBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in
            type == modelType ? backend : nil
        }
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: physicalMemory),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.loadPlanEnvironment = planEnvironment
        return (vm, backend)
    }

    private func makeLocalModel(
        modelType: ModelType = .gguf,
        fileSize: UInt64 = 1_024,
        detectedContextLength: Int? = 4_096,
        estimatedKVBytesPerToken: UInt64? = 2_048
    ) -> ModelInfo {
        ModelInfo(
            name: "Test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/virtual/test.gguf"),
            fileSize: fileSize,
            modelType: modelType,
            detectedContextLength: detectedContextLength,
            estimatedKVBytesPerToken: estimatedKVBytesPerToken
        )
    }

    // MARK: - Tests

    /// The legacy `canLoadModel` guard returned `false` for a model larger than
    /// `physicalMemory * 0.70 / 1.20`. If the UI still consulted it, a 10 GB
    /// model on a 1 GB device would refuse to load. The new plan uses
    /// `availableMemoryBytes` from the injected environment — we set that to
    /// plenty, so the load must proceed, proving `canLoadModel` is bypassed.
    func test_loadLocalModel_doesNotInvokeDeviceCapabilityServiceCanLoadModel() async {
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { 32 * oneGB },
            physicalMemoryBytes: 32 * oneGB
        )
        let (vm, backend) = await makeViewModel(
            physicalMemory: 1 * oneGB,  // tiny — canLoadModel would reject
            planEnvironment: env
        )
        let model = makeLocalModel(fileSize: 10 * oneGB)  // 10x physical RAM
        vm.availableModels = [model]
        vm.selectedModel = model

        await vm.loadSelectedModel()

        XCTAssertEqual(backend.loadCallCount, 1, "Plan must allow despite tiny physicalMemory")
        XCTAssertNil(vm.errorMessage)
    }

    /// With an environment that reports almost no available memory, the plan
    /// produces `.deny` with an `.insufficientResident` or `.insufficientKVCache`
    /// reason. The UI must surface that reason's text instead of the legacy
    /// RAM-in-GB message.
    func test_loadLocalModel_denyVerdict_surfacesReasonInErrorMessage() async {
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { 128 * 1024 * 1024 },  // 128 MB available
            physicalMemoryBytes: 8 * oneGB
        )
        let (vm, backend) = await makeViewModel(
            physicalMemory: 8 * oneGB,
            planEnvironment: env
        )
        // Model weights alone (2 GB) vastly exceed available memory.
        let model = makeLocalModel(fileSize: 2 * oneGB)
        vm.availableModels = [model]
        vm.selectedModel = model

        await vm.loadSelectedModel()

        XCTAssertEqual(backend.loadCallCount, 0, "Denied load must not reach backend")
        let message = vm.errorMessage ?? ""
        let hasReasonText = message.contains("too large for available memory")
            || message.contains("context window")
        XCTAssertTrue(
            hasReasonText,
            "Expected plan-derived reason text in error message, got: \(message)"
        )
    }

    /// Happy path: plan allows, backend is invoked, and the `contextSize` passed
    /// to the backend equals `Int32(plan.effectiveContextSize)`. Using a
    /// tight-but-allowed environment keeps the effective context below the
    /// requested context, which lets us diff against a naive passthrough.
    func test_loadLocalModel_allowVerdict_proceedsToInferenceService() async {
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { 32 * oneGB },
            physicalMemoryBytes: 32 * oneGB
        )
        let (vm, backend) = await makeViewModel(
            physicalMemory: 32 * oneGB,
            planEnvironment: env
        )
        let model = makeLocalModel(
            fileSize: 1 * oneGB,
            detectedContextLength: 8_192,
            estimatedKVBytesPerToken: 2_048
        )
        vm.availableModels = [model]
        vm.selectedModel = model

        let expectedPlan = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 8_192,
            strategy: .mappable,
            environment: env
        )

        await vm.loadSelectedModel()

        XCTAssertEqual(backend.loadCallCount, 1)
        XCTAssertEqual(backend.lastContextSize, Int32(expectedPlan.effectiveContextSize))
        XCTAssertNil(vm.errorMessage)
    }

    /// Foundation models are system-managed and must bypass the memory math.
    /// Even if the plan environment reports near-zero memory, a Foundation
    /// load must still dispatch with `effectiveContextSize == requested`.
    func test_loadLocalModel_foundationModelType_usesSystemManagedPlan() async {
        let env = ModelLoadPlan.Environment(
            availableMemoryBytes: { 1 },  // hostile: 1 byte available
            physicalMemoryBytes: 1
        )
        let (vm, backend) = await makeViewModel(
            modelType: .foundation,
            physicalMemory: 1,
            planEnvironment: env
        )
        let model = ModelInfo.builtInFoundation
        vm.availableModels = [model]
        vm.selectedModel = model

        // Foundation's detectedContextLength is nil -> requested == 8192.
        let expectedPlan = ModelLoadPlan.systemManaged(requestedContextSize: 8_192)
        XCTAssertEqual(expectedPlan.verdict, .allow)
        XCTAssertEqual(expectedPlan.effectiveContextSize, 8_192)

        await vm.loadSelectedModel()

        XCTAssertEqual(backend.loadCallCount, 1)
        XCTAssertEqual(backend.lastContextSize, 8_192)
        XCTAssertNil(vm.errorMessage)
    }
}

// MARK: - Recording Backend

/// Captures the arguments of each `loadModel` call so tests can assert on the
/// context size the UI forwarded to the backend.
private final class RecordingBackend: InferenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _loadCallCount = 0
    private var _lastURL: URL?
    private var _lastContextSize: Int32?
    private var _isModelLoaded = false

    var loadCallCount: Int { withLock { _loadCallCount } }
    var lastURL: URL? { withLock { _lastURL } }
    var lastContextSize: Int32? { withLock { _lastContextSize } }

    var isModelLoaded: Bool {
        get { withLock { _isModelLoaded } }
        set { withLock { _isModelLoaded = newValue } }
    }
    var isGenerating: Bool = false

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 8_192,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        withLock {
            _loadCallCount += 1
            _lastURL = url
            _lastContextSize = Int32(plan.effectiveContextSize)
            _isModelLoaded = true
        }
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() { isModelLoaded = false }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
