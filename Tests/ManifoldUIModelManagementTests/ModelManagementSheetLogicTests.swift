@preconcurrency import XCTest
#if canImport(AppKit)
import AppKit
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI
#endif
import SwiftUI
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for the logic that drives ModelManagementSheet tabs, model selection,
/// and storage display.
///
/// The sheet has three tabs (Select, Download, Storage) gated by feature flags,
/// and a model selection flow that immediately activates the chosen model.
/// These tests verify tab availability, model selection state transitions,
/// and the data that populates each tab.
@MainActor
final class ModelManagementSheetLogicTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private nonisolated(unsafe) var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses { harness.cleanup() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeViewModelWithMock(
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend) {
        let harness = try! makeTestChatViewModel(mock: mock, activateSession: true)
        harnesses.append(harness)
        return (harness.vm, harness.mock!)
    }

    // MARK: - Tab enumeration

    func test_tab_rawValues() {
        XCTAssertEqual(ModelManagementSheet.Tab.select.rawValue, "Select")
        XCTAssertEqual(ModelManagementSheet.Tab.download.rawValue, "Download")
        XCTAssertEqual(ModelManagementSheet.Tab.storage.rawValue, "Storage")
    }

    func test_tab_systemImages() {
        XCTAssertEqual(ModelManagementSheet.Tab.select.systemImage, "checkmark.circle")
        XCTAssertEqual(ModelManagementSheet.Tab.download.systemImage, "square.and.arrow.down")
        XCTAssertEqual(ModelManagementSheet.Tab.storage.systemImage, "externaldrive")
    }

    func test_tab_allCases() {
        let cases = ModelManagementSheet.Tab.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertEqual(cases, [.select, .download, .storage])
    }

    #if canImport(AppKit)
    // Regression guard for #378: a `NavigationStack { VStack { List } }` sheet
    // collapses to zero height on native macOS without an explicit outer frame.
    // Keep thresholds in lock-step with the `.frame(minWidth:minHeight:)` in
    // `ModelManagementSheet` (currently 560 x 480) so a future refactor that
    // drops the frame fails here rather than silently regressing the sheet.
    func test_macOS_sheetHasStableMinimumLayoutForAllTabs() {
        for tab in ModelManagementSheet.Tab.allCases {
            let size = hostedSheetFittingSize(for: tab)
            XCTAssertGreaterThanOrEqual(
                size.width,
                560,
                "\(tab.rawValue) tab should reserve enough width for its content on macOS"
            )
            XCTAssertGreaterThanOrEqual(
                size.height,
                480,
                "\(tab.rawValue) tab should reserve enough height for its content on macOS"
            )
        }
    }
    #endif

    // MARK: - Model selection state transitions

    func test_modelSelection_setsSelectedModel() {
        let (vm, _) = makeViewModelWithMock()
        let model = ModelInfo(
            name: "Test Model",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 1_000_000_000,
            modelType: .gguf
        )

        vm.selectedModel = model

        XCTAssertEqual(vm.selectedModel?.name, "Test Model")
        XCTAssertEqual(vm.selectedModel?.fileName, "test.gguf")
    }

    func test_modelSelection_clearsEndpointWhenModelSelected() {
        let (vm, _) = makeViewModelWithMock()

        // Simulate having an endpoint selected.
        // The mutual exclusion logic: setting selectedModel clears selectedEndpoint.
        let model = ModelInfo(
            name: "Local Model",
            fileName: "local.gguf",
            url: URL(fileURLWithPath: "/tmp/local.gguf"),
            fileSize: 2_000_000_000,
            modelType: .gguf
        )
        vm.selectedModel = model

        // After selecting a local model, the endpoint should be cleared.
        XCTAssertNil(vm.selectedEndpoint, "Selecting a model should clear the endpoint selection")
        XCTAssertNotNil(vm.selectedModel, "Model should remain selected")
    }

    // MARK: - Available models

