import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldTestSupport
@_spi(BackendInternals) import ManifoldHardware

@MainActor
final class ModelSelectionTests: XCTestCase {

    // MARK: - Fixtures

    private var modelsDirectory: URL!
    private var modelStorage: ModelStorageService!
    private var inferenceService: InferenceService!

    override func setUp() async throws {
        try await super.setUp()
        modelsDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("ModelSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        modelStorage = ModelStorageService(baseDirectory: modelsDirectory)
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        inferenceService = InferenceService(backend: mock, name: "Mock")
    }

    override func tearDown() async throws {
        if let modelsDirectory {
            try? FileManager.default.removeItem(at: modelsDirectory)
        }
        modelsDirectory = nil
        modelStorage = nil
        inferenceService = nil
        try await super.tearDown()
    }

    private func makeModel(
        name: String,
        modelType: ModelType,
        fileSize: UInt64 = 2 * 1_024 * 1_024 * 1_024
    ) -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: name,
            url: URL(fileURLWithPath: "/virtual/\(name)"),
            fileSize: fileSize,
            modelType: modelType
        )
    }

    private func makeSelection() -> ModelSelection {
        ModelSelection(
            inferenceService: inferenceService,
            modelStorage: modelStorage,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * 1_024 * 1_024 * 1_024)
        )
    }

    // MARK: - Grouping

    func test_groupedModels_splitsFoundationFromDownloaded() {
        let selection = makeSelection()
        let gguf = makeModel(name: "alpha.gguf", modelType: .gguf)
        let mlx = makeModel(name: "beta-mlx", modelType: .mlx)
        selection.injectAvailableModelsForTesting([.builtInFoundation, gguf, mlx])

        let groups = selection.groupedModels(by: .alphabetical)

        XCTAssertEqual(groups.map(\.group), [.foundation, .downloaded])
        XCTAssertEqual(groups[0].models.map(\.modelType), [.foundation])
        XCTAssertEqual(groups[1].models.map(\.name), ["alpha.gguf", "beta-mlx"])
    }

    func test_groupedModels_omitsEmptySections() {
        let selection = makeSelection()
        let gguf = makeModel(name: "only.gguf", modelType: .gguf)
        selection.injectAvailableModelsForTesting([gguf])

        let groups = selection.groupedModels(by: .alphabetical)

        XCTAssertEqual(groups.map(\.group), [.downloaded])
    }

    // MARK: - Scoring surface (the recommendation product)

    func test_scoredModels_attachesScores() {
        let selection = makeSelection()
        let gguf = makeModel(name: "scoreable.gguf", modelType: .gguf, fileSize: 3 * 1_024 * 1_024 * 1_024)
        selection.injectAvailableModelsForTesting([gguf])

        let scored = selection.scoredModels(useCase: .general)

        XCTAssertEqual(scored.count, 1)
        XCTAssertNotNil(scored.first?.score, "A real on-disk model must score via the ModelInfo fit bridge")
    }

    // MARK: - Headless latest-wins

    func test_loadSelected_resolvesLatestSelection() async {
        // Two local models selected back-to-back; the headless load path must
        // commit the latest selection (mirror of ChatViewModel's guarantee).
        let firstBackend = GatedBackend()
        let secondBackend = GatedBackend()
        let service = InferenceService()
        service.registerBackendFactory { type in
            switch type {
            case .gguf: return firstBackend
            case .foundation: return secondBackend
            case .mlx: return nil
            default: return nil
            }
        }
        let selection = ModelSelection(
            inferenceService: service,
            modelStorage: modelStorage,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * 1_024 * 1_024 * 1_024)
        )
        let first = makeModel(name: "first.gguf", modelType: .gguf, fileSize: 1_024)
        let second = makeModel(name: "second.foundation", modelType: .foundation, fileSize: 0)
        selection.injectAvailableModelsForTesting([first, second])

        selection.select(first)
        selection.loadSelected()
        await firstBackend.waitUntilStarted()

        selection.select(second)
        selection.loadSelected()
        await secondBackend.waitUntilStarted()

        await secondBackend.releaseSuccess()
        await waitUntil { service.isModelLoaded && service.activeBackendName == BackendName.foundation.rawValue }

        await firstBackend.releaseSuccess()
        await waitUntil { firstBackend.unloadCount == 1 }

        XCTAssertEqual(selection.selectedModel?.id, second.id)
        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, BackendName.foundation.rawValue)
    }

    // MARK: - Helpers

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
}

// MARK: - Test seam

extension ModelSelection {
    /// Seeds the underlying registry's `availableModels` so tests can exercise
    /// grouping/scoring/load without touching the filesystem.
    func injectAvailableModelsForTesting(_ models: [ModelInfo]) {
        registry.availableModels = models
    }
}

// MARK: - Gated backend

private actor GatedGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters; startWaiters.removeAll()
        for w in waiters { w.resume() }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters; releaseWaiters.removeAll()
        for w in waiters { w.resume() }
    }
    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

private final class GatedBackend: InferenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = GatedGate()
    private var _loaded = false
    private var _unloadCount = 0

    var isModelLoaded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _loaded }
        set { lock.lock(); _loaded = newValue; lock.unlock() }
    }
    var isGenerating: Bool = false
    var unloadCount: Int { lock.lock(); defer { lock.unlock() }; return _unloadCount }

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    func waitUntilStarted() async { await gate.waitUntilStarted() }
    func releaseSuccess() async { await gate.release() }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        await gate.markStarted()
        await gate.waitForRelease()
        isModelLoaded = true
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        GenerationStream(AsyncThrowingStream { $0.finish() })
    }

    func stopGeneration() {}

    func unloadModel() {
        lock.lock(); _unloadCount += 1; _loaded = false; lock.unlock()
    }
}
