@preconcurrency import XCTest
@testable import ManifoldUI
import ManifoldRuntime
@testable import ManifoldInference
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI

/// Characterization tests for PR 2 (headless `ModelSelection` + the #1312
/// synchronous dual-write collapse). These exercise the two-surface topology and
/// the synchronous endpoint-clear ordering that the pre-existing
/// `LoadDispatchCoordinationTests` / `InterleavingTests` (which all drive through
/// `ChatViewModel.selectedModel =`) give zero coverage of.
@MainActor
final class HeadlessModelSelectionTopologyTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeModel(_ name: String, _ type: ModelType) -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: name,
            url: URL(fileURLWithPath: "/virtual/\(name)"),
            fileSize: type == .foundation ? 0 : 1_024,
            modelType: type
        )
    }

    private func makeEndpoint(_ name: String, _ provider: APIProvider) -> APIEndpointRecord {
        APIEndpointRecord(
            name: name,
            provider: provider,
            baseURL: provider.defaultBaseURL,
            modelName: "m"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
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

    // MARK: - Two-surface topology (Correction E)

    /// A headless `ModelSelection` and a `ChatViewModel` over ONE shared
    /// `InferenceService`: a headless load must NOT leak progress/phase into the
    /// chat surface. The chat view model's `activityPhase` stays `.idle` because
    /// it never installed the load's chat-side seams for *this* dispatch — the
    /// shared coordinator's chat callbacks belong to the chat VM's own loads, and
    /// the headless surface observes only via its own `statusUpdates()` stream.
    func test_headlessLoad_doesNotLeakIntoChatSurfacePhase() async throws {
        let backend = SlowGatedBackend()
        let service = InferenceService()
        service.registerBackendFactory { $0 == .gguf ? backend : nil }

        let chatVM = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )

        let selection = ModelSelection(
            registry: ModelRegistry(inferenceService: service, modelStorage: ModelStorageService()),
            coordinator: service.modelLoadCoordinator,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB)
        )
        let model = makeModel("headless.gguf", .gguf)
        selection.registry.availableModels = [model]

        // Snapshot the chat surface BEFORE the headless load — it has no selection
        // and must remain idle throughout the headless load.
        XCTAssertNil(chatVM.selectedModel)
        XCTAssertEqual(chatVM.activityPhase, .idle)

        // Observe the headless surface's own status stream.
        var sawHeadlessLoading = false
        let observer = Task { @MainActor in
            for await status in selection.loadStatusUpdates() {
                if case .loading = status { sawHeadlessLoading = true }
                if case .loaded = status { return }
            }
        }

        selection.select(model)
        selection.loadSelected()
        await backend.waitUntilStarted()

        // While the headless load is in flight, the chat surface must not have been
        // dragged into a loading phase — it owns no selection and dispatched nothing.
        XCTAssertEqual(chatVM.activityPhase, .idle, "Headless load leaked into the chat phase")
        XCTAssertNil(chatVM.selectedModel)

        await backend.releaseSuccess()
        await waitUntil { service.isModelLoaded }
        observer.cancel()

        XCTAssertTrue(sawHeadlessLoading, "Headless surface should see its own load via statusUpdates()")
        XCTAssertEqual(chatVM.activityPhase, .idle)
    }

    /// The REVERSE interleaving of the no-leak case: a headless load that
    /// SUPERSEDES an in-flight chat-driving load must not leave the chat surface
    /// stuck on a `.modelLoading` spinner. The cancelled chat load can't flip its
    /// own phase back, and the incoming headless load won't touch it
    /// (`drivesChatSeams == false`) — so `dispatchLoad` resets the orphaned phase
    /// to `.idle` (#1312 Correction E).
    func test_headlessLoadSupersedingChatLoad_resetsOrphanedChatPhase() async {
        let backend = SlowGatedBackend()
        let service = InferenceService()
        service.registerBackendFactory { $0 == .gguf ? backend : nil }

        let chatVM = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        let chatModel = makeModel("chat.gguf", .gguf)
        chatVM.modelRegistry.availableModels = [chatModel]

        // Chat load goes in-flight → chat surface enters `.modelLoading`.
        chatVM.modelRegistry.selectModel(chatModel)
        chatVM.dispatchSelectedLoad()
        await backend.waitUntilStarted()
        await waitUntil {
            if case .modelLoading = chatVM.activityPhase { return true }
            return false
        }

        // A headless load over the SAME shared coordinator supersedes the chat load.
        let selection = ModelSelection(
            registry: ModelRegistry(inferenceService: service, modelStorage: ModelStorageService()),
            coordinator: service.modelLoadCoordinator,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB)
        )
        let headlessModel = makeModel("headless.gguf", .gguf)
        selection.registry.availableModels = [headlessModel]
        selection.select(headlessModel)
        selection.loadSelected()

        // The orphaned chat phase must have been reset synchronously by dispatchLoad.
        XCTAssertEqual(chatVM.activityPhase, .idle,
                       "Superseded chat load left the chat surface stuck on a spinner")

        await backend.releaseSuccess()
    }

    // MARK: - Synchronous endpoint-clear (Correction F)

    /// Selecting a local model via `ModelRegistry.selectModel` clears
    /// `selectedEndpoint` SYNCHRONOUSLY — before `dispatchSelectedLoad` reads
    /// `currentLoadIntent`. So the load that fires is the local model's, not the
    /// stale endpoint's. We prove this by routing the local model selection
    /// through the registry (the path the old async observer handled) and then
    /// dispatching: the LOCAL backend must start, never the endpoint backend.
    func test_selectingLocalModelViaRegistry_clearsEndpointSynchronously_beforeDispatch() async {
        let localBackend = SlowGatedBackend()
        let endpointBackend = SlowGatedBackend()
        let service = InferenceService()
        service.registerBackendFactory { $0 == .gguf ? localBackend : nil }
        service.registerEndpointBackendFactory { $0 == .ollama ? endpointBackend : nil }

        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )

        let model = makeModel("local.gguf", .gguf)
        vm.modelRegistry.availableModels = [model]
        vm.selectedEndpoint = makeEndpoint("Ollama", .ollama)
        XCTAssertNotNil(vm.selectedEndpoint)

        // Select the local model directly on the registry — NOT via vm.selectedModel.
        // The synchronous onSelectionChanged hook must clear the endpoint here.
        vm.modelRegistry.selectModel(model)

        // Synchronous assertion: the endpoint is already gone, no Task hop needed.
        XCTAssertNil(vm.selectedEndpoint, "Endpoint must be cleared synchronously inside selectModel")
        XCTAssertEqual(vm.selectedModel?.id, model.id)

        // Dispatch reads currentLoadIntent now — it must resolve to the model.
        vm.dispatchSelectedLoad()
        await localBackend.waitUntilStarted()
        XCTAssertFalse(endpointBackend.didStart, "Stale endpoint must not have been dispatched")

        await localBackend.releaseSuccess()
        await waitUntil { service.isModelLoaded }
    }

    // MARK: - Public setter still syncs (Correction F migration)

    /// The public `selectedModel` binding setter must still trigger the
    /// endpoint-sync (the migration guarantee for binding-based consumers).
    func test_publicSelectedModelSetter_stillClearsEndpoint() {
        let service = InferenceService()
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.selectedEndpoint = makeEndpoint("Ollama", .ollama)
        XCTAssertNotNil(vm.selectedEndpoint)

        vm.selectedModel = makeModel("via-setter.gguf", .gguf)

        XCTAssertNil(vm.selectedEndpoint, "Binding setter path must still clear the endpoint")
        XCTAssertNotNil(vm.selectedModel)
    }
}

