import XCTest
import SwiftUI
import SwiftData
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference

/// Verifies that user-facing controls in SessionListView, ChatExportSheet,
/// and APIConfigurationView are present in the view hierarchy.
///
/// Uses `Swift.dump()` to capture the hosting controller's hierarchy as text,
/// then asserts expected labels/buttons appear. This catches accidental removal
/// of controls without requiring pixel rendering or XCUITest infrastructure.
///
/// Toolbar items, navigation titles, and system image names are embedded in
/// SwiftUI's internal type signatures rather than appearing as literal strings,
/// so those are verified by checking for their type-level representation
/// (e.g. `ToolbarItem`, `NavigationTitleKey`, `ShareLink`).
@MainActor
final class SidebarAndSheetControlTests: XCTestCase {

    // MARK: - Helpers

    private func makeChatViewModel() -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * 1_024 * 1_024 * 1_024),
            modelStorage: ModelStorageService(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainerFactory.makeInMemoryContainer()
    }

    // MARK: - SessionListView: Empty State

    func test_sessionListView_emptyState_showsNoChatsLabel() {
        let dump = ViewHierarchyDumper.dump(
            SessionListView()
                .environment(SessionManagerViewModel())
        )

        XCTAssertTrue(
            dump.contains("No Chats"),
            "Empty SessionListView must show \"No Chats\" label"
        )
    }

    func test_sessionListView_emptyState_showsTapPlusHint() {
        let dump = ViewHierarchyDumper.dump(
            SessionListView()
                .environment(SessionManagerViewModel())
        )

        XCTAssertTrue(
            dump.contains("Tap the + button"),
            "Empty SessionListView must show the \"Tap the + button\" hint"
        )
    }

    func test_sessionListView_emptyState_doesNotShowList() {
        let dump = ViewHierarchyDumper.dump(
            SessionListView()
                .environment(SessionManagerViewModel())
        )

        // When empty, SessionListView shows ContentUnavailableView instead of a List.
        // SessionRowView should not appear in the hierarchy.
        XCTAssertFalse(
            dump.contains("SessionRowView"),
            "Empty SessionListView must not contain any SessionRowView"
        )
    }

    // MARK: - SessionListView: With Sessions

    func test_sessionListView_withSessions_showsSessionRows() async throws {
        let container = try makeInMemoryContainer()
        let persistence = SwiftDataPersistenceProvider(modelContext: container.mainContext)
        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
        try await sessionManager.createSession(title: "Test Chat Session")

        let dump = ViewHierarchyDumper.dump(
            SessionListView()
                .environment(sessionManager)
        )

        XCTAssertTrue(
            dump.contains("Test Chat Session"),
            "SessionListView with sessions must render session title"
        )
    }

    func test_sessionListView_withSessions_showsList() async throws {
        let container = try makeInMemoryContainer()
        let persistence = SwiftDataPersistenceProvider(modelContext: container.mainContext)
        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
        try await sessionManager.createSession(title: "Session Alpha")
        try await sessionManager.createSession(title: "Session Beta")

        let dump = ViewHierarchyDumper.dump(
            SessionListView()
                .environment(sessionManager)
        )

        XCTAssertTrue(
            dump.contains("Session Alpha"),
            "SessionListView must show first session"
        )
        XCTAssertTrue(
            dump.contains("Session Beta"),
            "SessionListView must show second session"
        )
    }

    func test_sessionListView_withSessions_containsSessionRowView() async throws {
        let container = try makeInMemoryContainer()
        let persistence = SwiftDataPersistenceProvider(modelContext: container.mainContext)
        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
        try await sessionManager.createSession(title: "Any Session")

        let dump = ViewHierarchyDumper.dump(
            SessionListView()
                .environment(sessionManager)
        )

        XCTAssertTrue(
            dump.contains("SessionRowView"),
            "SessionListView with sessions must contain SessionRowView"
        )
    }

    // `.contextMenu` content closures are evaluated lazily by SwiftUI
    // (on long-press/right-click) — they never materialize in
    // ViewHierarchyDumper's static NSHostingController snapshot of the full
    // row (verified: a full-row dump is byte-identical whether or not the
    // gate is open, aside from incidental SwiftData ordering/UUIDs). So the
    // `showChatExport` gate is tested by dumping `exportButton(for:)` in
    // isolation, which `SessionListView` exposes at `internal` visibility
    // for exactly this purpose.
    func test_sessionListView_exportButton_hiddenWhenShowChatExportDisabled() {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }
        var configuration = originalConfiguration
        configuration.features.showChatExport = false
        ManifoldConfiguration.shared = configuration

        let session = ChatSession(id: UUID(), title: "Locked Down Session")
        let dump = ViewHierarchyDumper.dump(SessionListView().exportButton(for: session))

        XCTAssertFalse(
            dump.contains("\"Export\""),
            "Sidebar export button must not render when showChatExport is false"
        )
    }

    func test_sessionListView_exportButton_shownWhenShowChatExportEnabled() {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }
        var configuration = originalConfiguration
        configuration.features.showChatExport = true
        ManifoldConfiguration.shared = configuration

        let session = ChatSession(id: UUID(), title: "Unlocked Session")
        let dump = ViewHierarchyDumper.dump(SessionListView().exportButton(for: session))

        XCTAssertTrue(
            dump.contains("\"Export\""),
            "Sidebar export button must render when showChatExport is true"
        )
    }

    // MARK: - ChatExportSheet: Form Content

    func test_chatExportSheet_showsFormatSection() {
        let vm = makeChatViewModel()

        let dump = ViewHierarchyDumper.dump(
            ChatExportSheet()
                .environment(vm)
        )

        XCTAssertTrue(
            dump.contains("Format"),
            "ChatExportSheet must contain the Format section"
        )
    }

    func test_chatExportSheet_showsMarkdownOption() {
        let vm = makeChatViewModel()

        let dump = ViewHierarchyDumper.dump(
            ChatExportSheet()
                .environment(vm)
        )

        XCTAssertTrue(
            dump.contains("Markdown"),
            "ChatExportSheet must list Markdown as an export format"
        )
    }

    func test_chatExportSheet_showsPlainTextOption() {
        let vm = makeChatViewModel()

        let dump = ViewHierarchyDumper.dump(
            ChatExportSheet()
                .environment(vm)
        )

        XCTAssertTrue(
            dump.contains("Plain Text"),
            "ChatExportSheet must list Plain Text as an export format"
        )
    }

    func test_chatExportSheet_showsPreviewSection() {
        let vm = makeChatViewModel()

        let dump = ViewHierarchyDumper.dump(
            ChatExportSheet()
                .environment(vm)
        )

        XCTAssertTrue(
            dump.contains("Preview"),
            "ChatExportSheet must have a Preview section"
        )
    }

    func test_chatExportSheet_usesSegmentedPicker() {
        let vm = makeChatViewModel()

        let dump = ViewHierarchyDumper.dump(
            ChatExportSheet()
                .environment(vm)
        )

        XCTAssertTrue(
            dump.contains("SegmentedPickerStyle"),
            "ChatExportSheet format picker must use segmented style"
        )
    }

    func test_chatExportSheet_containsShareLink() {
        let vm = makeChatViewModel()

        let dump = ViewHierarchyDumper.dump(
            ChatExportSheet()
                .environment(vm)
        )

        // ShareLink appears in the type signature within the dump
        XCTAssertTrue(
            dump.contains("ShareLink"),
            "ChatExportSheet must contain a ShareLink for exporting"
        )
    }

    func test_chatExportSheet_containsToolbarItems() {
        let vm = makeChatViewModel()

        let dump = ViewHierarchyDumper.dump(
            ChatExportSheet()
                .environment(vm)
        )

        // Toolbar items appear as SwiftUI.ToolbarItem in the type hierarchy
        XCTAssertTrue(
            dump.contains("ToolbarItem"),
            "ChatExportSheet must have toolbar items (Cancel + Share)"
        )
    }

    func test_chatExportSheet_containsNavigationTitle() {
        let vm = makeChatViewModel()

        let dump = ViewHierarchyDumper.dump(
            ChatExportSheet()
                .environment(vm)
        )

        XCTAssertTrue(
            dump.contains("NavigationTitleKey"),
            "ChatExportSheet must set a navigation title"
        )
    }

    // MARK: - SessionExportSheet: Form Content

    private func makeSessionExportSheetDump() -> String {
        ViewHierarchyDumper.dump(
            SessionExportSheet(session: ChatSession(id: UUID(), title: "Preview Chat"))
                .environment(SessionManagerViewModel())
        )
    }

    func test_sessionExportSheet_showsFormatSection() {
        XCTAssertTrue(
            makeSessionExportSheetDump().contains("Format"),
            "SessionExportSheet must contain the Format section"
        )
    }

    func test_sessionExportSheet_showsMarkdownOption() {
        XCTAssertTrue(
            makeSessionExportSheetDump().contains("Markdown"),
            "SessionExportSheet must list Markdown as an export format"
        )
    }

    func test_sessionExportSheet_showsPlainTextOption() {
        XCTAssertTrue(
            makeSessionExportSheetDump().contains("Plain Text"),
            "SessionExportSheet must list Plain Text as an export format"
        )
    }

    func test_sessionExportSheet_showsJSONLOption() {
        // Labeled "JSONL" (not "JSON") — the option is backed by
        // JSONLExportFormat and produces a `.jsonl` file, so the label must
        // say so rather than implying a single JSON document.
        XCTAssertTrue(
            makeSessionExportSheetDump().contains("JSONL"),
            "SessionExportSheet must list JSONL as an export format"
        )
    }

    func test_sessionExportSheet_usesSegmentedPicker() {
        XCTAssertTrue(
            makeSessionExportSheetDump().contains("SegmentedPickerStyle"),
            "SessionExportSheet format picker must use segmented style"
        )
    }

    func test_sessionExportSheet_containsToolbarItems() {
        XCTAssertTrue(
            makeSessionExportSheetDump().contains("ToolbarItem"),
            "SessionExportSheet must have toolbar items (Cancel + Share)"
        )
    }

    func test_sessionExportSheet_containsNavigationTitle() {
        XCTAssertTrue(
            makeSessionExportSheetDump().contains("NavigationTitleKey"),
            "SessionExportSheet must set a navigation title"
        )
    }

    func test_sessionExportSheet_showsProgressViewWhileExportPending() {
        // The file write is async I/O (unlike ChatExportSheet's synchronous
        // in-memory string export), so at initial layout — before the
        // `.task` has a chance to complete — the sheet must show a
        // ProgressView rather than a ShareLink for a not-yet-ready file.
        XCTAssertTrue(
            makeSessionExportSheetDump().contains("ProgressView"),
            "SessionExportSheet must show a ProgressView before the export completes"
        )
    }

    // MARK: - APIConfigurationView: Empty State

    func test_apiConfigurationView_emptyState_showsNoneConfiguredMessage() throws {
        let container = try makeInMemoryContainer()

        let dump = ViewHierarchyDumper.dump(
            APIConfigurationView()
                .modelContainer(container)
        )

        XCTAssertTrue(
            dump.contains("No cloud APIs configured"),
            "APIConfigurationView with no endpoints must show empty state text"
        )
    }

    func test_apiConfigurationView_showsAddEndpointButton() throws {
        let container = try makeInMemoryContainer()

        let dump = ViewHierarchyDumper.dump(
            APIConfigurationView()
                .modelContainer(container)
        )

        XCTAssertTrue(
            dump.contains("Add Endpoint"),
            "APIConfigurationView must have an \"Add Endpoint\" button"
        )
    }

    func test_apiConfigurationView_showsEndpointsSection() throws {
        let container = try makeInMemoryContainer()

        let dump = ViewHierarchyDumper.dump(
            APIConfigurationView()
                .modelContainer(container)
        )

        XCTAssertTrue(
            dump.contains("Endpoints"),
            "APIConfigurationView must have an \"Endpoints\" section header"
        )
    }

    func test_apiConfigurationView_showsPrivacyWarningText() throws {
        let container = try makeInMemoryContainer()

        let dump = ViewHierarchyDumper.dump(
            APIConfigurationView()
                .modelContainer(container)
        )

        XCTAssertTrue(
            dump.contains("external servers"),
            "APIConfigurationView must show the privacy warning about external servers"
        )
    }

    func test_apiConfigurationView_containsToolbarItem() throws {
        let container = try makeInMemoryContainer()

        let dump = ViewHierarchyDumper.dump(
            APIConfigurationView()
                .modelContainer(container)
        )

        // The Done button is a ToolbarItem in the type hierarchy
        XCTAssertTrue(
            dump.contains("ToolbarItem"),
            "APIConfigurationView must have a toolbar item (Done button)"
        )
    }

    func test_apiConfigurationView_containsNavigationTitle() throws {
        let container = try makeInMemoryContainer()

        let dump = ViewHierarchyDumper.dump(
            APIConfigurationView()
                .modelContainer(container)
        )

        XCTAssertTrue(
            dump.contains("NavigationTitleKey"),
            "APIConfigurationView must set a navigation title"
        )
    }

    func test_apiConfigurationView_usesNavigationStack() throws {
        let container = try makeInMemoryContainer()

        let dump = ViewHierarchyDumper.dump(
            APIConfigurationView()
                .modelContainer(container)
        )

        XCTAssertTrue(
            dump.contains("NavigationStack"),
            "APIConfigurationView must be wrapped in a NavigationStack"
        )
    }

}
