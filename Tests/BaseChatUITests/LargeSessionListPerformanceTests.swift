@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Baseline performance for the paginated session sidebar at 1000 sessions
/// and ~50K messages. These measurements catch regressions in the SwiftData
/// fetch path: an accidental fetch-all-then-filter on the message search
/// would blow the message-search baseline by orders of magnitude.
///
/// Each test seeds the entire fixture before the `measure` block so the
/// timed work is the operation under test, not the fixture build.
@MainActor
final class LargeSessionListPerformanceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var persistence: SwiftDataPersistenceProvider!
    private var vm: SessionManagerViewModel!

    private let sessionCount = 1_000
    private let messagesPerSession = 50

    override func setUp() async throws {
        try await super.setUp()
        // Slow XCTMeasure baselines (~65s combined). Skipped in main CI to keep
        // PR feedback fast; nightly job sets RUN_SLOW_TESTS=1. Always runs locally.
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["CI"] == "true" && env["RUN_SLOW_TESTS"] != "1",
                      "Slow perf baseline — runs in nightly CI only. Set RUN_SLOW_TESTS=1 to force.")
        container = try makeInMemoryContainer()
        context = container.mainContext
        persistence = SwiftDataPersistenceProvider(modelContext: context)
        vm = SessionManagerViewModel()
        vm.configure(persistence: persistence)
        try await seedLargeFixture()
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        persistence = nil
        vm = nil
        try await super.tearDown()
    }

    /// Initial sidebar render — only the first page should be materialised.
    func test_perf_initialFirstPageRender() {
        measure {
            let fresh = SessionManagerViewModel()
            fresh.configure(persistence: persistence)
            XCTAssertEqual(fresh.sessions.count, SessionManagerViewModel.sessionsPageSize)
        }
    }

    /// Cost of advancing one page on scroll. With SwiftData's fetchOffset,
    /// this should stay flat regardless of where in the list the user scrolls.
    func test_perf_paginationStep() async {
        // Pre-load to the same baseline as a real scroll session would.
        await vm.loadSessions()

        measure {
            // Reset to the first page each iteration so the measurement is
            // independent — otherwise every iteration after the first would
            // be a no-op once the list is exhausted.
            let exp = expectation(description: "pagination step")
            Task { @MainActor in
                await vm.loadSessions()
                await vm.loadNextPage()
                await vm.loadNextPage()
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30)
        }
    }

    /// End-to-end message search latency at 50K messages — the path users
    /// hit when they type into the search field with "Messages" scope.
    func test_perf_messageSearchLatency() async {
        measure {
            let exp = expectation(description: "message search")
            Task { @MainActor in
                await vm.runMessageSearch("findme")
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30)
            XCTAssertFalse(vm.messageMatchSessions.isEmpty,
                           "Fixture must seed at least one matching message")
        }
    }

    // MARK: - Fixture

    /// Seeds 1000 sessions and 50K messages, of which ~10 contain the
    /// "findme" needle so the search test always has work to do.
    private func seedLargeFixture() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var sessionIDs: [UUID] = []
        sessionIDs.reserveCapacity(sessionCount)
        for i in 0..<sessionCount {
            let record = ChatSessionRecord(
                title: "Session \(i)",
                updatedAt: base.addingTimeInterval(Double(i))
            )
            try await persistence.insertSession(record)
            sessionIDs.append(record.id)
        }

        // Spread "findme" across ~10 sessions so the search test is meaningful.
        let needleStride = max(1, sessionCount / 10)
        for (i, id) in sessionIDs.enumerated() {
            for j in 0..<messagesPerSession {
                let isNeedle = (i % needleStride == 0) && j == 0
                let body = isNeedle
                    ? "Earlier we discussed findme as a topic worth revisiting."
                    : "Generic chat content for session \(i) message \(j)."
                try await persistence.insertMessage(ChatMessageRecord(
                    role: j.isMultiple(of: 2) ? .user : .assistant,
                    content: body,
                    timestamp: base.addingTimeInterval(Double(i * messagesPerSession + j)),
                    sessionID: id
                ))
            }
        }
    }
}
