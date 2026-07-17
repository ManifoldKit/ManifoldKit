@preconcurrency import XCTest
@testable import ManifoldUI
@testable import ManifoldInference
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI

/// Coverage for `ChatViewModel.modelLoadState` and the distinguishable
/// `SendMessageError.modelLoading` case (#2222).
///
/// Before this change a caller had no way to tell "still loading" apart from
/// "silently failed": `isModelLoaded` stayed `false` in both cases,
/// `activeError`/`errorMessage` stayed `nil` while a load was in flight, and
/// `sendMessage(_:)` threw the same bare `.noModelLoaded` either way. These
/// tests drive a controlled (gated) backend so the in-flight window is
/// observable, then assert the new `modelLoadState` transitions and the
/// distinguishable send-during-load error.
@MainActor
final class ModelLoadStateTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeViewModel(backend: GatedLoadBackend) -> ChatViewModel {
        let service = InferenceService()
        service.registerBackendFactory { modelType in
            modelType == .gguf ? backend : nil
        }
        return ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
    }

    private func makeModel(fileName: String = "gated.gguf", fileSize: UInt64 = 1_024) -> ModelInfo {
        ModelInfo(
            name: fileName,
            fileName: fileName,
            url: URL(fileURLWithPath: "/virtual/\(fileName)"),
            fileSize: fileSize,
            modelType: .gguf
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

    // MARK: - modelLoadState transitions

    func test_modelLoadState_idleBeforeAnyLoad() {
        let backend = GatedLoadBackend()
        let vm = makeViewModel(backend: backend)
        guard case .idle = vm.modelLoadState else {
            return XCTFail("Expected .idle before any load, got \(vm.modelLoadState)")
        }
    }

    func test_modelLoadState_loadingWhileInFlight_thenLoadedOnSuccess() async {
        let backend = GatedLoadBackend()
        let vm = makeViewModel(backend: backend)
        vm.selectedModel = makeModel()

        vm.dispatchSelectedLoad()
        await backend.waitUntilLoadStarted()
        await waitUntil { vm.isLoading }

        guard case .loading = vm.modelLoadState else {
            return XCTFail("Expected .loading while the gate is held, got \(vm.modelLoadState)")
        }

        await backend.releaseSuccess()
        await waitUntil { vm.isModelLoaded }

        guard case .loaded = vm.modelLoadState else {
            return XCTFail("Expected .loaded after a successful load, got \(vm.modelLoadState)")
        }
    }

    func test_modelLoadState_failedCarriesTheRealErrorNotAString() async {
        let backend = GatedLoadBackend()
        let vm = makeViewModel(backend: backend)
        vm.selectedModel = makeModel()

        vm.dispatchSelectedLoad()
        await backend.waitUntilLoadStarted()

        await backend.releaseFailure(GatedLoadTestError.plannedFailure)
        await waitUntil {
            if case .failed = vm.modelLoadState { return true }
            return false
        }

        guard case .failed(let error) = vm.modelLoadState else {
            return XCTFail("Expected .failed after a load failure, got \(vm.modelLoadState)")
        }
        XCTAssertEqual(
            error as? GatedLoadTestError,
            .plannedFailure,
            "modelLoadState.failed must carry the ORIGINAL thrown error, not a stringified/erased copy."
        )
    }

    /// The `.deny` load-plan verdict is a separate failure path from the two
    /// tests above: `ModelLoadCoordinator.loadLocalModel` returns on `.deny`
    /// *before* ever calling `backend.loadModel`, so it never reaches the
    /// `catch` block `test_modelLoadState_failedCarriesTheRealErrorNotAString`
    /// exercises. `.deny` synthesizes its own `InferenceError` via
    /// `loadPlanDenyError(for:model:)` (`ModelLoadCoordinator.swift`) — this
    /// asserts that path also lands on `modelLoadState.failed` with a real,
    /// typed error rather than a bare message string.
    func test_modelLoadState_denyVerdict_failedCarriesSynthesizedInferenceError() async {
        let backend = GatedLoadBackend()
        let vm = makeViewModel(backend: backend)
        // Tiny available memory (128 MB) against a 2 GB model forces
        // ModelLoadPlan.compute to return .deny with .insufficientResident —
        // mirrors ChatViewModelLoadPlanWiringTests's deny-verdict recipe.
        vm.loadPlanEnvironment = ModelLoadPlan.Environment(
            availableMemoryBytes: { 128 * 1_024 * 1_024 },
            physicalMemoryBytes: 8 * oneGB
        )
        vm.selectedModel = makeModel(fileName: "huge.gguf", fileSize: 2 * oneGB)

        vm.dispatchSelectedLoad()
        await waitUntil {
            if case .failed = vm.modelLoadState { return true }
            return false
        }

        guard case .failed(let error) = vm.modelLoadState else {
            return XCTFail("Expected .failed after a .deny verdict, got \(vm.modelLoadState)")
        }
        guard case .memoryInsufficient = error as? InferenceError else {
            return XCTFail("Expected a synthesized InferenceError.memoryInsufficient, got \(error)")
        }
        XCTAssertEqual(backend.isModelLoaded, false, "A denied load must never reach the backend.")
    }

    // MARK: - sendMessage(_:) during load

    func test_sendMessageText_duringLoad_throwsDistinguishableModelLoadingError() async throws {
        let backend = GatedLoadBackend()
        let vm = makeViewModel(backend: backend)
        vm.activeSession = ChatSession(title: "Test Session")
        vm.selectedModel = makeModel()

        vm.dispatchSelectedLoad()
        await backend.waitUntilLoadStarted()
        await waitUntil { vm.isLoading }

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected sendMessage(_:) to throw while a load is in flight")
        } catch SendMessageError.modelLoading {
            // Expected — distinguishable from .noModelLoaded.
        } catch {
            XCTFail("Expected SendMessageError.modelLoading, got \(error)")
        }

        await backend.releaseSuccess()
        await waitUntil { vm.isModelLoaded }
    }

    func test_sendMessageText_withNoSelectionAtAll_stillThrowsNoModelLoaded() async throws {
        // Regression guard: the new .modelLoading branch must not swallow the
        // existing "nothing selected, nothing loading" case.
        let backend = GatedLoadBackend()
        let vm = makeViewModel(backend: backend)
        vm.activeSession = ChatSession(title: "Test Session")

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected sendMessage(_:) to throw with no model selected or loaded")
        } catch SendMessageError.noModelLoaded {
            // Expected.
        } catch {
            XCTFail("Expected SendMessageError.noModelLoaded, got \(error)")
        }
    }

    func test_voidSendMessage_duringLoad_surfacesDistinctStillLoadingMessage() async {
        let backend = GatedLoadBackend()
        let vm = makeViewModel(backend: backend)
        vm.activeSession = ChatSession(title: "Test Session")
        vm.selectedModel = makeModel()

        vm.dispatchSelectedLoad()
        await backend.waitUntilLoadStarted()
        await waitUntil { vm.isLoading }

        vm.inputText = "hello"
        await vm.sendMessage()

        XCTAssertEqual(
            vm.activeError?.message,
            "A model is still loading. Wait for it to finish before sending.",
            "A send while a model is loading must surface the distinct still-loading message, not the generic select-a-model text."
        )

        await backend.releaseSuccess()
        await waitUntil { vm.isModelLoaded }
    }
}

