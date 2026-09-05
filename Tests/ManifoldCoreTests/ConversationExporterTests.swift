import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// Tests for ``ConversationExporter`` — file output, filename sanitization,
/// and the SwiftData-fetching convenience overload.
///
/// Classified integration where we drive the persistence harness, unit
/// elsewhere.
@MainActor
/// Integration coverage uses real SwiftData; existing lower-level cases stay in this suite.
final class ConversationExporterIntegrationTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationExporterIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        stack = nil
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Pure path

    func test_export_writesFileWithExpectedExtension() throws {
        let session = ManifoldInference.ChatSession(title: "Hello")
        let file = try ConversationExporter.export(
            session: session,
            messages: [ManifoldInference.ChatMessage(role: .user, content: "hi", sessionID: session.id)],
            format: MarkdownExportFormat(),
            directory: tempDir
        )

        XCTAssertTrue(file.suggestedFilename.hasSuffix(".md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func test_export_fileContentsMatchFormatOutput() throws {
        let format = MarkdownExportFormat()
        let session = ManifoldInference.ChatSession(title: "RoundTrip")
        let messages = [
            ManifoldInference.ChatMessage(role: .user, content: "Q?", sessionID: session.id),
            ManifoldInference.ChatMessage(role: .assistant, content: "A!", sessionID: session.id)
        ]

        let file = try ConversationExporter.export(
            session: session,
            messages: messages,
            format: format,
            directory: tempDir
        )

        let onDisk = try Data(contentsOf: file.url)
        let direct = try format.export(session: session, messages: messages)

        // The export footer embeds a wall-clock "*Exported: <now>*"
        // line, so two exports that straddle a clock boundary differ in
        // that line alone — a race this test lost on parallel CI (equal
        // length, different bytes). Compare with the volatile line
        // normalized, and assert both sides actually carry exactly one
        // such line so the normalization can't mask a missing header.
        func normalized(_ data: Data) throws -> (stable: [String], exportedLines: Int) {
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            let lines = text.components(separatedBy: "\n")
            let volatile = lines.filter { $0.hasPrefix("*Exported: ") }
            return (lines.filter { !$0.hasPrefix("*Exported: ") }, volatile.count)
        }
        let disk = try normalized(onDisk)
        let mem = try normalized(direct)
        XCTAssertEqual(disk.stable, mem.stable)
        XCTAssertEqual(disk.exportedLines, 1)
        XCTAssertEqual(mem.exportedLines, 1)
    }

    func test_export_returnsContentTypeFromFormat() throws {
        let session = ManifoldInference.ChatSession(title: "ct")
        let file = try ConversationExporter.export(
            session: session,
            messages: [],
            format: JSONLExportFormat(),
            directory: tempDir
        )
        XCTAssertEqual(file.contentType.identifier, "public.json")
    }

    // MARK: - Filename sanitization

    func test_sanitiseStem_replacesPathSeparators() {
        XCTAssertFalse(ConversationExporter.sanitiseStem("a/b\\c").contains("/"))
        XCTAssertFalse(ConversationExporter.sanitiseStem("a/b\\c").contains("\\"))
    }

    func test_sanitiseStem_replacesControlCharacters() {
        XCTAssertFalse(ConversationExporter.sanitiseStem("hello\nworld").contains("\n"))
        XCTAssertFalse(ConversationExporter.sanitiseStem("hello\u{0007}bell").contains("\u{0007}"))
    }

    func test_sanitiseStem_fallsBackToChatWhenEmpty() {
        XCTAssertEqual(ConversationExporter.sanitiseStem(""), "chat")
        XCTAssertEqual(ConversationExporter.sanitiseStem("   \n\t  "), "chat")
    }

    func test_sanitiseStem_capsByUTF8ByteLength() {
        // ASCII: byte-count == grapheme-count, capped at 200 bytes.
        let asciiLong = String(repeating: "x", count: 500)
        XCTAssertEqual(ConversationExporter.sanitiseStem(asciiLong).utf8.count, 200)

        // Multi-byte: 4-byte emoji must stay below the 200-byte ceiling and
        // never split mid-scalar. 100 raccoons is 400 UTF-8 bytes raw.
        let emojiLong = String(repeating: "🦊", count: 100)
        let stem = ConversationExporter.sanitiseStem(emojiLong)
        XCTAssertLessThanOrEqual(stem.utf8.count, 200)
        // Re-decoding from UTF-8 must succeed — no truncation in the middle of a scalar.
        let bytes = Data(stem.utf8)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), stem)
    }

    func test_sanitiseFileExtension_stripsPathTraversal() {
        XCTAssertEqual(ConversationExporter.sanitiseFileExtension("../etc"), "etc")
        XCTAssertEqual(ConversationExporter.sanitiseFileExtension("md/secret"), "mdsecret")
        XCTAssertEqual(ConversationExporter.sanitiseFileExtension(".hidden"), "hidden")
    }

    func test_sanitiseFileExtension_fallsBackOnEmpty() {
        XCTAssertEqual(ConversationExporter.sanitiseFileExtension(""), "txt")
        XCTAssertEqual(ConversationExporter.sanitiseFileExtension("///"), "txt")
        XCTAssertEqual(ConversationExporter.sanitiseFileExtension("..."), "txt")
    }

    func test_sanitisedFilename_doesNotEscapeDirectory() {
        let session = ManifoldInference.ChatSession(title: "demo")
        let name = ConversationExporter.sanitisedFilename(for: session, fileExtension: "../evil")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
    }

    func test_sanitisedFilename_appendsExtension() {
        let session = ManifoldInference.ChatSession(title: "demo")
        let name = ConversationExporter.sanitisedFilename(for: session, fileExtension: "jsonl")
        XCTAssertEqual(name, "demo.jsonl")
    }

    // MARK: - ShareableFile.cleanup() ownership

    /// The default (no `directory:` override) path mints its own temp
    /// subdirectory — `cleanup()` must remove that whole directory, not just
    /// the file, so the caller doesn't leak an empty `ManifoldKit-export-*`
    /// directory into `tmp` on every export.
    func test_cleanup_removesExporterOwnedTempDirectory() throws {
        let session = ManifoldInference.ChatSession(title: "owned")
        let file = try ConversationExporter.export(
            session: session,
            messages: [ManifoldInference.ChatMessage(role: .user, content: "hi", sessionID: session.id)],
            format: MarkdownExportFormat(),
            directory: nil
        )
        let ownedDirectory = try XCTUnwrap(file.ownedDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedDirectory.path))

        file.cleanup()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ownedDirectory.path),
            "cleanup() should remove the exporter-minted temp directory"
        )
    }

    /// The important case: when a caller passes their own `directory:`, the
    /// exporter does not own that directory's lifecycle, so `cleanup()` must
    /// leave it standing — a no-op implementation of `cleanup()` (or the old
    /// `deletingLastPathComponent()` idiom) would delete it and fail this.
    func test_cleanup_doesNotDeleteCallerSuppliedDirectory() throws {
        let session = ManifoldInference.ChatSession(title: "caller-owned")
        let sibling = tempDir.appendingPathComponent("sibling.txt", isDirectory: false)
        try Data("keep me".utf8).write(to: sibling)

        let file = try ConversationExporter.export(
            session: session,
            messages: [ManifoldInference.ChatMessage(role: .user, content: "hi", sessionID: session.id)],
            format: MarkdownExportFormat(),
            directory: tempDir
        )
        XCTAssertNil(file.ownedDirectory, "caller-supplied directory must not be reported as exporter-owned")

        file.cleanup()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempDir.path),
            "cleanup() must not remove a directory the caller supplied"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sibling.path),
            "cleanup() must not touch other files the caller left in their own directory"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.url.path),
            "cleanup() should still remove the exported file itself"
        )
    }

    // MARK: - SwiftData convenience overload

    func test_export_viaPersistenceProvider_fetchesMessagesInOrder() async throws {
        let session = PersistedChatSession(title: "Provider Path")
        stack.context.insert(session)
        try stack.context.save()

        // Insert messages out of order to verify the exporter relies on
        // the provider's chronological sort, not raw fetch order.
        let later = ManifoldInference.ChatMessage(
            role: .assistant,
            content: "second",
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            sessionID: session.id
        )
        let earlier = ManifoldInference.ChatMessage(
            role: .user,
            content: "first",
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            sessionID: session.id
        )
        try await stack.provider.insertMessage(later)
        try await stack.provider.insertMessage(earlier)

        let file = try await ConversationExporter.export(
            session: session,
            format: MarkdownExportFormat(),
            provider: stack.provider,
            directory: tempDir
        )

        let text = try String(contentsOf: file.url, encoding: .utf8)
        let firstRange = try XCTUnwrap(text.range(of: "first"))
        let secondRange = try XCTUnwrap(text.range(of: "second"))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
    }

    func test_export_viaPersistenceProvider_includesHistoryBeyondTenThousandRows() async throws {
        let session = PersistedChatSession(title: "Complete export")
        stack.context.insert(session)
        try stack.context.save()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let messages = (0...10_000).map { index in
            ManifoldInference.ChatMessage(role: .user, content: "row-\(index)", timestamp: base.addingTimeInterval(Double(index)), sessionID: session.id)
        }
        try await stack.provider.performMessageMutations(messages.map(MessageStoreMutation.insert))

        let file = try await ConversationExporter.export(session: session, format: JSONLExportFormat(), provider: stack.provider, directory: tempDir)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, messages.count)
        let contents = try lines.map { line -> String in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            let record = try XCTUnwrap(object as? [String: Any])
            return try XCTUnwrap(record["content"] as? String)
        }
        XCTAssertEqual(contents, messages.map(\.content))
    }

    /// Opens a fresh on-disk SwiftData container before exporting, proving the
    /// persistence overload works after a SQLite round trip rather than only
    /// against the test harness's in-memory configuration.
    func test_export_viaReopenedOnDiskSQLiteContainer_roundTripsMessages() async throws {
        let storeURL = tempDir.appendingPathComponent("Conversation.sqlite")
        let sessionID: UUID
        do {
            let container = try ModelContainerFactory.makeContainer(
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = container.mainContext
            let session = PersistedChatSession(title: "On-disk export")
            context.insert(session)
            try context.save()
            let provider = SwiftDataPersistenceProvider(modelContext: context)
            try await provider.insertMessage(ManifoldInference.ChatMessage(
                role: .user,
                content: "persisted question",
                timestamp: Date(timeIntervalSinceReferenceDate: 1),
                sessionID: session.id
            ))
            try await provider.insertMessage(ManifoldInference.ChatMessage(
                role: .assistant,
                content: "persisted answer",
                timestamp: Date(timeIntervalSinceReferenceDate: 2),
                sessionID: session.id
            ))
            sessionID = session.id
        }

        let reopened = try ModelContainerFactory.makeContainer(
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = reopened.mainContext
        let sessions = try context.fetch(FetchDescriptor<PersistedChatSession>(
            predicate: #Predicate { $0.id == sessionID }
        ))
        let session = try XCTUnwrap(sessions.first)
        let provider = SwiftDataPersistenceProvider(modelContext: context)
        let file = try await ConversationExporter.export(
            session: session,
            format: MarkdownExportFormat(),
            provider: provider,
            directory: tempDir
        )

        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertTrue(text.contains("persisted question"))
        XCTAssertTrue(text.contains("persisted answer"))
    }

    func test_export_useDefaultDirectory_writesToTemp() throws {
        // Exercise the nil-directory path so the temp-dir branch is covered.
        let session = ManifoldInference.ChatSession(title: "tempy")
        let file = try ConversationExporter.export(
            session: session,
            messages: [ManifoldInference.ChatMessage(role: .user, content: "hi", sessionID: session.id)],
            format: MarkdownExportFormat(),
            directory: nil
        )

        XCTAssertTrue(
            file.url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
                || file.url.path.hasPrefix("/private\(FileManager.default.temporaryDirectory.path)"),
            "Expected default export to live under temp dir; got \(file.url.path)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))

        // Caller owns cleanup; clean up so we don't leak fixtures.
        file.cleanup()
    }
}
