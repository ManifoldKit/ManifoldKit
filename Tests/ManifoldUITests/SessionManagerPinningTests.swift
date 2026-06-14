@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// VM-level coverage for session-level pinning (#1301).
///
/// Asserts the public surface introduced on ``SessionManagerViewModel``:
///   - `pinSession(_:)` / `unpinSession(_:)` flip `isPinned` and reload the
///     page so observable `sessions` reflects the new sort order.
///   - `pinnedSessions` derives correctly from the loaded slice and stays
///     ordered by `pinnedAt` desc.
///   - Pinning is idempotent — repeating a pin doesn't reshuffle the bucket.
@MainActor
final class SessionManagerPinningTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Pin moves the session to the top

    func test_pinSession_movesSessionToTopOfList() async throws {
        let vm = SessionManagerViewModel()
        vm.configure(persistence: stack.provider, autoLoad: false)
        try await vm.createSession(title: "A")
        try await vm.createSession(title: "B")
        let toPin = try await vm.createSession(title: "C")
        // "C" is most recent, so without pinning it already sits at index 0.
        // Pin "A" instead — that's the load-bearing case.
        guard let aRecord = vm.sessions.first(where: { $0.title == "A" }) else {
            return XCTFail("Expected session A to be loaded")
        }

        try await vm.pinSession(aRecord)

        // After the pin, "A" sorts above the chronological tail even though
        // it has the oldest updatedAt of the three.
        XCTAssertEqual(vm.sessions.first?.title, "A")
        XCTAssertTrue(vm.sessions.first?.isPinned ?? false)
        XCTAssertNotNil(vm.sessions.first?.pinnedAt)

        _ = toPin   // silence unused warning
    }

    // MARK: - Unpin returns to chronological order

    func test_unpinSession_returnsToChronologicalOrder() async throws {
        let vm = SessionManagerViewModel()
        vm.configure(persistence: stack.provider, autoLoad: false)
        try await vm.createSession(title: "A")
        try await vm.createSession(title: "B")
        try await vm.createSession(title: "C")
        let aRecord = try XCTUnwrap(vm.sessions.first(where: { $0.title == "A" }))

        try await vm.pinSession(aRecord)
        XCTAssertEqual(vm.sessions.first?.title, "A")
        let pinned = try XCTUnwrap(vm.sessions.first)

        try await vm.unpinSession(pinned)

        // C is most recent, then B, then A — the original chronological order.
        XCTAssertEqual(vm.sessions.map(\.title), ["C", "B", "A"])
        XCTAssertFalse(vm.sessions.allSatisfy(\.isPinned))
    }

    // MARK: - pinnedSessions derived view

    func test_pinnedSessions_ordersByPinnedAtDescending() async throws {
        let vm = SessionManagerViewModel()
        vm.configure(persistence: stack.provider, autoLoad: false)
        try await vm.createSession(title: "A")
        try await vm.createSession(title: "B")
        try await vm.createSession(title: "C")

        let aRecord = try XCTUnwrap(vm.sessions.first(where: { $0.title == "A" }))
        try await vm.pinSession(aRecord)
        // Tiny sleep to guarantee the second `pinnedAt` is strictly later
        // (Date() resolution is microseconds but back-to-back awaits can land
        // in the same tick on some runners).
        try await Task.sleep(nanoseconds: 2_000_000)
        let bRecord = try XCTUnwrap(vm.sessions.first(where: { $0.title == "B" }))
        try await vm.pinSession(bRecord)

        XCTAssertEqual(vm.pinnedSessions.map(\.title), ["B", "A"])
        XCTAssertTrue(vm.pinnedSessions.allSatisfy(\.isPinned))
    }

    // MARK: - Idempotence

    func test_pinSession_isIdempotent() async throws {
        let vm = SessionManagerViewModel()
        vm.configure(persistence: stack.provider, autoLoad: false)
        try await vm.createSession(title: "A")
        let aRecord = try XCTUnwrap(vm.sessions.first)

        try await vm.pinSession(aRecord)
        let firstPinnedAt = try XCTUnwrap(vm.sessions.first?.pinnedAt)

        // Re-pin the freshly pinned record. The service guards on
        // `record.isPinned == false` so this must NOT reshuffle pinnedAt.
        try await Task.sleep(nanoseconds: 2_000_000)
        let pinnedRecord = try XCTUnwrap(vm.sessions.first)
        try await vm.pinSession(pinnedRecord)

        XCTAssertEqual(vm.sessions.first?.pinnedAt, firstPinnedAt,
                       "Re-pinning an already-pinned session must not reset its pinnedAt timestamp")
    }

    // MARK: - togglePin convenience (#1300)

    func test_togglePin_pinsThenUnpins() async throws {
        let vm = SessionManagerViewModel()
        vm.configure(persistence: stack.provider, autoLoad: false)
        try await vm.createSession(title: "A")
        let unpinned = try XCTUnwrap(vm.sessions.first)
        XCTAssertFalse(unpinned.isPinned)

        // First toggle pins.
        try await vm.togglePin(unpinned)
        let pinned = try XCTUnwrap(vm.sessions.first(where: { $0.title == "A" }))
        XCTAssertTrue(pinned.isPinned)
        XCTAssertNotNil(pinned.pinnedAt)

        // Second toggle (on the fresh, now-pinned record) unpins.
        try await vm.togglePin(pinned)
        let backToUnpinned = try XCTUnwrap(vm.sessions.first(where: { $0.title == "A" }))
        XCTAssertFalse(backToUnpinned.isPinned)
        XCTAssertNil(backToUnpinned.pinnedAt)
    }

    // MARK: - Reload preserves pinned state

    func test_pinning_survivesReload() async throws {
        let vm = SessionManagerViewModel()
        vm.configure(persistence: stack.provider, autoLoad: false)
        try await vm.createSession(title: "A")
        let aRecord = try XCTUnwrap(vm.sessions.first)
        try await vm.pinSession(aRecord)

        // Re-load page one from persistence. The pinned bit must be carried
        // by the record itself, not by VM state — otherwise it would not
        // travel across app-group reads or cloud sync.
        await vm.loadSessions()

        let reloaded = try XCTUnwrap(vm.sessions.first(where: { $0.title == "A" }))
        XCTAssertTrue(reloaded.isPinned)
        XCTAssertNotNil(reloaded.pinnedAt)
    }
}
