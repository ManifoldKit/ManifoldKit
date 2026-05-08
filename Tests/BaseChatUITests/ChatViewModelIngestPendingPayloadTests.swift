@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
@testable import BaseChatTestSupport

/// Integration tests for ``ChatViewModel/ingestPendingPayload(_:intent:)``.
///
/// These exercise every payload × intent cell against a real in-memory
/// SwiftData store and a ``MockInferenceBackend``. By classification
/// these are integration tests (per CLAUDE.md) — they hit SwiftData
/// end-to-end through the same persistence provider production uses.
@MainActor
final class ChatViewModelIngestPendingPayloadTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["ack"]

        let service = InferenceService(backend: mock, name: "MockIngestPending")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        vm = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func fetchSessions() -> [ChatSession] {
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchMessages(for sessionID: UUID) -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - text × .newSession

    func test_textPayload_newSession_createsSessionAndSendsMessage() async {
        XCTAssertTrue(fetchSessions().isEmpty)

        await vm.ingestPendingPayload(
            .text("draft an email"),
            intent: .newSession(preset: nil)
        )

        let sessions = fetchSessions()
        XCTAssertEqual(sessions.count, 1, "newSession should create exactly one session")
        XCTAssertNotNil(vm.activeSession, "Active session should be set")

        let messages = fetchMessages(for: vm.activeSession!.id)
        XCTAssertGreaterThanOrEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.content, "draft an email")
    }

    func test_textPayload_newSession_appliesPreset() async {
        let preset = IngestionPreset(
            modelID: nil,
            systemPrompt: "You are a poet.",
            temperature: 0.42,
            topP: 0.5,
            repeatPenalty: 1.25
        )

        await vm.ingestPendingPayload(
            .text("Compose a haiku."),
            intent: .newSession(preset: preset)
        )

        XCTAssertEqual(vm.systemPrompt, "You are a poet.")
        XCTAssertEqual(vm.temperature, 0.42)
        XCTAssertEqual(vm.topP, 0.5)
        XCTAssertEqual(vm.repeatPenalty, 1.25)

        // The preset is persisted on the new session row so a relaunch
        // (which reloads sampler params + system prompt from the session)
        // continues to see it.
        guard let activeSession = vm.activeSession else {
            return XCTFail("Expected an active session")
        }
        XCTAssertEqual(activeSession.systemPrompt, "You are a poet.")
        XCTAssertEqual(activeSession.temperature, 0.42)
        XCTAssertEqual(activeSession.topP, 0.5)
        XCTAssertEqual(activeSession.repeatPenalty, 1.25)
    }

    func test_textPayload_newSession_withoutModelLoaded_seedsDraftWithoutSending() async {
        // Drive the lifecycle's view of "loaded" rather than poking the
        // raw mock flag — the service's init(backend:) preloads the
        // backend, so we have to unload to flip `vm.isModelLoaded`.
        vm.inferenceService.unloadModel()
        XCTAssertFalse(vm.isModelLoaded, "Precondition: no model loaded")

        await vm.ingestPendingPayload(
            .text("waiting for a model"),
            intent: .newSession(preset: nil)
        )

        XCTAssertNotNil(vm.activeSession, "Session is still created")
        XCTAssertEqual(vm.inputText, "waiting for a model", "Draft is preserved when no model is loaded")
        // No user message should have been written: sendMessage() never ran.
        let messages = fetchMessages(for: vm.activeSession!.id)
        XCTAssertTrue(messages.isEmpty, "No messages persisted without an active model")
    }

    // MARK: - url × .appendToActive

    func test_urlPayload_appendToActive_appendsURLStringToDraft() async {
        // Seed a session and an existing draft.
        let session = ChatSessionRecord(title: "Existing")
        try? await vm.persistence?.insertSession(session)
        await vm.switchToSession(session)
        vm.inputText = "look at this"

        let url = URL(string: "https://example.com/article")!
        await vm.ingestPendingPayload(.url(url), intent: .appendToActive)

        XCTAssertEqual(
            vm.inputText,
            "look at this\nhttps://example.com/article",
            "URL should be appended after a newline"
        )
        // No new session should have been created.
        XCTAssertEqual(fetchSessions().count, 1)
    }

    func test_urlPayload_appendToActive_emptyDraft_replacesWithURLString() async {
        let session = ChatSessionRecord(title: "Existing")
        try? await vm.persistence?.insertSession(session)
        await vm.switchToSession(session)
        vm.inputText = ""

        let url = URL(string: "https://example.com/article")!
        await vm.ingestPendingPayload(.url(url), intent: .appendToActive)

        XCTAssertEqual(vm.inputText, "https://example.com/article")
    }

    // MARK: - image × .draft

    func test_imagePayload_draft_setsEmptyDraftWithoutSending() async {
        let session = ChatSessionRecord(title: "Existing")
        try? await vm.persistence?.insertSession(session)
        await vm.switchToSession(session)
        vm.inputText = "should be replaced"

        let imageData = ImageFixtures.oneByOnePNGData
        await vm.ingestPendingPayload(
            .image(imageData, mimeType: "image/png"),
            intent: .draft
        )

        // Image payloads don't carry a text body, so the draft text is cleared
        // while the image itself is staged in the compose bar.
        XCTAssertEqual(vm.inputText, "")
        XCTAssertEqual(vm.draftAttachments.count, 1)
        guard case .image(let data, let mimeType, let placeholderHash) = vm.draftAttachments[0] else {
            return XCTFail("Expected image draft attachment")
        }
        XCTAssertEqual(data, imageData)
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertNotNil(placeholderHash?.colorGrid)

        // No new messages should have been persisted.
        let messages = fetchMessages(for: session.id)
        XCTAssertTrue(messages.isEmpty)
    }

    func test_imagePayload_appendToActive_keepsDraftTextAndAddsAttachment() async {
        let session = ChatSessionRecord(title: "Existing")
        try? await vm.persistence?.insertSession(session)
        await vm.switchToSession(session)
        vm.inputText = "Please inspect this"

        let imageData = ImageFixtures.oneByOnePNGData
        await vm.ingestPendingPayload(
            .image(imageData, mimeType: "image/png"),
            intent: .appendToActive
        )

        XCTAssertEqual(vm.inputText, "Please inspect this")
        XCTAssertEqual(vm.draftAttachments.count, 1)
        guard case .image(let data, let mimeType, let placeholderHash) = vm.draftAttachments[0] else {
            return XCTFail("Expected image draft attachment")
        }
        XCTAssertEqual(data, imageData)
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertNotNil(placeholderHash?.colorGrid)

        let messages = fetchMessages(for: session.id)
        XCTAssertTrue(messages.isEmpty, "Appending an image payload should stay in draft state until the user sends")
    }

    // MARK: - file × .newSession

    func test_filePayload_newSession_seedsFilePathAsMessage() async {
        let fileURL = URL(fileURLWithPath: "/tmp/sample.txt")

        await vm.ingestPendingPayload(
            .file(fileURL),
            intent: .newSession(preset: nil)
        )

        let sessions = fetchSessions()
        XCTAssertEqual(sessions.count, 1)
        guard let activeSession = vm.activeSession else {
            return XCTFail("Expected an active session")
        }

        let messages = fetchMessages(for: activeSession.id)
        XCTAssertGreaterThanOrEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
        // File payloads currently render their path as the user message
        // body — see PendingPayload.intoMessageBody().
        XCTAssertEqual(messages.first?.content, "/tmp/sample.txt")
    }

    // MARK: - Without persistence

    func test_newSession_withoutPersistence_noops() async {
        let unconfigured = ChatViewModel(
            inferenceService: InferenceService(backend: mock, name: "NoPersistence")
        )
        // Deliberately do NOT call configure(persistence:).

        await unconfigured.ingestPendingPayload(
            .text("nope"),
            intent: .newSession(preset: nil)
        )

        XCTAssertNil(unconfigured.activeSession)
        XCTAssertTrue(unconfigured.messages.isEmpty)
    }

    func test_draft_withoutPersistence_stillSetsInputText() async {
        let unconfigured = ChatViewModel(
            inferenceService: InferenceService(backend: mock, name: "NoPersistence")
        )

        await unconfigured.ingestPendingPayload(.text("hello"), intent: .draft)

        // .draft does not require persistence — the host can wire it
        // up before a SwiftData container is open.
        XCTAssertEqual(unconfigured.inputText, "hello")
    }
}
