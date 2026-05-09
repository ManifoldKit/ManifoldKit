@preconcurrency import XCTest
import Foundation
import SwiftUI
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Smoke coverage for the new explicit-init path on the model-management
/// views: each view must instantiate, accept its dependencies, and read
/// `availableModels` / `selectedModel` through ``ModelRegistry`` rather
/// than through `@Environment(ChatViewModel.self)`.
@MainActor
final class ModelManagementExplicitInitTests: XCTestCase {

    private var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses {
            harness.cleanup()
        }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeRegistry() throws -> (ModelRegistry, ChatViewModel) {
        let harness = try makeTestChatViewModel()
        harnesses.append(harness)
        return (harness.vm.modelRegistry, harness.vm)
    }

    /// Hosts a SwiftUI view in a platform-appropriate hosting controller and
    /// triggers a layout pass. Used to confirm a view's `body` builds
    /// successfully under realistic conditions — calling `.body` directly
    /// on a SwiftUI view is a SwiftUI fatal error.
    private func renderHosted<V: View>(_ view: V) {
        #if canImport(AppKit)
        let vc = NSHostingController(rootView: view)
        vc.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        vc.view.layoutSubtreeIfNeeded()
        #elseif canImport(UIKit)
        let vc = UIHostingController(rootView: view)
        vc.view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        vc.view.layoutIfNeeded()
        #endif
    }

    // MARK: - ModelManagementSheet

    func test_modelManagementSheet_explicitInit_rendersWithoutChatViewModel() throws {
        let (registry, _) = try makeRegistry()
        // Compile-time assertion: the new init accepts a `ModelRegistry`
        // without a `ChatViewModel` in scope.
        let sheet = ModelManagementSheet(modelRegistry: registry, initialTab: .select)
        renderHosted(sheet.environment(ModelManagementViewModel()))
    }

    func test_modelManagementSheet_writesPropagateThroughRegistry() throws {
        let (registry, vm) = try makeRegistry()
        let model = ModelInfo.builtInFoundation

        // Mutate via registry; the chat view model surface must agree.
        registry.selectedModel = model
        XCTAssertEqual(vm.selectedModel?.id, model.id)
    }

    // MARK: - ModelSelectionTabView

    func test_modelSelectionTabView_explicitInit_readsRegistryAvailableModels() throws {
        let (registry, _) = try makeRegistry()
        let model = ModelInfo.builtInFoundation
        registry.availableModels = [model]

        let view = ModelSelectionTabView(modelRegistry: registry, onSelect: {})
        XCTAssertEqual(view.sortedModels.count, 1)
        XCTAssertEqual(view.sortedModels.first?.id, model.id)
    }

    // MARK: - LocalModelStorageView

    func test_localModelStorageView_explicitInit_renders() throws {
        let (registry, _) = try makeRegistry()
        let view = LocalModelStorageView(modelRegistry: registry)
            .environment(ModelManagementViewModel())
        renderHosted(view)
    }

    // MARK: - StorageManagementView

    func test_storageManagementView_explicitInit_renders() throws {
        let (registry, _) = try makeRegistry()
        let view = StorageManagementView(modelRegistry: registry)
            .environment(ModelManagementViewModel())
        renderHosted(view)
    }

    // MARK: - HuggingFaceBrowserView

    func test_huggingFaceBrowserView_explicitInit_renders() throws {
        let (registry, _) = try makeRegistry()
        let view = HuggingFaceBrowserView(
            modelRegistry: registry,
            recommendedModelIDs: nil,
            recommendationTitle: nil,
            recommendationMessage: nil
        )
            .environment(ModelManagementViewModel())
        renderHosted(view)
    }
}