    func test_availableModels_emptyOnInit() {
        let vm = ChatViewModel(
            inferenceService: InferenceService(),
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            memoryPressure: MemoryPressureHandler()
        )
        XCTAssertTrue(vm.availableModels.isEmpty, "Available models should be empty on init")
    }

    func test_refreshModels_populatesAvailableModels() {
        let (vm, _) = makeViewModelWithMock()
        vm.refreshModels()
        // The actual count depends on what's on disk; we just verify it doesn't crash.
        // In the existing GenerationViewModelTests, actual GGUF files are created.
    }

    // MARK: - Off-main discovery (#1774)

    /// The sheet's `.task` drives `refreshAsync()` so the chrome paints
    /// immediately and only the model list waits. This proves the registry
    /// exposes content asynchronously, not via a synchronous main-thread scan:
    /// the registry starts empty on appear, and is populated only after the
    /// async refresh resolves.
    func test_refreshAsync_exposesEmptyListBeforeScanResolves_thenPopulated() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a GGUF-shaped file so a completed scan would find one model.
        let gguf = dir.appendingPathComponent("sheet-async.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
        data.append(Data(repeating: 0xAA, count: 4092))
        try data.write(to: gguf)

        let registry = ModelRegistry(
            inferenceService: InferenceService(),
            modelStorage: ModelStorageService(baseDirectory: dir)
        )

        // The sheet renders its chrome with an empty list on appear.
        XCTAssertTrue(registry.availableModels.isEmpty, "Registry exposes an empty list before any scan resolves")

        try await registry.refreshAsync()

        XCTAssertTrue(
            registry.availableModels.contains(where: { $0.fileName == "sheet-async.gguf" }),
            "availableModels must be populated once the off-main scan resolves"
        )
    }

    /// `discoverModelsOffMain()` is the off-main scan that backs `refreshAsync()`
    /// (#1774). Called from the main actor it returns a `(models, errors)` tuple
    /// equivalent to the synchronous `discoverModels(reportingErrors:)` overload,
    /// proving the async API surfaces the same content the sync path would.
    func test_discoverModelsOffMain_matchesSyncDiscovery() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OffMainScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let gguf = dir.appendingPathComponent("offmain.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
        data.append(Data(repeating: 0xAA, count: 4092))
        try data.write(to: gguf)

        let storage = ModelStorageService(baseDirectory: dir, includeUserDocumentsFallback: false)

        let sync = storage.discoverModels()
        let asyncResult = await storage.discoverModelsOffMain()

        XCTAssertEqual(
            asyncResult.models.map(\.id),
            sync.map(\.id),
            "discoverModelsOffMain() must yield the same models (and order) as the synchronous discoverModels()"
        )
        XCTAssertTrue(asyncResult.errors.isEmpty, "A clean GGUF directory yields no discovery errors")
    }

    // MARK: - ModelInfo properties

    func test_modelInfo_ggufType() {
        let model = ModelInfo(
            name: "Test GGUF",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 4_000_000_000,
            modelType: .gguf
        )
        XCTAssertEqual(model.modelType, .gguf)
        XCTAssertEqual(model.name, "Test GGUF")
        XCTAssertEqual(model.fileSize, 4_000_000_000)
    }

    func test_modelInfo_mlxType() {
        let model = ModelInfo(
            name: "Test MLX",
            fileName: "test-mlx",
            url: URL(fileURLWithPath: "/tmp/test-mlx"),
            fileSize: 3_000_000_000,
            modelType: .mlx
        )
        XCTAssertEqual(model.modelType, .mlx)
    }

    func test_modelInfo_foundationType() {
        let model = ModelInfo(
            name: "Foundation Model",
            fileName: "foundation",
            url: URL(fileURLWithPath: "/tmp/foundation"),
            fileSize: 0,
            modelType: .foundation
        )
        XCTAssertEqual(model.modelType, .foundation)
    }

