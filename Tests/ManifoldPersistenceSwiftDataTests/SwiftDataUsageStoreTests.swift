import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldRuntime
import ManifoldTestSupport

/// Integration tests for ``SwiftDataUsageStore``.
///
/// All tests use an in-memory SwiftData container — no mocking of the
/// persistence layer per ManifoldKit test conventions.
@MainActor
final class SwiftDataUsageStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var sut: SwiftDataUsageStore!

    override func setUp() async throws {
        container = try ModelContainerFactory.makeInMemoryContainer()
        sut = SwiftDataUsageStore(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        sut = nil
        container = nil
    }

    // MARK: - record(_:)

    func test_record_persistsInStore() async throws {
        let record = makeTurnRecord(promptTokens: 100, completionTokens: 50)
        try await sut.record(record)

        let fetched = try await sut.recentRecords(limit: 10)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, record.id)
        XCTAssertEqual(fetched[0].promptTokens, 100)
        XCTAssertEqual(fetched[0].completionTokens, 50)

        // Sabotage check: wrong count would fail the test.
        XCTAssertNotEqual(fetched.count, 0)
    }

    func test_record_multipleRecords_allPersisted() async throws {
        let r1 = makeTurnRecord(promptTokens: 10, completionTokens: 5)
        let r2 = makeTurnRecord(promptTokens: 20, completionTokens: 10)
        try await sut.record(r1)
        try await sut.record(r2)

        let fetched = try await sut.recentRecords(limit: 10)
        XCTAssertEqual(fetched.count, 2)
    }

    func test_record_roundTrips_allFields() async throws {
        let sessionID = UUID()
        let endpointID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let record = TurnUsage(
            id: UUID(),
            sessionID: sessionID,
            endpointID: endpointID,
            modelIdentifier: "claude-sonnet-4-6",
            timestamp: timestamp,
            promptTokens: 200,
            completionTokens: 75,
            cachedInputTokens: 50,
            cacheWriteTokens: 10
        )
        try await sut.record(record)

        let records = try await sut.recentRecords(limit: 1)
        let fetched = try XCTUnwrap(records.first)
        XCTAssertEqual(fetched.sessionID, sessionID)
        XCTAssertEqual(fetched.endpointID, endpointID)
        XCTAssertEqual(fetched.modelIdentifier, "claude-sonnet-4-6")
        XCTAssertEqual(fetched.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(fetched.promptTokens, 200)
        XCTAssertEqual(fetched.completionTokens, 75)
        XCTAssertEqual(fetched.cachedInputTokens, 50)
        XCTAssertEqual(fetched.cacheWriteTokens, 10)
    }

    // MARK: - recentRecords(limit:)

    func test_recentRecords_emptyStore_returnsEmpty() async throws {
        let fetched = try await sut.recentRecords(limit: 10)
        XCTAssertTrue(fetched.isEmpty)
    }

    func test_recentRecords_reverseChronologicalOrder() async throws {
        let past = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)

        let older = makeTurnRecord(timestamp: past, promptTokens: 1, completionTokens: 1)
        let newer = makeTurnRecord(timestamp: recent, promptTokens: 2, completionTokens: 2)

        // Insert in chronological order; expect reverse-chron return.
        try await sut.record(older)
        try await sut.record(newer)

        let fetched = try await sut.recentRecords(limit: 10)
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched[0].timestamp, recent, "Most recent record should be first.")
        XCTAssertEqual(fetched[1].timestamp, past)
    }

    func test_recentRecords_respectsLimit() async throws {
        for i in 0..<5 {
            try await sut.record(makeTurnRecord(
                timestamp: Date(timeIntervalSince1970: Double(i) * 100),
                promptTokens: i,
                completionTokens: i
            ))
        }
        let fetched = try await sut.recentRecords(limit: 3)
        XCTAssertEqual(fetched.count, 3)
    }

    // MARK: - summary(sinceDays:)

    func test_summary_noRecords_returnsZeroTotals() async throws {
        let s = try await sut.summary(sinceDays: 30)
        XCTAssertEqual(s.totalPromptTokens, 0)
        XCTAssertEqual(s.totalCompletionTokens, 0)
        XCTAssertEqual(s.totalCachedInputTokens, 0)
        XCTAssertEqual(s.totalCacheWriteTokens, 0)
        XCTAssertEqual(s.turnCount, 0)
    }

    func test_summary_sumsTokensCorrectly() async throws {
        try await sut.record(makeTurnRecord(promptTokens: 100, completionTokens: 50, cachedInputTokens: 20, cacheWriteTokens: 5))
        try await sut.record(makeTurnRecord(promptTokens: 200, completionTokens: 80, cachedInputTokens: 30, cacheWriteTokens: 10))

        let s = try await sut.summary(sinceDays: 30)
        XCTAssertEqual(s.totalPromptTokens, 300)
        XCTAssertEqual(s.totalCompletionTokens, 130)
        XCTAssertEqual(s.totalCachedInputTokens, 50)
        XCTAssertEqual(s.totalCacheWriteTokens, 15)
        XCTAssertEqual(s.turnCount, 2)

        // Sabotage check: totals cannot be zero when records were inserted.
        XCTAssertGreaterThan(s.totalPromptTokens, 0)
    }

    func test_summary_excludesRecordsOlderThanSinceDays() async throws {
        // Old record: 10 days ago (beyond 7-day window).
        let old = Date().addingTimeInterval(-10 * 86_400)
        try await sut.record(makeTurnRecord(timestamp: old, promptTokens: 999, completionTokens: 999))

        // Recent record: within 7-day window.
        try await sut.record(makeTurnRecord(promptTokens: 50, completionTokens: 20))

        let s = try await sut.summary(sinceDays: 7)
        XCTAssertEqual(s.totalPromptTokens, 50)
        XCTAssertEqual(s.totalCompletionTokens, 20)
        XCTAssertEqual(s.turnCount, 1)
    }

    // MARK: - summary(forEndpoint:sinceDays:)

    func test_summaryForEndpoint_filtersCorrectly() async throws {
        let endpointA = UUID()
        let endpointB = UUID()

        try await sut.record(TurnUsage(
            sessionID: UUID(), endpointID: endpointA, modelIdentifier: "gpt-4o",
            promptTokens: 100, completionTokens: 50))
        try await sut.record(TurnUsage(
            sessionID: UUID(), endpointID: endpointB, modelIdentifier: "claude-3-5-sonnet",
            promptTokens: 200, completionTokens: 80))
        try await sut.record(TurnUsage(
            sessionID: UUID(), endpointID: endpointA, modelIdentifier: "gpt-4o",
            promptTokens: 50, completionTokens: 25))

        let sA = try await sut.summary(forEndpoint: endpointA, sinceDays: 30)
        XCTAssertEqual(sA.totalPromptTokens, 150)
        XCTAssertEqual(sA.totalCompletionTokens, 75)
        XCTAssertEqual(sA.turnCount, 2)

        let sB = try await sut.summary(forEndpoint: endpointB, sinceDays: 30)
        XCTAssertEqual(sB.totalPromptTokens, 200)
        XCTAssertEqual(sB.turnCount, 1)

        // Unknown endpoint should yield zeros.
        let sUnknown = try await sut.summary(forEndpoint: UUID(), sinceDays: 30)
        XCTAssertEqual(sUnknown.turnCount, 0)
    }

    // MARK: - Schema V5→V6 migration

    /// Verifies that a container created against the current schema can still
    /// read V5 model types (sessions, messages) alongside the new V6
    /// TurnUsageModel. This guards against additive migration regressions
    /// where older model rows become unreadable after a schema bump.
    func test_schemaV6_existingSessionDataRemainsReadable() async throws {
        // Insert a V5-era ChatSession and ChatMessage into the current schema
        // container (all V5 types are carried forward in V6).
        let context = container.mainContext
        let session = ChatSession(title: "Migration test session")
        context.insert(session)
        let message = ChatMessage(role: .user, content: "Hello", sessionID: session.id)
        context.insert(message)
        try context.save()

        // Now also insert a V6-only TurnUsageModel.
        let usageRecord = makeTurnRecord(promptTokens: 42, completionTokens: 21)
        try await sut.record(usageRecord)

        // Both old and new rows should be retrievable.
        let sessions = try context.fetch(FetchDescriptor<ChatSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].title, "Migration test session")

        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(messages.count, 1)

        let usageRows = try context.fetch(FetchDescriptor<TurnUsageModel>())
        XCTAssertEqual(usageRows.count, 1)
        XCTAssertEqual(usageRows[0].promptTokens, 42)
    }

    // MARK: - Helpers

    private func makeTurnRecord(
        timestamp: Date = Date(),
        promptTokens: Int = 10,
        completionTokens: Int = 5,
        cachedInputTokens: Int? = nil,
        cacheWriteTokens: Int? = nil
    ) -> TurnUsage {
        TurnUsage(
            sessionID: UUID(),
            endpointID: nil,
            modelIdentifier: "test-model",
            timestamp: timestamp,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }
}
