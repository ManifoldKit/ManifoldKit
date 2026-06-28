import XCTest
@testable import ManifoldUI
import ManifoldInference
import ManifoldTestSupport

/// Tripwire for the "selected but never loaded" diagnostic.
///
/// Setting `selectedModel` / `selectedEndpoint` only *records* a choice — a host
/// must still dispatch a load (`dispatchSelectedLoad()` / `loadSelectedModel()`).
/// A send with a live selection but no loaded backend used to surface the same
/// generic "select a model" error a host who already selected would find
/// misleading. The send path now logs a warning and surfaces a distinct,
/// actionable message; these tests lock that distinction in so the diagnostic
/// can't silently regress back to the generic text.
@MainActor
final class SelectedModelLoadWarningTests: XCTestCase {

    private var harness: TestChatViewModelHarness!

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    private func makeModel() -> ModelInfo {
        ModelInfo(
            name: "unloaded.gguf",
            fileName: "unloaded.gguf",
            url: URL(fileURLWithPath: "/virtual/unloaded.gguf"),
            fileSize: 1_024,
            modelType: .gguf
        )
    }

    func test_sendWithSelectedButUnloadedModel_surfacesDistinctMessage() async throws {
        // `mock: nil` → default InferenceService with nothing loaded.
        harness = try makeTestChatViewModel(activateSession: true)
        let vm = harness.vm
        vm.selectedModel = makeModel()
        XCTAssertFalse(vm.isModelLoaded, "Precondition: a model is selected but not loaded.")

        vm.inputText = "hello"
        await vm.sendMessage()

        XCTAssertEqual(
            vm.activeError?.message,
            "A model is selected but not loaded yet. Load it before sending.",
            "A send with a selected-but-unloaded model must surface the actionable load-it message, not the generic select-a-model text."
        )
    }

    func test_sendWithNoSelection_keepsGenericSelectMessage() async throws {
        harness = try makeTestChatViewModel(activateSession: true)
        let vm = harness.vm
        XCTAssertNil(vm.selectedModel)
        XCTAssertNil(vm.selectedEndpoint)

        vm.inputText = "hello"
        await vm.sendMessage()

        XCTAssertEqual(
            vm.activeError?.message,
            "No model loaded. Select a model from the sidebar first.",
            "With no selection at all the generic select-a-model message must remain."
        )
    }
}