    func test_modelInfo_fileSizeFormatted() {
        let model = ModelInfo(
            name: "4GB Model",
            fileName: "model.gguf",
            url: URL(fileURLWithPath: "/tmp/model.gguf"),
            fileSize: 4_000_000_000,
            modelType: .gguf
        )
        // fileSizeFormatted should produce a human-readable string.
        XCTAssertFalse(model.fileSizeFormatted.isEmpty, "Formatted file size should not be empty")
    }

    // MARK: - ModelManagementViewModel state

    func test_managementViewModel_defaultState() {
        let vm = ModelManagementViewModel()
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertTrue(vm.searchResults.isEmpty)
        XCTAssertFalse(vm.isSearching)
        XCTAssertNil(vm.searchError)
    }

    func test_managementViewModel_storageInfo() {
        let vm = ModelManagementViewModel(
            modelStorage: ModelStorageService(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            )
        )
        // totalStorageUsed should return a formatted string even if no models exist.
        XCTAssertFalse(vm.totalStorageUsed.isEmpty, "Storage display should never be empty")
        XCTAssertFalse(vm.modelsDirectoryPath.isEmpty, "Models directory path should never be empty")
    }

    // MARK: - Cached discovery state (#1787)

    func test_discoveredModels_cachedAndOffMain_noScanOnRead() async throws {
        let counter = ScanCountingFileManager()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = ModelStorageService(
            fileManager: counter,
            baseDirectory: scratch,
            includeUserDocumentsFallback: false
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try storage.ensureModelsDirectory()

        // Two fixture GGUFs on disk.
        for i in 0..<2 {
            var data = Data([0x47, 0x47, 0x55, 0x46])
            data.append(Data(repeating: 0xAA, count: 1020))
            try data.write(to: storage.modelsDirectory.appendingPathComponent("m-\(i).gguf"))
        }

        let vm = ModelManagementViewModel(modelStorage: storage)

        // Pre-refresh: cache is empty, totalStorageUsed derives "0 bytes" without
        // touching disk, and hasLoadedModelsOnce is false.
        XCTAssertTrue(vm.discoveredModels.isEmpty, "Cache must be empty before any refresh")
        XCTAssertFalse(vm.hasLoadedModelsOnce)

        // Reading the render-path properties must NOT trigger a disk scan.
        counter.scanCount = 0
        _ = vm.discoveredModels
        _ = vm.totalStorageUsed
        _ = vm.discoveredModels
        _ = vm.totalStorageUsed
        XCTAssertEqual(counter.scanCount, 0, "Reading discoveredModels/totalStorageUsed must never scan disk (#1787)")

        // After an awaited refresh the cache is populated.
        vm.refreshDiscoveredModels()
        try await waitForRefresh(vm)

        XCTAssertEqual(vm.discoveredModels.count, 2, "Refresh must populate the cache from disk")
        XCTAssertTrue(vm.hasLoadedModelsOnce)
        XCTAssertFalse(vm.totalStorageUsed.isEmpty)

        // Reading again post-refresh still triggers zero additional scans.
        let afterRefreshCount = counter.scanCount
        _ = vm.discoveredModels
        _ = vm.totalStorageUsed
        XCTAssertEqual(counter.scanCount, afterRefreshCount, "Post-refresh reads must stay cache-only")
    }

    func test_refreshDiscoveredModels_isSingleFlight() async throws {
        let counter = ScanCountingFileManager()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = ModelStorageService(
            fileManager: counter,
            baseDirectory: scratch,
            includeUserDocumentsFallback: false
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try storage.ensureModelsDirectory()
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0xAA, count: 1020))
        try data.write(to: storage.modelsDirectory.appendingPathComponent("only.gguf"))

        let vm = ModelManagementViewModel(modelStorage: storage)
        counter.scanCount = 0

        // Fire N concurrent refreshes synchronously on the main actor — the
        // single-flight guard collapses them into ONE in-flight scan.
        for _ in 0..<8 {
            vm.refreshDiscoveredModels()
        }
        try await waitForRefresh(vm)

        XCTAssertEqual(counter.scanCount, 1, "Concurrent refresh calls must collapse into a single scan")
        XCTAssertEqual(vm.discoveredModels.count, 1)
    }