// MARK: - Test fixtures

private enum GatedLoadTestError: Error, Equatable {
    case plannedFailure
}

/// Minimal gated backend: `loadModel(from:plan:)` blocks until the test
/// releases it with a success or failure decision. Trimmed variant of the
/// `ControlledLoadBackend`/`ControlledLoadGate` pair in
/// `LoadDispatchCoordinationTests.swift` (kept separate — `private` there is
/// file-scoped, and this file only needs the load-gating behavior, not the
/// endpoint-configurable / unload-counting surface that file also exercises).
private actor GatedLoadSignal {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var decision: Result<Void, Error>?
    private var releaseWaiters: [CheckedContinuation<Result<Void, Error>, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async -> Result<Void, Error> {
        if let decision { return decision }
        return await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release(_ result: Result<Void, Error>) {
        guard decision == nil else { return }
        decision = result
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }
}

private final class GatedLoadBackend: InferenceBackend, @unchecked Sendable {
    private let stateLock = NSLock()
    private let signal = GatedLoadSignal()
    private var _isModelLoaded = false
    private var _isGenerating = false

    var isModelLoaded: Bool {
        get { withLock { _isModelLoaded } }
        set { withLock { _isModelLoaded = newValue } }
    }

    var isGenerating: Bool {
        get { withLock { _isGenerating } }
        set { withLock { _isGenerating = newValue } }
    }

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4_096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func waitUntilLoadStarted() async {
        await signal.waitUntilStarted()
    }

    func releaseSuccess() async {
        await signal.release(.success(()))
    }

    func releaseFailure(_ error: any Error) async {
        await signal.release(.failure(error))
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        await signal.markStarted()
        switch await signal.waitForRelease() {
        case .success:
            isModelLoaded = true
        case .failure(let error):
            throw error
        }
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
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
