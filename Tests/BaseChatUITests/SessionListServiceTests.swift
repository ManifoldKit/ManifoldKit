@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatRuntime
@testable import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

/// Phase 1.1 — covers ``SessionListService`` directly (no view model
/// adapter), ensuring CRUD, search, pagination, and title generation behave
/// against a real in-memory SwiftData store and that the `AsyncStream` event
/// surface fires in the expected order.
@MainActor
final class SessionListServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var persistence: SwiftDataPersistenceProvider!
    private var service: SessionListService!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        persistence = SwiftDataPersistenceProvider(modelContext: context)
        service = SessionListService(persistence: persistence)
    }

    override func tearDown() async throws {
        service = nil
        persistence = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Drains events into an array via the synchronous sink. Tests assert
    /// against the captured sequence after running commands.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [SessionListEvent] = []

        var sink: @Sendable (SessionListEvent) -> Void {
            { [self] event in
                self.lock.lock(); defer { self.lock.unlock() }
                self.events.append(event)
            }
        }

        func snapshot() -> [SessionListEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    private func attachCollector() -> EventCollector {
        let collector = EventCollector()
        service.setEventSink(collector.sink)
        return collector
    }

    private func makeInferenceService(tokens: [String]) -> InferenceService {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = tokens
        return InferenceService(backend: mock, name: "Mock")
    }

    private func makeThrowingInferenceService() -> InferenceService {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("Mock failure")
        return InferenceService(backend: mock, name: "Mock")
    }

    // MARK: - CRUD

    func test_createSession_persists_andEmitsSessionsLoaded() async throws {
        let collector = attachCollector()

        let record = try await service.createSession(title: "First")

        XCTAssertEqual(record.title, "First")
        let events = collector.snapshot()
        // The contract: `.sessionsLoaded` carries the freshly persisted page.
        // We do NOT emit `.sessionInserted` — the spike's collapse is
        // asserted here so a future maintainer cannot quietly re-introduce
        // the redundant event without breaking this test.
        XCTAssertEqual(events.count, 1)
        guard case let .sessionsLoaded(records, hasMore, offset) = events[0] else {
            XCTFail("Expected .sessionsLoaded, got \(events[0])"); return
        }
        XCTAssertEqual(offset, 0)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(records.map(\.id), [record.id])
    }

    func test_deleteSession_emitsSessionDeletedThenSessionsLoaded() async throws {
        let record = try await service.createSession(title: "Doomed")
        let collector = attachCollector()

        try await service.deleteSession(record.id)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        guard case let .sessionDeleted(id) = events[0], id == record.id else {
            XCTFail("Expected .sessionDeleted(\(record.id)) first, got \(events[0])"); return
        }
        guard case let .sessionsLoaded(records, _, _) = events[1] else {
            XCTFail("Expected .sessionsLoaded second, got \(events[1])"); return
        }
        XCTAssertEqual(records, [])
    }

    func test_deleteSession_throwsOnMissingSession_andEmitsNothing() async throws {
        let collector = attachCollector()
        let ghost = ChatSessionRecord(title: "Ghost")

        do {
            try await service.deleteSession(ghost.id)
            XCTFail("Expected throw")
        } catch {
            guard case ChatPersistenceError.sessionNotFound = error else {
                XCTFail("Expected sessionNotFound, got \(error)"); return
            }
        }
        XCTAssertEqual(collector.snapshot().count, 0,
                       "Throwing commands must not emit events on the failure path")
    }

    func test_renameSession_emitsSessionRenamedThenSessionsLoaded() async throws {
        let record = try await service.createSession(title: "Original")
        let collector = attachCollector()

        try await service.renameSession(record, title: "Renamed")

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        guard case let .sessionRenamed(id, title) = events[0] else {
            XCTFail("Expected .sessionRenamed first, got \(events[0])"); return
        }
        XCTAssertEqual(id, record.id)
        XCTAssertEqual(title, "Renamed")
        guard case let .sessionsLoaded(records, _, _) = events[1] else {
            XCTFail("Expected .sessionsLoaded second, got \(events[1])"); return
        }
        XCTAssertEqual(records.first?.title, "Renamed")
    }

    // MARK: - Pagination

    func test_loadInitialPage_emitsFirstPage() async throws {
        try await seedSessions(count: 60)
        let collector = attachCollector()

        await service.loadInitialPage()

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case let .sessionsLoaded(records, hasMore, offset) = events[0] else {
            XCTFail("Expected .sessionsLoaded, got \(events[0])"); return
        }
        XCTAssertEqual(offset, 0)
        XCTAssertTrue(hasMore)
        XCTAssertEqual(records.count, SessionListService.sessionsPageSize)
    }

    func test_loadNextPage_emitsPageAtOffset() async throws {
        try await seedSessions(count: 60)
        let collector = attachCollector()

        await service.loadNextPage(offset: SessionListService.sessionsPageSize)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case let .sessionsLoaded(records, hasMore, offset) = events[0] else {
            XCTFail("Expected .sessionsLoaded, got \(events[0])"); return
        }
        XCTAssertEqual(offset, SessionListService.sessionsPageSize)
        XCTAssertFalse(hasMore, "Final partial page must clear hasMore")
        XCTAssertEqual(records.count, 10)
    }

    func test_loadNextPage_persistenceFailure_emitsResetThenFailure() async throws {
        try await seedSessions(count: 5)
        // Wrap the in-memory provider with an error injector so the next
        // fetch throws. Using the default `fetchSessions(offset:limit:)`
        // implementation (pages over `fetchSessions()`) means injecting on
        // `shouldThrowOnFetchSessions` covers the pagination call too.
        let injector = ErrorInjectingPersistenceProvider(wrapping: persistence)
        injector.shouldThrowOnFetchSessions = ChatPersistenceError.providerNotConfigured
        let service = SessionListService(persistence: injector)
        let collector = EventCollector()
        service.setEventSink(collector.sink)

        await service.loadNextPage(offset: 50)

        // Phase 1.0 behaviour: a failed page-load resets `hasMoreSessions`
        // so the user is not stuck retrying. We restore that by emitting an
        // empty `.sessionsLoaded(_, hasMore: false, offset:)` ahead of the
        // diagnostic `.persistenceFailure`. Without the reset the adapter
        // would still believe a next page exists.
        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2,
                       "Expected reset .sessionsLoaded then .persistenceFailure, got \(events)")
        guard case let .sessionsLoaded(records, hasMore, offset) = events[0] else {
            XCTFail("Expected .sessionsLoaded reset event, got \(events[0])"); return
        }
        XCTAssertEqual(records, [])
        XCTAssertFalse(hasMore, "Failure must clear hasMore so the adapter stops paginating")
        XCTAssertEqual(offset, 50, "Reset event must carry the failed offset, not 0")
        guard case .persistenceFailure = events[1] else {
            XCTFail("Expected .persistenceFailure second, got \(events[1])"); return
        }
    }

    func test_fetchPage_doesNotEmit() async throws {
        try await seedSessions(count: 5)
        let collector = attachCollector()

        let page = try await service.fetchPage(offset: 0, limit: 10)

        XCTAssertEqual(page.count, 5)
        XCTAssertEqual(collector.snapshot().count, 0,
                       "fetchPage is the read-only helper; it must not emit")
    }

    // MARK: - Search

    func test_runTitleSearch_emitsCaseInsensitiveMatches() async throws {
        try await seedSessions(titles: ["Travel Plan", "Recipes", "TRAVEL guide"])
        let all = try await persistence.fetchSessions()
        let collector = attachCollector()

        service.runTitleSearch("travel", against: all)

        guard case let .searchResultsChanged(results) = collector.snapshot().last else {
            XCTFail("Expected .searchResultsChanged, got \(collector.snapshot())"); return
        }
        XCTAssertEqual(Set(results.titleMatches.map(\.title)), ["Travel Plan", "TRAVEL guide"])
        XCTAssertTrue(results.messageMatchSessions.isEmpty)
    }

    func test_runTitleSearch_emptyQueryEmitsEmpty() async throws {
        let collector = attachCollector()
        service.runTitleSearch(" ", against: [])
        guard case let .searchResultsChanged(results) = collector.snapshot().last else {
            XCTFail("Expected .searchResultsChanged"); return
        }
        XCTAssertTrue(results.titleMatches.isEmpty)
    }

    func test_runMessageSearch_emitsHitsAndResolvedSessions() async throws {
        let s1 = try await service.createSession(title: "S1")
        let s2 = try await service.createSession(title: "S2")
        let s3 = try await service.createSession(title: "S3")
        try await persistence.insertMessage(ChatMessageRecord(role: .user, content: "tell me about NEEDLE in haystack", sessionID: s1.id))
        try await persistence.insertMessage(ChatMessageRecord(role: .user, content: "no match here", sessionID: s2.id))
        try await persistence.insertMessage(ChatMessageRecord(role: .user, content: "more needle talk", sessionID: s3.id))
        let collector = attachCollector()

        await service.runMessageSearch("needle")

        guard case let .searchResultsChanged(results) = collector.snapshot().last else {
            XCTFail("Expected .searchResultsChanged"); return
        }
        XCTAssertEqual(Set(results.messageMatchSessions.map(\.id)), [s1.id, s3.id])
        XCTAssertEqual(results.messageHitsBySession[s1.id]?.count, 1)
        XCTAssertEqual(results.messageHitsBySession[s3.id]?.count, 1)
        XCTAssertNil(results.messageHitsBySession[s2.id])
    }

    func test_clearSearch_emitsEmpty() {
        let collector = attachCollector()
        service.clearSearch()
        guard case let .searchResultsChanged(results) = collector.snapshot().last else {
            XCTFail("Expected .searchResultsChanged"); return
        }
        XCTAssertTrue(results.titleMatches.isEmpty)
        XCTAssertTrue(results.messageMatchSessions.isEmpty)
    }

    // MARK: - Title generation

    func test_autoRenameSession_emitsTitleGenerated_andReload() async throws {
        let session = try await service.createSession()
        let collector = attachCollector()
        let inference = makeInferenceService(tokens: ["Travel", " Tips"])

        await service.autoRenameSession(session, firstMessage: "How do I plan?", inferenceService: inference)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2, "Expected .titleGenerated then .sessionsLoaded")
        guard case let .titleGenerated(id, title) = events[0] else {
            XCTFail("Expected .titleGenerated first, got \(events[0])"); return
        }
        XCTAssertEqual(id, session.id)
        XCTAssertEqual(title, "Travel Tips")
        guard case .sessionsLoaded = events[1] else {
            XCTFail("Expected .sessionsLoaded second, got \(events[1])"); return
        }
    }

    func test_autoRenameSession_inferenceFailure_recordsDiagnostic_emitsNothing() async throws {
        let diagnostics = DiagnosticsService()
        let service = SessionListService(persistence: persistence, diagnostics: diagnostics)
        let session = try await service.createSession()
        let collector = EventCollector()
        service.setEventSink(collector.sink)
        let inference = makeThrowingInferenceService()

        await service.autoRenameSession(session, firstMessage: "Tell me", inferenceService: inference)

        XCTAssertEqual(collector.snapshot().count, 0)
        XCTAssertEqual(diagnostics.count, 1)
        guard case .titleGenerationFailed = diagnostics.warnings.first?.error else {
            XCTFail("Expected .titleGenerationFailed, got \(String(describing: diagnostics.warnings.first?.error))")
            return
        }
    }

    func test_autoRenameSession_skipsNonNewChatTitle() async throws {
        let session = try await service.createSession(title: "Custom")
        let collector = attachCollector()
        let inference = makeInferenceService(tokens: ["Should", " Be", " Skipped"])

        await service.autoRenameSession(session, firstMessage: "Hi", inferenceService: inference)

        XCTAssertEqual(collector.snapshot().count, 0,
                       "Non-default title must short-circuit before any emit")
    }

    func test_autoGenerateTitle_emitsTitleGenerated_andTruncatesAtWordBoundary() async throws {
        let session = try await service.createSession()
        let collector = attachCollector()

        await service.autoGenerateTitle(
            for: session,
            firstMessage: "This is a really long message that should be truncated at a word boundary because it exceeds fifty characters"
        )

        let events = collector.snapshot()
        guard case let .titleGenerated(_, title) = events.first else {
            XCTFail("Expected .titleGenerated, got \(events)"); return
        }
        XCTAssertTrue(title.hasSuffix("..."))
        XCTAssertLessThanOrEqual(title.count, 53)
    }

    // MARK: - AsyncStream surface

    func test_eventsStream_observesEvents_inOrder() async throws {
        // Verifies the public AsyncStream surface matches the synchronous
        // sink. The adapter uses the sink today; runtime adapters in Phase
        // 1.2 will use the stream.
        let stream = service.events
        let observerTask = Task { @MainActor () -> [SessionListEvent] in
            var observed: [SessionListEvent] = []
            for await event in stream {
                observed.append(event)
                // createSession emits one event; deleteSession emits two.
                if observed.count >= 3 { break }
            }
            return observed
        }
        // Yield so the consumer Task is parked on `for await` before we emit.
        await Task.yield()

        let record = try await service.createSession(title: "Streamed")
        try await service.deleteSession(record.id)

        let observed = await observerTask.value
        XCTAssertEqual(observed.count, 3)
        guard case .sessionsLoaded = observed[0] else {
            XCTFail("Expected createSession's .sessionsLoaded, got \(observed[0])"); return
        }
        guard case let .sessionDeleted(id) = observed[1] else {
            XCTFail("Expected .sessionDeleted, got \(observed[1])"); return
        }
        XCTAssertEqual(id, record.id)
        guard case .sessionsLoaded = observed[2] else {
            XCTFail("Expected deleteSession's .sessionsLoaded, got \(observed[2])"); return
        }
    }

    // MARK: - Seeding

    private func seedSession(title: String, updatedAt: Date = Date()) async throws -> ChatSessionRecord {
        let record = ChatSessionRecord(title: title, updatedAt: updatedAt)
        try await persistence.insertSession(record)
        return record
    }

    private func seedSessions(titles: [String], spacingSeconds: TimeInterval = 1) async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        for (i, title) in titles.enumerated() {
            try await persistence.insertSession(ChatSessionRecord(
                title: title,
                updatedAt: base.addingTimeInterval(Double(i) * spacingSeconds)
            ))
        }
    }

    private func seedSessions(count: Int) async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<count {
            try await persistence.insertSession(ChatSessionRecord(
                title: "S\(i)",
                updatedAt: base.addingTimeInterval(Double(i))
            ))
        }
    }
}