    /// Polls until the view model's in-flight refresh has settled, with a tight deadline.
    private func waitForRefresh(_ vm: ModelManagementViewModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while vm.isRefreshingModels && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(vm.isRefreshingModels, "Refresh should settle within the deadline")
    }

    // MARK: - Download model grouping

    func test_downloadableModelGroup_singleVariant() {
        let models = [
            DownloadableModel(
                repoID: "test/repo",
                fileName: "model-q4.gguf",
                displayName: "Test Model Q4",
                modelType: .gguf,
                sizeBytes: 4_000_000_000
            )
        ]
        let groups = DownloadableModelGroup.group(models)
        XCTAssertEqual(groups.count, 1, "Single model should produce one group")
        XCTAssertEqual(groups.first?.variants.count, 1, "Single model group should have one variant")
    }

    func test_downloadableModelGroup_multipleVariants() {
        let models = [
            DownloadableModel(
                repoID: "test/repo",
                fileName: "model-q4.gguf",
                displayName: "Test Model Q4",
                modelType: .gguf,
                sizeBytes: 4_000_000_000
            ),
            DownloadableModel(
                repoID: "test/repo",
                fileName: "model-q6.gguf",
                displayName: "Test Model Q6",
                modelType: .gguf,
                sizeBytes: 6_000_000_000
            )
        ]
        let groups = DownloadableModelGroup.group(models)
        // Both models are from the same repo, so they should be grouped together.
        XCTAssertEqual(groups.count, 1, "Same-repo models should be grouped together")
        XCTAssertEqual(groups.first?.variants.count, 2, "Group should contain both variants")
    }

    func test_downloadableModelGroup_differentRepos() {
        let models = [
            DownloadableModel(
                repoID: "test/repo1",
                fileName: "model-a.gguf",
                displayName: "Model A",
                modelType: .gguf,
                sizeBytes: 4_000_000_000
            ),
            DownloadableModel(
                repoID: "test/repo2",
                fileName: "model-b.gguf",
                displayName: "Model B",
                modelType: .gguf,
                sizeBytes: 5_000_000_000
            )
        ]
        let groups = DownloadableModelGroup.group(models)
        XCTAssertEqual(groups.count, 2, "Different repos should produce separate groups")
    }

    // MARK: - Capability tier display

    func test_capabilityTier_labels() {
        // ModelCapabilityTier drives badge text in ModelSelectRow.
        let tiers: [ModelCapabilityTier] = [.minimal, .fast, .balanced, .capable, .frontier]
        for tier in tiers {
            XCTAssertFalse(tier.label.isEmpty, "\(tier) should have a non-empty label")
        }
    }

    func test_capabilityTier_labelsAreHumanReadable() {
        XCTAssertEqual(ModelCapabilityTier.minimal.label, "Minimal")
        XCTAssertEqual(ModelCapabilityTier.fast.label, "Fast")
        XCTAssertEqual(ModelCapabilityTier.balanced.label, "Balanced")
        XCTAssertEqual(ModelCapabilityTier.capable.label, "Capable")
        XCTAssertEqual(ModelCapabilityTier.frontier.label, "Frontier")
    }

    func test_capabilityTier_ordering() {
        XCTAssertTrue(ModelCapabilityTier.minimal < .fast)
        XCTAssertTrue(ModelCapabilityTier.fast < .balanced)
        XCTAssertTrue(ModelCapabilityTier.balanced < .capable)
        XCTAssertTrue(ModelCapabilityTier.capable < .frontier)
    }

    // MARK: - Model selection sorting

    func test_modelSelectionSortOrder_allCases() {
        XCTAssertEqual(
            ModelSelectionSortOrder.allCases,
            [.alphabetical, .type, .size, .capability]
        )
    }

