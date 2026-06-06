import XCTest
@testable import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport

/// Verifies ``SessionListService/deleteAllSessions()`` emits **one**
/// terminal `.sessionsLoaded([], hasMore: false, offset: 0)` event rather
/// than fanning out one `.sessionDeleted(id)` per row — the entire reason
/// the bulk API lowers to a single store call.
@MainActor
final class SessionListServiceDeleteAllTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!
    private var service: SessionListService!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
        service = SessionListService(persistence: stack.provider)
    }

    override func tearDown() async throws {
        service = nil
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Event collector

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [SessionListEvent] = []

        var sink: @Sendable (SessionListEvent) -> Void {
            { [self] event in
                self.lock.lock(); defer { self.lock.unlock() }
                self.events.append(event)
            }
        }
    }

    // MARK: - One-event guarantee

    func test_deleteAllSessions_emitsExactlyOneTerminalEvent() async throws {
        for i in 0..<6 {
            try await stack.provider.insertSession(ChatSession(title: "S\(i)"))
        }

        // Attach the sink *after* the seed so we only capture the deleteAll
        // emission, not the prior loads.
        let collector = EventCollector()
        service.setEventSink(collector.sink)

        try await service.deleteAllSessions()

        XCTAssertEqual(collector.events.count, 1,
                       "deleteAllSessions() must emit exactly one event, not N")

        guard case let .sessionsLoaded(records, hasMore, offset) = collector.events[0] else {
            XCTFail("Expected .sessionsLoaded terminal event, got \(collector.events[0])")
            return
        }
        XCTAssertTrue(records.isEmpty, "Terminal event must carry an empty page")
        XCTAssertFalse(hasMore)
        XCTAssertEqual(offset, 0)

        // Sabotage check (kept here so the assertion is meaningful): if the
        // service ever regresses to fanning out `.sessionDeleted` per id, the
        // count above goes to N+1 (per-id deletes plus the empty load) — the
        // strict `== 1` catches that immediately.
    }

    func test_deleteAllSessions_noSessions_stillEmitsOneEvent() async throws {
        // Even on an empty store the API contract is "one terminal event";
        // observers that re-render on the event don't need to special-case
        // the no-op path.
        let collector = EventCollector()
        service.setEventSink(collector.sink)

        try await service.deleteAllSessions()

        XCTAssertEqual(collector.events.count, 1)
    }

    func test_deleteAllSessions_onPersistenceFailure_emitsNoEvent() async throws {
        // Errors propagate to the caller, but observable state must not
        // briefly show "empty" and then "restored" if persistence failed —
        // so the service emits nothing when the store throws.
        try await stack.provider.insertSession(ChatSession(title: "S0"))

        let injector = ErrorInjectingPersistenceProvider(wrapping: stack.provider)
        injector.shouldThrowOnDeleteAll = ChatPersistenceError.providerNotConfigured
        let failingService = SessionListService(persistence: injector)

        let collector = EventCollector()
        failingService.setEventSink(collector.sink)

        do {
            try await failingService.deleteAllSessions()
            XCTFail("Expected the injected error to propagate")
        } catch {
            // expected
        }

        XCTAssertEqual(collector.events.count, 0,
                       "No event must be emitted when the store throws — observable state stays consistent with the unchanged store")
    }
}
