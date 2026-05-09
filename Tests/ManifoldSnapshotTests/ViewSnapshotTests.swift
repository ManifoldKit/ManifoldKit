import XCTest
import SnapshotTesting
import SwiftUI
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference

/// Snapshot tests for SwiftUI preview configurations.
///
/// Uses the `.dump` text-based strategy which works headless in CI — no simulator
/// or rendering pipeline required. Catches structural regressions (view hierarchy
/// changes, missing data, wrong bindings) without XCUITest overhead.
///
/// Views that require complex environment objects (ChatInputBar, DownloadProgressView,
/// ChatView, model management views) are excluded — they need a full app environment.
/// This covers the self-contained indicator and bubble views (13 of 26 previews).
///
/// On first run, set `recordMode = .all` to generate reference snapshots.
@MainActor
final class ViewSnapshotTests: XCTestCase {

    // Set to .all to record new reference snapshots, then set back to .missing.
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // Fixed identifiers so `.dump` output is deterministic across runs.
    private let fixedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let fixedSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let fixedDate = Date(timeIntervalSinceReferenceDate: 0)

    private func assertDumpSnapshot<V: View>(
        _ view: V,
        named name: String,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        #if canImport(UIKit)
        let vc = UIHostingController(rootView: view)
        #elseif canImport(AppKit)
        let vc = NSHostingController(rootView: view)
        #endif
        assertSnapshot(
            of: vc,
            as: .dump,
            named: name,
            record: recordMode,
            file: file,
            testName: testName,
            line: line
        )
    }

    // MARK: - MessageBubbleView (4 previews)

    func test_messageBubble_userMessage() {
        assertDumpSnapshot(
            MessageBubbleView(
                message: ChatMessageRecord(id: fixedID, role: .user, content: "Hello, tell me a story.", timestamp: fixedDate, sessionID: fixedSessionID),
                isStreaming: false
            ),
            named: "user_message"
        )
    }

    func test_messageBubble_assistantMessage() {
        assertDumpSnapshot(
            MessageBubbleView(
                message: ChatMessageRecord(id: fixedID, role: .assistant, content: "Once upon a time...", timestamp: fixedDate, sessionID: fixedSessionID),
                isStreaming: false
            ),
            named: "assistant_message"
        )
    }

    func test_messageBubble_assistantStreaming() {
        assertDumpSnapshot(
            MessageBubbleView(
                message: ChatMessageRecord(id: fixedID, role: .assistant, content: "Once upon a time...", timestamp: fixedDate, sessionID: fixedSessionID),
                isStreaming: true
            ),
            named: "assistant_streaming"
        )
    }

    func test_messageBubble_systemMessage() {
        assertDumpSnapshot(
            MessageBubbleView(
                message: ChatMessageRecord(id: fixedID, role: .system, content: "You are a creative assistant.", timestamp: fixedDate, sessionID: fixedSessionID),
                isStreaming: false
            ),
            named: "system_message"
        )
    }

    // MARK: - ContextIndicatorView (4 previews)

    func test_contextIndicator_lowUsage() {
        assertDumpSnapshot(
            ContextIndicatorView(usedTokens: 500, maxTokens: 4096),
            named: "low_usage"
        )
    }

    func test_contextIndicator_highUsage() {
        assertDumpSnapshot(
            ContextIndicatorView(usedTokens: 3500, maxTokens: 4096),
            named: "high_usage"
        )
    }

    func test_contextIndicator_critical() {
        assertDumpSnapshot(
            ContextIndicatorView(usedTokens: 3900, maxTokens: 4096),
            named: "critical"
        )
    }

    // MARK: - MemoryIndicatorView (4 previews)

    func test_memoryIndicator_nominal() {
        assertDumpSnapshot(
            MemoryIndicatorView(
                pressureLevel: .nominal,
                physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
                appMemoryBytes: 432 * 1024 * 1024
            ),
            named: "nominal"
        )
    }

    func test_memoryIndicator_warning() {
        assertDumpSnapshot(
            MemoryIndicatorView(
                pressureLevel: .warning,
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
                appMemoryBytes: 5_800 * 1024 * 1024
            ),
            named: "warning"
        )
    }

    func test_memoryIndicator_critical() {
        assertDumpSnapshot(
            MemoryIndicatorView(
                pressureLevel: .critical,
                physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
                appMemoryBytes: 5_900 * 1024 * 1024
            ),
            named: "critical"
        )
    }

    func test_memoryIndicator_noAppUsage() {
        assertDumpSnapshot(
            MemoryIndicatorView(
                pressureLevel: .nominal,
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
                appMemoryBytes: nil
            ),
            named: "no_app_usage"
        )
    }

    // MARK: - AssistantMarkdownView (3 snapshots)

    func test_assistantMarkdown_plainText() {
        assertDumpSnapshot(
            AssistantMarkdownView(content: "Once upon a time in a land far away..."),
            named: "plain_text"
        )
    }

    func test_assistantMarkdown_withCodeBlock() {
        assertDumpSnapshot(
            AssistantMarkdownView(content: "Here's an example:\n\n```swift\nlet x = 42\nprint(x)\n```\n\nThat's how it works."),
            named: "with_code_block"
        )
    }

    func test_assistantMarkdown_withFormatting() {
        assertDumpSnapshot(
            AssistantMarkdownView(content: "This is **bold** and *italic* and a [link](https://example.com)."),
            named: "with_formatting"
        )
    }

    // MARK: - MessagePartsView (1 snapshot)

    func test_messageParts_textOnly() {
        assertDumpSnapshot(
            MessagePartsView(parts: [.text("Hello world")], role: .assistant),
            named: "text_only"
        )
    }

    // MARK: - StreamingCursorView (1 snapshot)

    func test_streamingCursor() {
        assertDumpSnapshot(
            StreamingCursorView(),
            named: "default"
        )
    }

    // MARK: - TypingIndicatorView (1 snapshot)

    func test_typingIndicator() {
        assertDumpSnapshot(
            TypingIndicatorView(),
            named: "default"
        )
    }

    // MARK: - ModelLoadingIndicatorView (2 snapshots)

    func test_modelLoadingIndicator_indeterminate() {
        assertDumpSnapshot(
            ModelLoadingIndicatorView(),
            named: "indeterminate"
        )
    }

    func test_modelLoadingIndicator_withProgress() {
        assertDumpSnapshot(
            ModelLoadingIndicatorView(progress: 0.65),
            named: "with_progress"
        )
    }

    // MARK: - SessionRowView (2 snapshots)

    func test_sessionRow_recent() {
        assertDumpSnapshot(
            SessionRowView(session: ChatSessionRecord(
                id: fixedID,
                title: "Travel Planning",
                createdAt: fixedDate,
                updatedAt: fixedDate
            )),
            named: "recent"
        )
    }

    func test_sessionRow_longTitle() {
        assertDumpSnapshot(
            SessionRowView(session: ChatSessionRecord(
                id: fixedID,
                title: "This is a really long chat title that should be truncated in the row view",
                createdAt: fixedDate,
                updatedAt: fixedDate
            )),
            named: "long_title"
        )
    }

    // MARK: - WhyDownloadView (1 preview)

    func test_whyDownloadView() {
        assertDumpSnapshot(
            WhyDownloadView()
                .environment(ModelManagementViewModel()),
            named: "why_download"
        )
    }
}
