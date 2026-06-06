import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

/// Integration tests for session-level pinning (#1301).
///
/// Classified integration: drives a real SwiftData stack via
/// ``InMemoryPersistenceHarness``. Persistence is never mocked.
@MainActor
final class SessionPinningTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    private var provider: SwiftDataPersistenceProvider { stack.provider }

    // MARK: - Default state

    func test_insertSession_defaultsToUnpinned() async throws {
        let record = ManifoldInference.ChatSession(title: "Default")
        try await provider.insertSession(record)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertFalse(fetched[0].isPinned)
        XCTAssertNil(fetched[0].pinnedAt)
    }

    // MARK: - Pin / unpin round-trip

    func test_pinning_persistsAcrossFetch() async throws {
        let record = ManifoldInference.ChatSession(title: "Pin me")
        try await provider.insertSession(record)

        var updated = record
        updated.isPinned = true
        updated.pinnedAt = Date(timeIntervalSince1970: 2_000_000)
        try await provider.updateSession(updated)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched[0].isPinned)
        XCTAssertEqual(fetched[0].pinnedAt, updated.pinnedAt)
    }

    func test_unpinning_clearsState() async throws {
        let record = ManifoldInference.ChatSession(
            title: "Unpin",
            isPinned: true,
            pinnedAt: Date(timeIntervalSince1970: 1_500_000)
        )
        try await provider.insertSession(record)

        var updated = record
        updated.isPinned = false
        updated.pinnedAt = nil
        try await provider.updateSession(updated)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertFalse(fetched[0].isPinned)
        XCTAssertNil(fetched[0].pinnedAt)
    }

    // MARK: - Sort order

    func test_fetchSessions_pinnedSurfaceAboveChronological() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)

        // Two pinned sessions and two unpinned. Pinned-at order is the
        // *opposite* of updatedAt order so the test fails if the sort falls
        // back to updatedAt within the pinned bucket.
        let unpinnedRecent = ManifoldInference.ChatSession(title: "U-recent", updatedAt: now.addingTimeInterval(300))
        let unpinnedOld = ManifoldInference.ChatSession(title: "U-old", updatedAt: now.addingTimeInterval(100))
        let pinnedOlderActivity = ManifoldInference.ChatSession(
            title: "P-older-activity",
            updatedAt: now.addingTimeInterval(50),
            isPinned: true,
            pinnedAt: now.addingTimeInterval(900)   // pinned more recently
        )
        let pinnedRecentActivity = ManifoldInference.ChatSession(
            title: "P-recent-activity",
            updatedAt: now.addingTimeInterval(400),
            isPinned: true,
            pinnedAt: now.addingTimeInterval(800)   // pinned earlier
        )

        try await provider.insertSession(unpinnedRecent)
        try await provider.insertSession(unpinnedOld)
        try await provider.insertSession(pinnedOlderActivity)
        try await provider.insertSession(pinnedRecentActivity)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(
            fetched.map(\.title),
            ["P-older-activity", "P-recent-activity", "U-recent", "U-old"]
        )
    }

    // MARK: - Pagination interleaves correctly

    func test_pagination_pinnedFirstSpansPages() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Three pinned + two unpinned. Page size 2 must split the pinned
        // bucket across pages cleanly — pinned[2] surfaces on page 2 before
        // any unpinned record.
        for i in 0..<3 {
            try await provider.insertSession(ManifoldInference.ChatSession(
                title: "P\(i)",
                updatedAt: now,
                isPinned: true,
                pinnedAt: now.addingTimeInterval(TimeInterval(-i))
            ))
        }
        for i in 0..<2 {
            try await provider.insertSession(ManifoldInference.ChatSession(
                title: "U\(i)",
                updatedAt: now.addingTimeInterval(TimeInterval(-100 - i))
            ))
        }

        let page1 = try await provider.fetchSessions(offset: 0, limit: 2)
        let page2 = try await provider.fetchSessions(offset: 2, limit: 2)
        XCTAssertEqual(page1.map(\.title), ["P0", "P1"])
        XCTAssertEqual(page2.map(\.title), ["P2", "U0"])
    }
}