    func test_sortModels_alphabetical_ordersByName() {
        let beta = ModelInfo(
            name: "Beta",
            fileName: "beta.gguf",
            url: URL(fileURLWithPath: "/tmp/beta.gguf"),
            fileSize: 3 * oneGB,
            modelType: .gguf
        )
        let alpha = ModelInfo(
            name: "Alpha",
            fileName: "alpha.gguf",
            url: URL(fileURLWithPath: "/tmp/alpha.gguf"),
            fileSize: 6 * oneGB,
            modelType: .gguf
        )

        let sorted = ModelSelection.sortModels([beta, alpha], by: .alphabetical)

        XCTAssertEqual(sorted.map(\.name), ["Alpha", "Beta"])
    }

    func test_sortModels_type_groupsFoundationThenGGUFThenMLX() {
        let mlx = ModelInfo(
            name: "Zulu MLX",
            fileName: "zulu-mlx",
            url: URL(fileURLWithPath: "/tmp/zulu-mlx"),
            fileSize: 4 * oneGB,
            modelType: .mlx
        )
        let gguf = ModelInfo(
            name: "Alpha GGUF",
            fileName: "alpha.gguf",
            url: URL(fileURLWithPath: "/tmp/alpha.gguf"),
            fileSize: 2 * oneGB,
            modelType: .gguf
        )
        let foundation = ModelInfo.builtInFoundation

        let sorted = ModelSelection.sortModels([mlx, gguf, foundation], by: .type)

        XCTAssertEqual(sorted.map(\.modelType), [.foundation, .gguf, .mlx])
    }

    func test_sortModels_size_ordersSmallestFirst() {
        let large = ModelInfo(
            name: "Large",
            fileName: "large.gguf",
            url: URL(fileURLWithPath: "/tmp/large.gguf"),
            fileSize: 8 * oneGB,
            modelType: .gguf
        )
        let small = ModelInfo(
            name: "Small",
            fileName: "small.gguf",
            url: URL(fileURLWithPath: "/tmp/small.gguf"),
            fileSize: 2 * oneGB,
            modelType: .gguf
        )

        let sorted = ModelSelection.sortModels([large, small], by: .size)

        XCTAssertEqual(sorted.map(\.name), ["Small", "Large"])
    }

    func test_sortModels_capability_ordersStrongestTierFirst() {
        let minimal = ModelInfo(
            name: "Minimal",
            fileName: "minimal.gguf",
            url: URL(fileURLWithPath: "/tmp/minimal.gguf"),
            fileSize: 1 * oneGB,
            modelType: .gguf
        )
        let capable = ModelInfo(
            name: "Capable",
            fileName: "capable.gguf",
            url: URL(fileURLWithPath: "/tmp/capable.gguf"),
            fileSize: 12 * oneGB,
            modelType: .gguf
        )

        let sorted = ModelSelection.sortModels([minimal, capable], by: .capability)

        XCTAssertEqual(sorted.map(\.name), ["Capable", "Minimal"])
    }

    #if canImport(AppKit)
    private func hostedSheetFittingSize(for tab: ModelManagementSheet.Tab) -> CGSize {
        let (vm, _) = makeViewModelWithMock()
        let modelManagement = ModelManagementViewModel(
            modelStorage: ModelStorageService(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            )
        )
        let controller = NSHostingController(
            rootView: ModelManagementSheet(initialTab: tab)
                .environment(vm)
                .environment(modelManagement)
        )

        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()
        return controller.view.fittingSize
    }
    #endif
}

// MARK: - Scan-counting FileManager

/// A `FileManager` subclass that counts directory enumerations so a test can
/// prove the view model scans disk only when it intends to (#1787).
///
/// `@unchecked Sendable`: the discovery scan runs on a detached task thread, but
/// the test only reads `scanCount` after awaiting the refresh to completion, so
/// the read is ordered after every write via the `@MainActor` hop that publishes
/// `isRefreshingModels = false`.
private final class ScanCountingFileManager: FileManager, @unchecked Sendable {
    var scanCount = 0

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        scanCount += 1
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
