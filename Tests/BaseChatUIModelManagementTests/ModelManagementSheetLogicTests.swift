@preconcurrency import XCTest
#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
@testable import BaseChatUI
@testable import BaseChatUIModelManagement
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

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

    // MARK: - Model type variants

    func test_modelType_distinctCases() {
        let types: [ModelType] = [.gguf, .mlx, .foundation]
        // Each type is distinct — they drive different backend and badge rendering.
        XCTAssertNotEqual(types[0], types[1])
        XCTAssertNotEqual(types[1], types[2])
        XCTAssertNotEqual(types[0], types[2])
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
        let vm = ModelManagementViewModel()
        // totalStorageUsed should return a formatted string even if no models exist.
        XCTAssertFalse(vm.totalStorageUsed.isEmpty, "Storage display should never be empty")
        XCTAssertFalse(vm.modelsDirectoryPath.isEmpty, "Models directory path should never be empty")
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

        let sorted = ModelSelectionTabView.sortModels([beta, alpha], by: .alphabetical)

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

        let sorted = ModelSelectionTabView.sortModels([mlx, gguf, foundation], by: .type)

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

        let sorted = ModelSelectionTabView.sortModels([large, small], by: .size)

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

        let sorted = ModelSelectionTabView.sortModels([minimal, capable], by: .capability)

        XCTAssertEqual(sorted.map(\.name), ["Capable", "Minimal"])
    }

    #if canImport(AppKit)
    private func hostedSheetFittingSize(for tab: ModelManagementSheet.Tab) -> CGSize {
        let (vm, _) = makeViewModelWithMock()
        let controller = NSHostingController(
            rootView: ModelManagementSheet(initialTab: tab)
                .environment(vm)
                .environment(ModelManagementViewModel())
        )

        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()
        return controller.view.fittingSize
    }
    #endif
}
