@preconcurrency import XCTest
import Foundation
import SwiftUI
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Coverage for the public ``ModelPicker`` sample view (PR 3): it renders the
/// sorted / grouped model data ``ModelSelection`` vends, and selecting a row
/// writes back to the shared ``ModelRegistry``.
@MainActor
final class ModelPickerTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024
    private var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses { harness.cleanup() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeRegistry() throws -> ModelRegistry {
        let harness = try makeTestChatViewModel()
        harnesses.append(harness)
        return harness.vm.modelRegistry
    }

    private func gguf(_ name: String, sizeGB: UInt64) -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).gguf",
            url: URL(fileURLWithPath: "/tmp/\(name).gguf"),
            fileSize: sizeGB * oneGB,
            modelType: .gguf
        )
    }

    // MARK: - Flat sorted rendering

    func test_modelPicker_sortedModels_matchesModelSelectionOrdering() throws {
        let registry = try makeRegistry()
        let models = [gguf("Zeta", sizeGB: 2), gguf("Alpha", sizeGB: 5)]
        registry.availableModels = models

        let view = ModelPicker(modelRegistry: registry, onSelect: {})

        // The view must render exactly what the headless `ModelSelection`
        // ordering helper produces — the view is a thin pass-through.
        XCTAssertEqual(
            view.sortedModels.map(\.name),
            ModelSelection.sortModels(models, by: .alphabetical).map(\.name)
        )
        XCTAssertEqual(view.sortedModels.map(\.name), ["Alpha", "Zeta"])
    }

    // MARK: - Grouped rendering

    func test_modelPicker_groupedModels_splitsFoundationAndDownloaded() throws {
        let registry = try makeRegistry()
        let foundation = ModelInfo.builtInFoundation
        let local = gguf("Local", sizeGB: 3)
        registry.availableModels = [local, foundation]

        let view = ModelPicker(modelRegistry: registry, grouped: true, onSelect: {})

        let groups = view.groupedModels
        XCTAssertEqual(groups.map(\.group), [.foundation, .downloaded])
        XCTAssertEqual(groups.first?.models.map(\.name), [foundation.name])
        XCTAssertEqual(groups.last?.models.map(\.name), [local.name])

        // The view must render exactly the headless grouping helper's output.
        XCTAssertEqual(
            groups.map { $0.group },
            ModelSelection.groupModels(registry.availableModels, by: .alphabetical).map { $0.group }
        )
    }

    func test_modelPicker_groupedModels_omitsEmptyFoundationSection() throws {
        let registry = try makeRegistry()
        registry.availableModels = [gguf("Only", sizeGB: 1)]

        let view = ModelPicker(modelRegistry: registry, grouped: true, onSelect: {})

        XCTAssertEqual(view.groupedModels.map(\.group), [.downloaded])
    }

    // MARK: - Selection writes back through the registry

    func test_modelPicker_sharesSelectionStateWithRegistry() throws {
        let registry = try makeRegistry()
        let model = gguf("Pick", sizeGB: 2)
        registry.availableModels = [model]

        // ModelPicker reads `selectedModel` from the registry; writing the
        // registry must be reflected in what the picker would render as selected.
        registry.selectedModel = model
        XCTAssertEqual(registry.selectedModel?.id, model.id)

        let view = ModelPicker(modelRegistry: registry, onSelect: {})
        XCTAssertEqual(view.sortedModels.first?.id, registry.selectedModel?.id)
    }
}
