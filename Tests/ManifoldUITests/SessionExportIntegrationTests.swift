@preconcurrency import XCTest
import SwiftData
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
@testable import ManifoldUI
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// Integration test: drives ``SessionManagerViewModel/exportSession(_:format:directory:)``
/// end-to-end against a real in-memory SwiftData store — creates a session,
/// inserts real messages via `MessageStore`, exports through each built-in
/// ``ConversationExportFormat``, and verifies the file that lands on disk.
///
/// This is the wiring test for the previously-inert rich file-based export
/// pipeline (``ConversationExporter``): ``ChatExportIntegrationTests`` covers
/// the live but narrower toolbar path (Pipeline A, `ChatExportService`); this
/// file covers the per-session sidebar path (Pipeline B).
@MainActor
final class SessionExportIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var persistence: SwiftDataPersistenceProvider!
    private var sessionManager: SessionManagerViewModel!

    /// Every export writes into a unique temp subdirectory; track them here
    /// so tearDown can remove them regardless of which test wrote what.
    private var writtenDirectories: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        persistence = SwiftDataPersistenceProvider(modelContext: context)
        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
    }

    override func tearDown() async throws {
        for dir in writtenDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        writtenDirectories = []
        sessionManager = nil
        persistence = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func seedSession(
        title: String = "Export Test Session",
        turns: [(role: MessageRole, content: String)] = [
            (.user, "Hello"),
            (.assistant, "Hi there!")
        ]
    ) async throws -> ManifoldInference.ChatSession {
        let session = try await sessionManager.createSession(title: title)
        for (offset, turn) in turns.enumerated() {
            let message = ChatMessage(
                role: turn.role,
                content: turn.content,
                timestamp: Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(TimeInterval(offset)),
                sessionID: session.id
            )
            try await persistence.insertMessage(message)
        }
        return session
    }

    private func track(_ file: ShareableFile) {
        writtenDirectories.append(file.url.deletingLastPathComponent())
    }

    func test_exportSession_includesHistoryBeyondTenThousandRows() async throws {
        let session = try await sessionManager.createSession(title: "Complete export")
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let messages = (0...10_000).map { index in
            ChatMessage(role: .user, content: "row-\(index)", timestamp: base.addingTimeInterval(Double(index)), sessionID: session.id)
        }
        try await persistence.performMessageMutations(messages.map(MessageStoreMutation.insert))

        let file = try await sessionManager.exportSession(session, format: JSONLExportFormat())
        track(file)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, messages.count)
        let contents = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }.map { $0["content"] as! String }
        XCTAssertEqual(contents, messages.map(\.content))
    }

    // MARK: - Markdown

    func test_exportSession_markdown_writesRealFileWithFetchedMessages() async throws {
        let session = try await seedSession(title: "Story Time")

        let file = try await sessionManager.exportSession(session, format: MarkdownExportFormat())
        track(file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), "Export must write a real file to disk")
        XCTAssertTrue(file.suggestedFilename.hasSuffix(".md"))

        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Story Time"), "Markdown export should start with H1 title")
        XCTAssertTrue(text.contains("**User:**"))
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("**Assistant:**"))
        XCTAssertTrue(text.contains("Hi there!"))
    }

    // MARK: - Plain text

    func test_exportSession_plainText_writesRealFileWithFetchedMessages() async throws {
        let session = try await seedSession(title: "Casual Chat")

        let file = try await sessionManager.exportSession(session, format: PlainTextExportFormat())
        track(file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(file.suggestedFilename.hasSuffix(".txt"))

        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Casual Chat"))
        XCTAssertTrue(text.contains("User:"))
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("Assistant:"))
        XCTAssertTrue(text.contains("Hi there!"))
        XCTAssertFalse(text.contains("**User:**"), "Plain-text export must not leak Markdown syntax")
    }

    // MARK: - JSON (JSONL)

    func test_exportSession_json_writesRealFileWithFetchedMessages() async throws {
        let session = try await seedSession(title: "JSON Chat")

        let file = try await sessionManager.exportSession(session, format: JSONLExportFormat())
        track(file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(file.suggestedFilename.hasSuffix(".jsonl"))

        let text = try String(contentsOf: file.url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "Two visible messages should produce two JSONL lines")

        let firstLineData = try XCTUnwrap(lines.first?.data(using: .utf8))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: firstLineData) as? [String: Any]
        )
        XCTAssertEqual(decoded["role"] as? String, "user")
        XCTAssertEqual(decoded["content"] as? String, "Hello")
        XCTAssertNotNil(decoded["timestamp"])
    }

    // MARK: - Filename sanitization passthrough

    func test_exportSession_filenameDerivedFromSanitizedSessionTitle() async throws {
        let session = try await seedSession(title: "Weird/Title:With*Chars")

        let file = try await sessionManager.exportSession(session, format: MarkdownExportFormat())
        track(file)

        XCTAssertFalse(file.suggestedFilename.contains("/"), "Sanitized filename must not contain a path separator")
        XCTAssertFalse(file.suggestedFilename.contains(":"), "Sanitized filename must not contain a colon")
        XCTAssertFalse(file.suggestedFilename.contains("*"), "Sanitized filename must not contain an asterisk")
        XCTAssertTrue(file.suggestedFilename.hasSuffix(".md"))
    }

    // MARK: - Error path

    func test_exportSession_throwsWhenPersistenceNotConfigured() async throws {
        let unconfigured = SessionManagerViewModel()
        let session = ManifoldInference.ChatSession(id: UUID(), title: "Orphan")

        do {
            _ = try await unconfigured.exportSession(session, format: MarkdownExportFormat())
            XCTFail("exportSession must throw before persistence is configured")
        } catch let error as ChatPersistenceError {
            XCTAssertEqual(error, .providerNotConfigured)
        }
    }

    // MARK: - Repeated export cleanup (regression: SessionExportSheet's
    // `.task(id: selectedFormat)` re-runs `performExport()` on every format
    // switch — before the fix, each re-run overwrote `exportedFile` without
    // calling `cleanup()` on the previous one, orphaning a
    // `ManifoldKit-export-<uuid>/` temp directory per switch.
    //
    // Two tests, because neither alone pins the fix:
    //  - `test_cleanupBeforeReplace_mechanismLeavesNoOrphanedDirectory`
    //    proves the underlying primitive (`ShareableFile.cleanup()` called
    //    before starting the next export) actually prevents the leak — but
    //    it drives `sessionManager.exportSession` directly and calls
    //    `cleanup()` itself, so it would stay green even if
    //    `SessionExportSheet.performExport()` never called it (verified:
    //    reverting the one-line fix in `performExport()` and re-running
    //    this test leaves it passing).
    //  - `test_performExport_sourceCallsCleanupBeforeReplacingExportedFile`
    //    closes that gap with a source-scanning audit that fails if
    //    `performExport()`'s `cleanupExportedFile()` call is removed or
    //    reordered after `exportedFile` is reassigned (verified: reverting
    //    the fix makes THIS test fail, with a clear message).
    //
    // A real behavioral test was attempted first, via ViewInspector's
    // `callTask(id:)` (ViewInspector 0.10.3 is already a project dependency,
    // wired into this exact target — see `Package.swift`). It genuinely
    // drives `.task(id:)` closures rather than re-implementing them, and is
    // used elsewhere in this file's sibling suite (`ChatShellStateScreenWiringTests`)
    // for tap/binding-driven wiring tests. It does not work here: both
    // `sheet.inspect().find(ViewType.Form.self)` and the direct
    // `sheet.inspect().navigationStack().form()` accessor throw
    // `InspectionError: Form<...> does not have 'task' modifier` when asked
    // to locate the exact `.task(id: selectedFormat)` modifier
    // `SessionExportSheet` chains onto its `Form` — even though that
    // modifier is unambiguously present in the source one line above
    // `.onDisappear`. ViewInspector works by string-matching SwiftUI's
    // private modifier type names (e.g. `_TaskValueModifier<Value>`); the
    // likely cause is a naming/structure mismatch between what 0.10.3
    // expects and the modifier shape actually emitted by the installed
    // macOS 26 / Swift 6.3 SDK, which is a version-compatibility gap in the
    // dependency, not something fixable from this test file. So: a
    // source-scanning audit, honestly labelled as one — it pins *textual
    // ordering in source*, so it would pass if the cleanup call sat in a
    // dead branch, and it can break on a benign refactor that moves the
    // call into a helper. Revisit if/when ViewInspector is bumped past
    // 0.10.3 and this gap might have closed.

    func test_cleanupBeforeReplace_mechanismLeavesNoOrphanedDirectory() async throws {
        let session = try await seedSession(title: "Switch Formats")

        let markdownFile = try await sessionManager.exportSession(session, format: MarkdownExportFormat())
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownFile.url.path))
        let markdownDirectory = try XCTUnwrap(markdownFile.ownedDirectory)

        // Mirrors `SessionExportSheet.performExport()`: clean up the
        // in-flight file before starting the next export.
        markdownFile.cleanup()

        let plainTextFile = try await sessionManager.exportSession(session, format: PlainTextExportFormat())
        track(plainTextFile)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markdownDirectory.path),
            "Switching formats must not leave the previous export's temp directory behind"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plainTextFile.url.path),
            "The newly selected format's export must still land on disk"
        )
    }

    func test_performExport_sourceCallsCleanupBeforeReplacingExportedFile() throws {
        let source = try String(contentsOf: try Self.locateSessionExportSheetSource(), encoding: .utf8)

        guard let funcRange = source.range(of: "private func performExport() async {") else {
            XCTFail("Could not locate performExport() in SessionExportSheet.swift — did it get renamed?")
            return
        }
        guard let bodyEndRange = source.range(of: "\n    }", range: funcRange.upperBound..<source.endIndex) else {
            XCTFail("Could not locate the end of performExport()'s body")
            return
        }
        let body = source[funcRange.upperBound..<bodyEndRange.lowerBound]

        guard let cleanupRange = body.range(of: "cleanupExportedFile()") else {
            XCTFail(
                "performExport() no longer calls cleanupExportedFile() — this reopens the leak where every " +
                "format-picker switch orphans a ManifoldKit-export-<uuid>/ temp directory"
            )
            return
        }
        guard let replaceRange = body.range(of: "exportedFile = nil") else {
            XCTFail("performExport() no longer resets exportedFile — test assumption stale, update this audit")
            return
        }
        XCTAssertLessThan(
            cleanupRange.lowerBound,
            replaceRange.lowerBound,
            "cleanupExportedFile() must run BEFORE exportedFile is reassigned — cleaning up after handing out " +
            "a fresh exportedFile would clean up the wrong (new) file, not the orphaned previous one"
        )
    }

    /// Walks up from `#filePath` to the repo root (marked by `Package.swift`)
    /// then down to the source file under audit. Mirrors the upwalk pattern
    /// other audit tests in this repo use (e.g. `FixtureRedactionAuditTest`)
    /// so this works regardless of invocation cwd.
    private static func locateSessionExportSheetSource(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir.appendingPathComponent("Sources/ManifoldUI/Views/Sidebar/SessionExportSheet.swift")
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "SessionExportIntegrationTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root (Package.swift) from #filePath"
        ])
    }

    // MARK: - Not limited to the active session

    func test_exportSession_worksForNonActiveSession() async throws {
        let active = try await seedSession(title: "Active Session", turns: [(.user, "hi")])
        let other = try await seedSession(title: "Other Session", turns: [(.user, "bonjour")])
        sessionManager.activeSession = active

        let file = try await sessionManager.exportSession(other, format: PlainTextExportFormat())
        track(file)

        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertTrue(text.contains("bonjour"), "Export must use the passed session's messages, not the active one's")
        XCTAssertFalse(text.contains("Active Session"))
    }
}
