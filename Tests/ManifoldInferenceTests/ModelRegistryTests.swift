import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class ModelRegistryTests: XCTestCase {

    // MARK: - Fixtures

    private var modelsDirectory: URL!
    private var inferenceService: InferenceService!
    private var modelStorage: ModelStorageService!

    override func setUp() async throws {
        try await super.setUp()
        modelsDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("ModelRegistryTests-\(UUID().uuidString)", isDirectory: true)
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
        inferenceService = nil
        modelStorage = nil
        try await super.tearDown()
    }

    // MARK: - Construction

    func test_init_withZeroDeps_startsEmpty() {
        let registry = ModelRegistry(
            inferenceService: inferenceService,
            modelStorage: modelStorage
        )

        XCTAssertTrue(registry.availableModels.isEmpty)
        XCTAssertNil(registry.selectedModel)
        XCTAssertNil(registry.foundationModelProvider)
    }

    // MARK: - refresh()

    /// Writes a file shaped like a GGUF model — `ModelInfo(ggufURL:)` checks
    /// the four magic bytes "GGUF", so the discoverModels path needs that
    /// prefix to recognise the file.
    @discardableResult
    private func createFakeGgufFile(named name: String, sizeBytes: Int = 4096) throws -> URL {
        let url = modelsDirectory.appendingPathComponent(name)
        var data = Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
        data.append(Data(repeating: 0xAA, count: sizeBytes - 4))
        try data.write(to: url)
        return url
    }

    func test_refresh_populatesAvailableModelsFromStorage() throws {
        try createFakeGgufFile(named: "registry-test.gguf")

        let registry = ModelRegistry(
            inferenceService: inferenceService,
            modelStorage: modelStorage
        )

        try registry.refresh()

        XCTAssertTrue(
            registry.availableModels.contains(where: { $0.fileName == "registry-test.gguf" }),
            "refresh() should publish on-disk models into availableModels"
        )
    }

    func test_refresh_includesFoundationWhenProviderReturnsTrue() throws {
        let registry = ModelRegistry(
            inferenceService: inferenceService,
            modelStorage: modelStorage,
            foundationModelProvider: { true }
        )

        try registry.refresh()

        XCTAssertTrue(
            registry.availableModels.contains(where: { $0.modelType == .foundation }),
            "Foundation model should be inserted when foundationModelProvider returns true"
        )
    }

    func test_refresh_clearsSelectedModelWhenNoLongerOnDisk() throws {
        let modelFile = try createFakeGgufFile(named: "ephemeral.gguf")

        let registry = ModelRegistry(
            inferenceService: inferenceService,
            modelStorage: modelStorage
        )
        try registry.refresh()

        guard let discovered = registry.availableModels.first(where: { $0.fileName == "ephemeral.gguf" }) else {
            return XCTFail("Pre-condition: model file should be discoverable")
        }
        registry.selectedModel = discovered

        // Delete the underlying file and refresh again — selectedModel must clear.
        try FileManager.default.removeItem(at: modelFile)
        try registry.refresh()

        XCTAssertNil(
            registry.selectedModel,
            "selectedModel should clear when its model is no longer in availableModels"
        )
    }

    // MARK: - selectedModel round-trip

    func test_selectedModel_writeReadRoundTrip() {
        let registry = ModelRegistry(
            inferenceService: inferenceService,
            modelStorage: modelStorage
        )

        let model = ModelInfo.builtInFoundation
        registry.selectedModel = model
        XCTAssertEqual(registry.selectedModel?.id, model.id)

        registry.selectedModel = nil
        XCTAssertNil(registry.selectedModel)
    }

    // MARK: - compatibility(for:)

    func test_compatibility_forwardsToInferenceService() {
        let registry = ModelRegistry(
            inferenceService: inferenceService,
            modelStorage: modelStorage
        )

        // The mock-backed InferenceService recognises the mock backend, so a
        // direct call and the registry forwarding call must agree on every
        // ModelType.
        for modelType in [ModelType.gguf, .mlx, .foundation] {
            XCTAssertEqual(
                registry.compatibility(for: modelType),
                inferenceService.compatibility(for: modelType),
                "Registry compatibility should match InferenceService for \(modelType)"
            )
        }
    }
}
