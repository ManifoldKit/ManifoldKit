import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

/// Observability decorator that WRAPS a real ``SessionStore`` and counts which
/// surface the turn loop drives — `fetchSessions()` (full-table scan) vs
/// `fetchSession(id:)` (predicate pushdown). Not a mock: every call delegates
/// to the wrapped store so behavior is unchanged; it only records counts.
@MainActor
private final class CountingSessionStore: SessionStore {
    let wrapped: any SessionStore
    private(set) var fetchSessionsCount = 0
    private(set) var fetchSessionByIDCount = 0

    init(wrapping wrapped: any SessionStore) {
        self.wrapped = wrapped
    }

    func insertSession(_ session: ManifoldInference.ChatSession) async throws {
        try await wrapped.insertSession(session)
    }

    func updateSession(_ session: ManifoldInference.ChatSession) async throws {
        try await wrapped.updateSession(session)
    }

    func deleteSession(_ sessionID: UUID) async throws {
        try await wrapped.deleteSession(sessionID)
    }

    func touch(sessionID: UUID, date: Date) async throws {
        try await wrapped.touch(sessionID: sessionID, date: date)
    }

    func setActiveAgent(sessionID: UUID, agentID: UUID?) async throws {
        try await wrapped.setActiveAgent(sessionID: sessionID, agentID: agentID)
    }

    func fetchSessions() async throws -> [ManifoldInference.ChatSession] {
        fetchSessionsCount += 1
        return try await wrapped.fetchSessions()
    }

    // Delegates to the wrapped store's override (predicate pushdown for the
    // SwiftData provider) — does NOT fall through to the protocol default's
    // scan, so a hit here proves the port took the by-id path.
    func fetchSession(id: UUID) async throws -> ManifoldInference.ChatSession? {
        fetchSessionByIDCount += 1
        return try await wrapped.fetchSession(id: id)
    }
}

/// Proves the per-turn single-session read no longer scans the whole sessions
/// table: one `send` through ``ConversationRuntime`` must hit
/// `fetchSession(id:)` and never `fetchSessions()`.
@MainActor
final class TurnFetchSessionByIDNoScanTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    func test_send_readsSessionByID_neverScansFullTable() async throws {
        let counting = CountingSessionStore(wrapping: stack.provider)

        // A persisted session the turn loop will read its multi-agent state
        // from, plus a decoy so a scan would have something to discard.
        let sessionID = UUID()
        try await counting.insertSession(ManifoldInference.ChatSession(id: sessionID, title: "Active"))
        try await counting.insertSession(ManifoldInference.ChatSession(title: "Decoy"))

        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let runtime = ConversationRuntime(
            messageStore: stack.provider,
            sessionStore: counting,
            inferenceService: inference,
            pipeline: nil
        )

        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "hi"))
        )
        _ = await handle?.outcome

        XCTAssertEqual(
            counting.fetchSessionsCount, 0,
            "A send turn must not scan the whole sessions table"
        )
        XCTAssertGreaterThanOrEqual(
            counting.fetchSessionByIDCount, 1,
            "A send turn must read the active session via fetchSession(id:)"
        )
    }
}