// MARK: - Slow gated backend

private actor SlowGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let w = startWaiters; startWaiters.removeAll()
        for c in w { c.resume() }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        guard !released else { return }
        released = true
        let w = releaseWaiters; releaseWaiters.removeAll()
        for c in w { c.resume() }
    }
    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

private final class SlowGatedBackend: InferenceBackend,
                                      EndpointBackendURLModelConfigurable,
                                      @unchecked Sendable {
    private let lock = NSLock()
    private let gate = SlowGate()
    private var _loaded = false
    private var _didStart = false

    var isModelLoaded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _loaded }
        set { lock.lock(); _loaded = newValue; lock.unlock() }
    }
    var isGenerating: Bool = false
    var didStart: Bool { lock.lock(); defer { lock.unlock() }; return _didStart }

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func configure(baseURL: URL, modelName: String) {}
    func waitUntilStarted() async { await gate.waitUntilStarted() }
    func releaseSuccess() async { await gate.release() }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        markStarted()
        await gate.markStarted()
        await gate.waitForRelease()
        isModelLoaded = true
    }

    private func markStarted() {
        lock.lock(); _didStart = true; lock.unlock()
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        GenerationStream(AsyncThrowingStream { $0.finish() })
    }
    func stopGeneration() {}
    func unloadModel() { lock.lock(); _loaded = false; lock.unlock() }
}
