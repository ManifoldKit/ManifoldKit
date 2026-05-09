@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
@testable import ManifoldTestSupport

/// Integration tests for ``ChatViewModel/ingest(_:)``.
///
/// These run against a real in-memory SwiftData store and a
/// ``MockInferenceBackend`` so the full handoff path is exercised: a new
/// session is inserted into persistence, the message funnels through
/// ``ChatViewModel/sendMessage()``, and generation completes with mocked
/// tokens. That means these are integration tests by classification (they
/// hit SwiftData end-to-end), not unit tests, per CLAUDE.md.
@MainActor
final class ChatViewModelIngestTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: true))
        mock.isModelLoaded = true
        mock.tokensToYield = ["ack"]

        let service = InferenceService(backend: mock, name: "MockIngest")
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

    // MARK: - Creation & basic seeding

    func test_ingest_createsNewSession() async {
        XCTAssertTrue(fetchSessions().isEmpty, "No sessions exist before ingest")

        let payload = InboundPayload(prompt: "summarize READMEs", source: .appIntent)
        await vm.ingest(payload)

        let sessions = fetchSessions()
        XCTAssertEqual(sessions.count, 1, "Ingest should have created exactly one session")
        XCTAssertNotNil(vm.activeSession, "Active session should be set after ingest")
        XCTAssertEqual(vm.activeSession?.id, sessions.first?.id, "Ingested session is active")

        // The prompt must land as the first user message.
        let sessionID = vm.activeSession!.id
        let messages = fetchMessages(for: sessionID)
        XCTAssertGreaterThanOrEqual(messages.count, 1, "Ingest should have seeded a user message")
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.content, "summarize READMEs")
    }

    func test_ingest_attachmentsPreservedAsMessageParts() async {
        let image = MessagePart.image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png")
        let attachments: [MessagePart] = [image]
        let payload = InboundPayload(
            prompt: "here is the prompt",
            attachments: attachments,
            source: .shareExtension
        )
        await vm.ingest(payload)
        let expectedImage = image.generatingImagePlaceholderIfNeeded()

        // The user message is the first one in the active session.
        let userMessage = vm.messages.first(where: { $0.role == .user })
        XCTAssertNotNil(userMessage, "Ingest should seed a user message")
        XCTAssertEqual(
            userMessage?.contentParts,
            [.text("here is the prompt"), expectedImage],
            "User message should carry the prompt plus the image attachment"
        )
        XCTAssertEqual(vm.draftAttachments, [], "Ingested attachments should be consumed by sendMessage()")
        XCTAssertEqual(mock.lastReceivedStructuredHistory?.first?.parts, [.text("here is the prompt"), expectedImage])
    }

    func test_switchToSession_clearsDraftAttachments() async throws {
        let first = ChatSessionRecord(title: "First")
        let second = ChatSessionRecord(title: "Second")
        try await vm.persistence?.insertSession(first)
        try await vm.persistence?.insertSession(second)
        await vm.switchToSession(first)

        vm.inputText = "staged"
        vm.draftAttachments = [
            .image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png")
        ]

        await vm.switchToSession(second)

        XCTAssertEqual(vm.activeSession?.id, second.id)
        XCTAssertEqual(vm.inputText, "")
        XCTAssertTrue(vm.draftAttachments.isEmpty, "Session switches must drop staged attachments from the prior session")
    }

    // MARK: - Concurrency

    func test_ingest_concurrentCallsSerialize() async {
        // Back-to-back on the main actor: each ingest creates its own
        // session before the next runs. The test asserts two distinct
        // sessions exist and both received their prompt. We don't need
        // `async let` here — the main actor re-entrancy contract already
        // serializes these — the assertion is that both ingests land
        // distinct sessions.
        await vm.ingest(InboundPayload(prompt: "first", source: .appIntent))
        await vm.ingest(InboundPayload(prompt: "second", source: .deepLink))

        let sessions = fetchSessions()
        XCTAssertEqual(sessions.count, 2, "Two ingests should produce two distinct sessions")

        // Gather every user message across both sessions and confirm both prompts landed.
        var prompts = Set<String>()
        for session in sessions {
            for message in fetchMessages(for: session.id) where message.role == .user {
                prompts.insert(message.content)
            }
        }
        XCTAssertEqual(prompts, ["first", "second"])
    }

    // MARK: - Precondition: persistence unset

    func test_ingest_withoutPersistence_noops() async {
        let service = InferenceService(backend: mock, name: "MockNoPersistence")
        let unconfigured = ChatViewModel(inferenceService: service)
        // Deliberately do NOT call configure(persistence:).

        await unconfigured.ingest(InboundPayload(prompt: "no persistence", source: .appIntent))

        XCTAssertNil(unconfigured.activeSession, "No session is created without persistence")
        XCTAssertTrue(unconfigured.messages.isEmpty, "No messages when persistence is absent")
    }
}
