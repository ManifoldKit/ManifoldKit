import XCTest
import SwiftUI
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

    // MARK: - ModelManagementSheet — Tab Structure

    private func modelManagementDump(tab: ModelManagementSheet.Tab = .select) -> String {
        let chatVM = makeChatViewModel()
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

    func test_generationSettings_hasPromptInspectorView() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("PromptInspectorView"),
            "Settings should contain the PromptInspectorView type reference"
        )
    }

    func test_generationSettings_showAdvancedSettingsAppStorage() {
        let dump = generationSettingsDump()
        XCTAssertTrue(
            dump.contains("showAdvancedSettings"),
            "Settings should reference the showAdvancedSettings AppStorage key"
        )
    }
}
