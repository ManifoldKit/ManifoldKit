@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// Covers the "jump to the matched message" bridge: selecting a
/// `.messages`-scope search result must scroll the chat pane to the exact
/// message that matched, once the opened session's messages have loaded.
///
/// Two seams are exercised end-to-end against a real in-memory SwiftData
/// store (no persistence mocks), mirroring
/// ``SessionManagerSearchPaginationTests`` and
/// ``ChatViewModelScrollToMessageTests``:
///
/// 1. ``SessionManagerViewModel/pendingSearchScrollMessageID`` — recorded
///    automatically when `activeSession` is set while a `.messages` search
///    is active, and consumable exactly once via
///    ``SessionManagerViewModel/consumeSearchScrollTarget(for:)``.
/// 2. ``ChatViewModel/switchToSession(_:scrollToMessageID:)`` — the
///    post-load seam that turns that target into a real
///    ``ChatViewModel/scrollToMessageRequest``.
@MainActor
final class SearchJumpToMessageTests: XCTestCase {

    private var container: ModelContainer!
    private var persistence: SwiftDataPersistenceProvider!
    private var sessionManager: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        persistence = SwiftDataPersistenceProvider(modelContext: container.mainContext)
        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
    }

    override func tearDown() async throws {
        sessionManager = nil
        persistence = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - SessionManagerViewModel: pending target bookkeeping

    func test_selectingMessagesSearchHit_recordsPendingScrollTarget() async throws {
        let session = try await seedSession(title: "S1")
        let match = try await insertMessage(content: "find the NEEDLE here", sessionID: session.id)
        await sessionManager.loadSessions()

        sessionManager.searchScope = .messages
        sessionManager.searchQuery = "needle"
        await sessionManager.runMessageSearch("needle")

        // Simulate the sidebar's `List(selection: $sessionManager.activeSession)`
        // binding writing the tapped row's session directly.
        sessionManager.activeSession = session

        XCTAssertEqual(sessionManager.pendingSearchScrollMessageID, match.id)
    }

    func test_ordinarySessionOpen_doesNotRecordPendingScrollTarget() async throws {
        let session = try await seedSession(title: "S1")
        _ = try await insertMessage(content: "hello world", sessionID: session.id)
        await sessionManager.loadSessions()

        // No search active — scope defaults to `.titles`, query is empty.
        sessionManager.activeSession = session

        XCTAssertNil(sessionManager.pendingSearchScrollMessageID)
    }

    func test_selectingTitlesSearchHit_doesNotRecordPendingScrollTarget() async throws {
        let session = try await seedSession(title: "Travel Plan")
        _ = try await insertMessage(content: "needle content", sessionID: session.id)
        await sessionManager.loadSessions()

        sessionManager.searchScope = .titles
        sessionManager.searchQuery = "Travel"
        sessionManager.runTitleSearch("Travel")

        sessionManager.activeSession = session

        XCTAssertNil(
            sessionManager.pendingSearchScrollMessageID,
            "Titles-scope selection must never set a message-jump target"
        )
    }

    func test_multipleHits_targetsMostRecentHitForSession() async throws {
        let session = try await seedSession(title: "S1")
        _ = try await insertMessage(content: "older needle mention", sessionID: session.id, secondsAgo: 100)
        let mostRecent = try await insertMessage(content: "newer needle mention", sessionID: session.id, secondsAgo: 1)
        await sessionManager.loadSessions()

        sessionManager.searchScope = .messages
        sessionManager.searchQuery = "needle"
        await sessionManager.runMessageSearch("needle")

        sessionManager.activeSession = session

        XCTAssertEqual(
            sessionManager.pendingSearchScrollMessageID,
            mostRecent.id,
            "Hits are recency-sorted — the first hit for a session must be the most recent match"
        )
    }

    func test_consumeSearchScrollTarget_returnsAndClearsTarget() async throws {
        let session = try await seedSession(title: "S1")
        let match = try await insertMessage(content: "needle", sessionID: session.id)
        await sessionManager.loadSessions()

        sessionManager.searchScope = .messages
        sessionManager.searchQuery = "needle"
        await sessionManager.runMessageSearch("needle")
        sessionManager.activeSession = session

        let consumed = sessionManager.consumeSearchScrollTarget(for: session.id)

        XCTAssertEqual(consumed, match.id)
        XCTAssertNil(
            sessionManager.pendingSearchScrollMessageID,
            "Consuming must clear the target so re-activating the same session later does not re-fire"
        )
        XCTAssertNil(
            sessionManager.consumeSearchScrollTarget(for: session.id),
            "A second consume for the same session must return nil"
        )
    }

    func test_consumeSearchScrollTarget_returnsNilForMismatchedSession() async throws {
        let session = try await seedSession(title: "S1")
        let other = try await seedSession(title: "S2")
        _ = try await insertMessage(content: "needle", sessionID: session.id)
        await sessionManager.loadSessions()

        sessionManager.searchScope = .messages
        sessionManager.searchQuery = "needle"
        await sessionManager.runMessageSearch("needle")
        sessionManager.activeSession = session

        XCTAssertNil(sessionManager.consumeSearchScrollTarget(for: other.id))
        // The mismatched read must not have consumed the real target.
        XCTAssertNotNil(sessionManager.pendingSearchScrollMessageID)
    }

    func test_clearSearch_clearsPendingScrollTarget() async throws {
        let session = try await seedSession(title: "S1")
        _ = try await insertMessage(content: "needle", sessionID: session.id)
        await sessionManager.loadSessions()

        sessionManager.searchScope = .messages
        sessionManager.searchQuery = "needle"
        await sessionManager.runMessageSearch("needle")
        sessionManager.activeSession = session
        XCTAssertNotNil(sessionManager.pendingSearchScrollMessageID)

        sessionManager.clearSearch()

        XCTAssertNil(sessionManager.pendingSearchScrollMessageID)
    }

    // MARK: - Cross-VM bridge: SessionManagerViewModel -> ChatViewModel

    /// End-to-end: a search-hit selection produces a pending target that,
    /// once forwarded through `switchToSession(_:scrollToMessageID:)`,
    /// becomes a real scroll request AFTER messages have loaded — the target
    /// message is actually present in `messages` by the time the request is
    /// issued (the load-before-scroll ordering the timing seam depends on).
    func test_searchHitSelection_producesScrollRequestAfterMessagesLoad() async throws {
        let session = try await seedSession(title: "S1")
        _ = try await insertMessage(content: "unrelated first message", sessionID: session.id, secondsAgo: 50)
        let match = try await insertMessage(content: "the NEEDLE is here", sessionID: session.id, secondsAgo: 10)
        await sessionManager.loadSessions()

        sessionManager.searchScope = .messages
        sessionManager.searchQuery = "needle"
        await sessionManager.runMessageSearch("needle")
        sessionManager.activeSession = session

        let scrollTarget = sessionManager.consumeSearchScrollTarget(for: session.id)
        XCTAssertEqual(scrollTarget, match.id, "Precondition: the bridge must resolve the matched message")

        let chatVM = makeChatViewModel()
        await chatVM.switchToSession(session, scrollToMessageID: scrollTarget)

        XCTAssertTrue(
            chatVM.messages.contains(where: { $0.id == match.id }),
            "The target message must actually be loaded before the scroll request is meaningful"
        )
        XCTAssertEqual(chatVM.scrollToMessageRequest?.messageID, match.id)
        XCTAssertEqual(chatVM.scrollToMessageRequest?.anchor, .center)
    }

    /// An ordinary (non-search) session open must never scroll — the
    /// consumed target is `nil`, and `switchToSession` must leave
    /// `scrollToMessageRequest` untouched.
    func test_ordinarySessionOpen_doesNotTriggerScrollRequest() async throws {
        let session = try await seedSession(title: "S1")
        _ = try await insertMessage(content: "hello world", sessionID: session.id)
        await sessionManager.loadSessions()

        // No search active.
        sessionManager.activeSession = session
        let scrollTarget = sessionManager.consumeSearchScrollTarget(for: session.id)
        XCTAssertNil(scrollTarget, "Precondition: an ordinary open must not resolve a scroll target")

        let chatVM = makeChatViewModel()
        await chatVM.switchToSession(session, scrollToMessageID: scrollTarget)

        XCTAssertNil(chatVM.scrollToMessageRequest, "Ordinary session open must not trigger a scroll-to-message request")
    }

    /// Backward-compatibility: the pre-existing single-argument call site
    /// (no consumer wired up to search) must keep behaving exactly as before.
    func test_switchToSession_withoutScrollToMessageID_defaultsToNoScrollRequest() async throws {
        let session = try await seedSession(title: "S1")
        _ = try await insertMessage(content: "hello world", sessionID: session.id)

        let chatVM = makeChatViewModel()
        await chatVM.switchToSession(session)

        XCTAssertNil(chatVM.scrollToMessageRequest)
    }

    // MARK: - Helpers

    private func makeChatViewModel() -> ChatViewModel {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "MockSearchJump-\(UUID().uuidString)")
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)
        return vm
    }

    private func seedSession(title: String, updatedAt: Date = Date()) async throws -> ManifoldInference.ChatSession {
        let record = ManifoldInference.ChatSession(title: title, updatedAt: updatedAt)
        try await persistence.insertSession(record)
        return record
    }

    @discardableResult
    private func insertMessage(
        content: String,
        sessionID: UUID,
        secondsAgo: TimeInterval = 0
    ) async throws -> ManifoldInference.ChatMessage {
        let message = ManifoldInference.ChatMessage(
            role: .user,
            content: content,
            timestamp: Date(timeIntervalSinceNow: -secondsAgo),
            sessionID: sessionID
        )
        try await persistence.insertMessage(message)
        return message
    }
}
