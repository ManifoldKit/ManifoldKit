@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration coverage for the multi-session relaunch / restore path
/// fixed in #1464. These tests exercise ``SessionManagerViewModel`` against
/// a real in-memory SwiftData store (no persistence mocks) so the cold-start
/// race that the issue describes is reproduced end-to-end.
///
/// Each test uses a per-test ``UserDefaults`` suite so the persisted
/// last-active session ID does not leak between cases under
/// `swift test --parallel`.
@MainActor
final class SessionRestoreIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        suiteName = "manifoldkit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeVM() -> SessionManagerViewModel {
        let vm = SessionManagerViewModel(userDefaults: defaults)
        let provider = SwiftDataPersistenceProvider(modelContext: container.mainContext)
        vm.configure(persistence: provider, autoLoad: false)
        return vm
    }

    private func insertSession(
        id: UUID = UUID(),
        title: String = "Persisted",
        updatedAt: Date = Date(),
        messageBodies: [String] = []
    ) async throws -> ManifoldInference.ChatSession {
        let provider = SwiftDataPersistenceProvider(modelContext: container.mainContext)
        let record = ManifoldInference.ChatSession(id: id, title: title, updatedAt: updatedAt)
        try await provider.insertSession(record)
        for body in messageBodies {
            let msg = ManifoldInference.ChatMessage(
                role: .user,
                content: body,
                sessionID: record.id
            )
            try await provider.insertMessage(msg)
        }
        return record
    }

    // MARK: - #1464 coverage

    /// Cold start with N persisted sessions and M messages — the first
    /// observation after `configureAndLoad`/`loadSessions` sees all of them.
    /// The pre-fix bug was that `configure(bootstrap:)` returned before the
    /// fire-and-forget load Task ran, so `sessions` was empty on the first
    /// inspection.
    func test_coldStart_withPersistedSessions_restoresThemBeforeFirstObservation() async throws {
        let s1 = try await insertSession(title: "First", updatedAt: Date(timeIntervalSinceNow: -100))
        let s2 = try await insertSession(title: "Second", updatedAt: Date(timeIntervalSinceNow: -50), messageBodies: ["hello"])

        let vm = makeVM()
        await vm.loadSessions()

        XCTAssertEqual(vm.sessions.count, 2, "Both persisted sessions should be visible after the awaited load")
        XCTAssertTrue(vm.sessions.contains(where: { $0.id == s1.id }))
        XCTAssertTrue(vm.sessions.contains(where: { $0.id == s2.id }))
    }

    /// Cold start with zero persisted sessions — `selectInitialSession()`
    /// returns `nil` rather than minting a blank `New Chat`. This is the
    /// invariant that lets the host decide whether to create one, instead
    /// of the framework producing the duplicate-blank-session behaviour
    /// reported on relaunch.
    func test_coldStart_emptyStore_doesNotMintBlankSession() async throws {
        let vm = makeVM()
        await vm.loadSessions()

        let restored = await vm.selectInitialSession()
        XCTAssertNil(restored, "selectInitialSession must not synthesize a session when the store is empty")
        XCTAssertTrue(vm.sessions.isEmpty, "loadSessions must not write any new rows when the store is empty")
    }

    /// Cold start with persisted sessions including a previously active one
    /// — that session is restored even when the most-recent row is a stray
    /// blank session minted by an earlier launch's naive bootstrap.
    func test_coldStart_prefersPreviouslyActiveSessionOverNewerBlankRow() async throws {
        let older = try await insertSession(
            title: "Active conversation",
            updatedAt: Date(timeIntervalSinceNow: -1000),
            messageBodies: ["original content"]
        )
        // Newer row, but empty — what a previous-launch naive bootstrap
        // would have minted.
        _ = try await insertSession(
            title: "New Chat",
            updatedAt: Date()
        )

        // Persist "older" as the last-active session.
        defaults.set(older.id.uuidString, forKey: "manifoldkit.sessionManager.lastActiveSessionID")

        let vm = makeVM()
        await vm.loadSessions()
        let restored = await vm.selectInitialSession()

        XCTAssertEqual(restored?.id, older.id, "The previously active session should be preferred over a newer blank row")
    }

    /// Cold start with no last-active marker — `selectInitialSession()`
    /// still prefers the most recent **non-empty** session over a newer
    /// blank `New Chat` row.
    func test_coldStart_prefersMostRecentNonEmptyOverNewerBlank() async throws {
        let nonEmpty = try await insertSession(
            title: "Has messages",
            updatedAt: Date(timeIntervalSinceNow: -500),
            messageBodies: ["history"]
        )
        _ = try await insertSession(
            title: "Newer but empty",
            updatedAt: Date()
        )

        let vm = makeVM()
        await vm.loadSessions()
        let restored = await vm.selectInitialSession()

        XCTAssertEqual(restored?.id, nonEmpty.id, "A non-empty older session should win over a newer empty one")
    }

    /// Assigning to `activeSession` persists the ID so the next cold start
    /// can restore it. This is the bridge between user selection and the
    /// relaunch policy.
    func test_activeSession_assignmentPersistsLastActiveID_forNextRelaunch() async throws {
        let a = try await insertSession(title: "A")
        let b = try await insertSession(title: "B", updatedAt: Date(timeIntervalSinceNow: 10))

        let vm = makeVM()
        await vm.loadSessions()
        vm.activeSession = a

        // Simulate relaunch with a fresh VM bound to the same defaults.
        let vm2 = SessionManagerViewModel(userDefaults: defaults)
        vm2.configure(
            persistence: SwiftDataPersistenceProvider(modelContext: container.mainContext),
            autoLoad: false
        )
        await vm2.loadSessions()
        let restored = await vm2.selectInitialSession()

        XCTAssertEqual(restored?.id, a.id, "Active session set in the first launch must be restored in the next")
        XCTAssertNotEqual(restored?.id, b.id, "Newer row must not override the recorded last-active session")
    }
}
