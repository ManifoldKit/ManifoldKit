@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// VM-level coverage for ``SessionManagerViewModel/deleteAllSessions()``.
///
/// Asserts the user-visible observable surface after the bulk call:
///   - `sessions` collapses to empty in one update (not animated per-row)
///   - `activeSession` clears (so a re-entry surface doesn't retain a stale pointer)
///   - underlying persistence transaction ran once (single round-trip)
///   - on persistence failure the call rethrows and observable state stays
///     consistent with the unchanged store.
@MainActor
final class SessionManagerBulkDeleteTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Happy path

    func test_deleteAllSessions_clearsSessionsAndActivePointer() async throws {
        let vm = SessionManagerViewModel()
        vm.configure(persistence: stack.provider, autoLoad: false)
        for i in 0..<4 {
            try await vm.createSession(title: "S\(i)")
        }
        XCTAssertEqual(vm.sessions.count, 4)
        XCTAssertNotNil(vm.activeSession,
                        "createSession activates the freshly-created session by contract")

        try await vm.deleteAllSessions()

        XCTAssertTrue(vm.sessions.isEmpty,
                      "After deleteAllSessions(), the published session list must collapse to empty")
        XCTAssertNil(vm.activeSession,
                     "Active session pointer must be cleared so re-entry surfaces don't reference a deleted row")
        XCTAssertFalse(vm.hasMoreSessions)
    }

    // MARK: - Single store transaction

    func test_deleteAllSessions_lowersToSingleStoreCall_notNPerSession() async throws {
        // Wrap the real provider in the counting injector so we can prove the
        // VM lowered to one bulk call rather than N per-session deletes.
        let injector = ErrorInjectingPersistenceProvider(wrapping: stack.provider)
        let vm = SessionManagerViewModel()
        vm.configure(persistence: injector, autoLoad: false)
        for i in 0..<5 {
            try await vm.createSession(title: "S\(i)")
        }
        // Baseline: no deleteAll calls yet, no per-session deletes yet.
        XCTAssertEqual(injector.deleteAllCallCount, 0)
        XCTAssertEqual(injector.deleteSessionCallCount, 0)

        try await vm.deleteAllSessions()

        XCTAssertEqual(injector.deleteAllCallCount, 1,
                       "deleteAllSessions() must hit the store's deleteAll() exactly once")
        XCTAssertEqual(injector.deleteSessionCallCount, 0,
                       "deleteAllSessions() must not fan out per-session deleteSession() calls")
    }

    // MARK: - Failure propagation + state preservation

    func test_deleteAllSessions_persistenceFailure_propagates_andLeavesStateUntouched() async throws {
        let injector = ErrorInjectingPersistenceProvider(wrapping: stack.provider)
        let vm = SessionManagerViewModel()
        vm.configure(persistence: injector, autoLoad: false)
        for i in 0..<3 {
            try await vm.createSession(title: "S\(i)")
        }
        let beforeIDs = vm.sessions.map(\.id).sorted()
        let beforeActive = vm.activeSession?.id

        injector.shouldThrowOnDeleteAll = ChatPersistenceError.providerNotConfigured

        do {
            try await vm.deleteAllSessions()
            XCTFail("Expected the injected persistence error to propagate")
        } catch {
            // expected
        }

        XCTAssertEqual(vm.sessions.map(\.id).sorted(), beforeIDs,
                       "On persistence failure the session list must be unchanged")
        XCTAssertEqual(vm.activeSession?.id, beforeActive,
                       "On persistence failure the active session pointer must be unchanged")
    }

    // MARK: - Unconfigured guard

    func test_deleteAllSessions_throwsWhenPersistenceMissing() async {
        let vm = SessionManagerViewModel()
        do {
            try await vm.deleteAllSessions()
            XCTFail("deleteAllSessions() must throw before persistence is configured")
        } catch ChatPersistenceError.providerNotConfigured {
            // expected
        } catch {
            XCTFail("Expected providerNotConfigured, got \(error)")
        }
    }
}
