import XCTest
import SwiftUI
import SwiftData
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference

/// Verifies that all user-facing controls in ModelManagementSheet and
/// GenerationSettingsView are present in the view hierarchy.
///
/// Uses `Swift.dump()` on a hosted view to capture the hierarchy as text,
/// then asserts expected type names, SF Symbol identifiers, and rendered
/// string literals appear. This catches accidental control removal without
/// requiring pixel rendering or XCUITest.
///
/// Note: SwiftUI's dump output includes rendered text for Form-based views
/// (GenerationSettingsView) but not for List-based views (ModelManagementSheet
/// tab content). For List views, we assert on type names and SF Symbol
/// identifiers instead.
@MainActor
final class ModelAndSettingsControlTests: XCTestCase {

    // MARK: - Helpers

    private func makeChatViewModel() -> ChatViewModel {
        let oneGB: UInt64 = 1_024 * 1_024 * 1_024
        return ChatViewModel(
            inferenceService: InferenceService(),
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
        )
    }

    /// A `ChatViewModel` whose `InferenceService` has declared GGUF support —
    /// mirrors `ModelManagementSheetLogicTests.makeRegistry(supporting:)`, the
    /// same real `declareSupport(for:)` call a companion backend registrar
    /// (manifold-mlx / manifold-llama) makes at runtime (#1749). Needed so the
    /// Download tab is actually reachable: `ModelManagementSheet.availableTabs`
    /// hides it unless `modelRegistry.compatibility(for:)` reports a
    /// downloadable type supported, and a bare `InferenceService()` never does.
    private func makeChatViewModelWithDownloadableBackend() -> ChatViewModel {
        let oneGB: UInt64 = 1_024 * 1_024 * 1_024
        let service = InferenceService()
        service.declareSupport(for: .gguf)
        return ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
        )
    }

    // MARK: - ModelManagementSheet — Tab Structure

    private func modelManagementDump(tab: ModelManagementSheet.Tab = .select) -> String {
        let chatVM = makeChatViewModel()
        return ViewHierarchyDumper.dump(
            ModelManagementSheet(modelRegistry: chatVM.modelRegistry, initialTab: tab)
                .environment(ModelManagementViewModel())
        )
    }

    /// Like `modelManagementDump`, but backed by a registry that has declared
    /// GGUF support so the `.download` tab is actually reachable (see
    /// `makeChatViewModelWithDownloadableBackend`).
    private func modelManagementDownloadableDump(tab: ModelManagementSheet.Tab = .download) -> String {
        let chatVM = makeChatViewModelWithDownloadableBackend()
        return ViewHierarchyDumper.dump(
            ModelManagementSheet(modelRegistry: chatVM.modelRegistry, initialTab: tab)
                .environment(ModelManagementViewModel())
        )
    }

    func test_modelManagement_hasSegmentedPicker() {
        let dump = modelManagementDump(tab: .select)
        // macOS renders segmented pickers as SystemSegmentedControl
        #if canImport(AppKit)
        XCTAssertTrue(
            dump.contains("SystemSegmentedControl"),
            "Tab picker should render as a segmented control"
        )
        #endif
    }

    // MARK: - ModelManagementSheet — Download Tab Content

    func test_modelManagement_downloadTab_hasWhyDownloadView() {
        let dump = modelManagementDownloadableDump(tab: .download)
        XCTAssertTrue(
            dump.contains("WhyDownloadView"),
            "Download tab should contain the WhyDownloadView explainer"
        )
    }

    func test_modelManagement_downloadTab_hasDownloadableModelRow() {
        let dump = modelManagementDownloadableDump(tab: .download)
        // DownloadableModelRow is rendered for recommended models
        XCTAssertTrue(
            dump.contains("DownloadableModelRow"),
            "Download tab should contain DownloadableModelRow for recommended models"
        )
    }

    func test_modelManagement_downloadTab_hasDownloadableModelGroup() {
        let dump = modelManagementDownloadableDump(tab: .download)
        XCTAssertTrue(
            dump.contains("DownloadableModelGroup"),
            "Download tab should reference DownloadableModelGroup for search result grouping"
        )
    }

    // MARK: - ModelManagementSheet — Storage Tab Content

    func test_modelManagement_storageTab_hasDeleteModelAlert() {
        let dump = modelManagementDump(tab: .storage)
        // The alert title "Delete Model" appears in the dump as a string literal
        XCTAssertTrue(
            dump.contains("Delete Model"),
            "Storage tab should have a 'Delete Model' confirmation alert configured"
        )
    }

    func test_modelManagement_storageTab_notInSelectTab() {
        let dump = modelManagementDump(tab: .select)
        XCTAssertFalse(
            dump.contains("Delete Model"),
            "Select tab should not contain 'Delete Model' alert (storage tab content)"
        )
    }

    // MARK: - GenerationSettingsView — Text Labels

    /// Shared dump for settings tests to avoid repeated view construction.
    private func generationSettingsDump() -> String {
        ViewHierarchyDumper.dump(
            GenerationSettingsView { EmptyView() }
                .environment(makeChatViewModel())
        )
    }

    func test_generationSettings_hasTemperatureLabel() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("Temperature"),
            "Settings should contain the 'Temperature' label"
        )
    }

    func test_generationSettings_hasTemperatureDefaultValue() {
        let dump = generationSettingsDump()
        // Default temperature of 0.70 is rendered as text
        XCTAssertTrue(
            dump.contains("0.70"),
            "Settings should show the default temperature value (0.70)"
        )
    }

    func test_generationSettings_hasSystemPromptSection() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("System Prompt"),
            "Settings should contain the 'System Prompt' section header"
        )
    }

    func test_generationSettings_hasSystemPromptPlaceholder() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("Optional system instructions..."),
            "Settings should contain the system prompt placeholder text"
        )
    }

    func test_generationSettings_hasColorSchemePicker() {
        let dump = generationSettingsDump()
        XCTAssertTrue(dump.contains("Color Scheme"), "Should contain the Color Scheme picker label")
        XCTAssertTrue(dump.contains("Light"), "Should contain the Light appearance option")
        XCTAssertTrue(dump.contains("Dark"), "Should contain the Dark appearance option")
    }

    func test_generationSettings_hasResetToDefaults() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("Reset to Defaults"),
            "Settings should contain the 'Reset to Defaults' button"
        )
    }

    func test_generationSettings_hasAdvancedSettingsDisclosure() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("Advanced Settings"),
            "Settings should contain the 'Advanced Settings' disclosure group label"
        )
    }

    func test_generationSettings_hasSamplingSection() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("Sampling"),
            "Settings should contain the 'Sampling' section header"
        )
    }

    func test_generationSettings_hasAppearanceSection() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("Appearance"),
            "Settings should contain the 'Appearance' section header"
        )
    }

    // MARK: - GenerationSettingsView — Platform Controls

    #if canImport(AppKit)
    func test_generationSettings_hasSliderControl() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("SystemSlider"),
            "Settings should render a system slider (temperature control)"
        )
    }

    func test_generationSettings_hasTextEditorControl() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("AppKitTextEditorAdaptor"),
            "Settings should render a text editor (system prompt)"
        )
    }

    func test_generationSettings_hasSegmentedControl() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("SystemSegmentedControl"),
            "Settings should render a segmented control (color scheme picker)"
        )
    }

    #endif

    // MARK: - GenerationSettingsView — Advanced Section References

    func test_generationSettings_hasSamplerPresetPicker() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("SamplerPresetPickerView"),
            "Settings should contain the SamplerPresetPickerView type reference"
        )
    }

    func test_generationSettings_hasPersonaPicker() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("PersonaPickerView"),
            "Settings should contain the PersonaPickerView type reference"
        )
    }

    /// The "Debug" → Prompt Inspector row was removed (gap E of the
    /// UI-honesty audit, #2356): it always passed
    /// `PromptInspectorView(assembledPrompt: nil, ...)` because nothing in
    /// the live turn path produces an `AssembledPrompt` — the sheet only
    /// ever showed its empty state. See the seam comment on
    /// `PromptInspectorView` for what real plumbing would need. This test
    /// now asserts the entry point stays gone rather than reappearing
    /// un-wired.
    func test_generationSettings_hasNoPromptInspectorEntryPoint() {
        let dump = generationSettingsDump()
        XCTAssertFalse(
            dump.contains("PromptInspectorView"),
            "Settings should not reference PromptInspectorView until it is wired to a real AssembledPrompt"
        )
    }

    func test_generationSettings_showAdvancedSettingsAppStorage() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("showAdvancedSettings"),
            "Settings should reference the showAdvancedSettings AppStorage key"
        )
    }

    // MARK: - GenerationSettingsView — Diagnostics (issue #2453)

    /// `DiagnosticsDisclosure`'s own doc comment promised embedding in
    /// `GenerationSettingsView` through two prior API-surface sweeps without
    /// ever actually being wired in (#2453 M1 kill-list item 3) — zero call
    /// sites anywhere in the repo. This test pins the embedding live: it
    /// builds a real, hosted, laid-out `GenerationSettingsView` with a
    /// `SessionManagerViewModel` carrying a configured `DiagnosticsService`
    /// (the shape a real bootstrapped app produces — see
    /// `SessionManagerViewModel.configure(bootstrap:)`) and asserts
    /// `DiagnosticsDisclosure` participates in the composed view.
    ///
    /// Named for what it actually checks, not for the realistic setup used to
    /// check it: like the sibling tests above (`test_generationSettings_hasSamplerPresetPicker`
    /// / `_hasPersonaPicker`), `ViewHierarchyDumper.dump` reflects the *type*
    /// of the hosted view's body, which for a `some View` return type is fixed
    /// at compile time across every syntactic branch — so this cannot
    /// distinguish "conditionally shown at these AppStorage/environment
    /// values" from "unconditionally shown". What it verifies, and what
    /// actually matters for #2453 (`DiagnosticsDisclosure` went from
    /// *referenced by zero files* to *compiled into `GenerationSettingsView`'s
    /// view graph*), is reachability: delete the
    /// `if let diagnostics = sessionManager?.diagnostics { DiagnosticsDisclosure(...) }`
    /// line in `GenerationSettingsView.body` and `DiagnosticsDisclosure` no
    /// longer appears anywhere in the type, so this test fails — verified by
    /// hand (temporarily removing that line reproduced the failure) before
    /// this PR. The realistic `SessionManagerViewModel.configure(...)` setup is
    /// kept anyway (over a bare unconfigured `SessionManagerViewModel()`) so
    /// this test also documents the actual shape a bootstrapped host produces.
    func test_generationSettings_compilesDiagnosticsDisclosureIntoBody() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let persistence = SwiftDataPersistenceProvider(modelContext: container.mainContext)
        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false, diagnostics: DiagnosticsService())

        let dump = ViewHierarchyDumper.dump(
            GenerationSettingsView { EmptyView() }
                .environment(makeChatViewModel())
                .environment(sessionManager)
        )

        XCTAssertTrue(
            dump.contains("DiagnosticsDisclosure"),
            "GenerationSettingsView.body should compile in a reference to DiagnosticsDisclosure via the environed SessionManagerViewModel's DiagnosticsService (#2453)"
        )
    }
}
