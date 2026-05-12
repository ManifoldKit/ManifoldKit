import XCTest
@testable import ManifoldRuntime

/// Unit tests for ``TurnUsageRecord`` and ``UsageSummary`` value semantics.
///
/// These types are part of the port surface and must round-trip through
/// `Codable` and expose the right defaults. A compile-time guard ensures
/// the ``UsageSummary`` init stays in sync with the stored-property set.
final class UsageStoreTypesTests: XCTestCase {

    // MARK: - TurnUsageRecord

    func test_turnUsageRecord_defaultsToNilOptionals() {
        let record = TurnUsageRecord(
            sessionID: UUID(),
            endpointID: nil,
            modelIdentifier: "llama-3",
            promptTokens: 10,
            completionTokens: 5
        )
        XCTAssertNil(record.cachedInputTokens)
        XCTAssertNil(record.cacheWriteTokens)
        XCTAssertNil(record.endpointID)
    }

    func test_turnUsageRecord_defaultTimestampIsRecent() {
        let before = Date()
        let record = TurnUsageRecord(
            sessionID: UUID(),
            endpointID: nil,
            modelIdentifier: "test",
            promptTokens: 1,
            completionTokens: 1
        )
        let after = Date()
        XCTAssertGreaterThanOrEqual(record.timestamp, before)
        XCTAssertLessThanOrEqual(record.timestamp, after)
    }

    func test_turnUsageRecord_defaultIDIsNonNil() {
        let r1 = TurnUsageRecord(
            sessionID: UUID(), endpointID: nil, modelIdentifier: "m",
            promptTokens: 1, completionTokens: 1)
        let r2 = TurnUsageRecord(
            sessionID: UUID(), endpointID: nil, modelIdentifier: "m",
            promptTokens: 1, completionTokens: 1)
        XCTAssertNotEqual(r1.id, r2.id, "Each call to init should produce a distinct UUID.")
    }

    func test_turnUsageRecord_codableRoundTrip() throws {
        let original = TurnUsageRecord(
            id: UUID(),
            sessionID: UUID(),
            endpointID: UUID(),
            modelIdentifier: "gpt-4o",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            promptTokens: 512,
            completionTokens: 128,
            cachedInputTokens: 64,
            cacheWriteTokens: 8
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TurnUsageRecord.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.sessionID, original.sessionID)
        XCTAssertEqual(decoded.endpointID, original.endpointID)
        XCTAssertEqual(decoded.modelIdentifier, original.modelIdentifier)
        XCTAssertEqual(
            decoded.timestamp.timeIntervalSince1970,
            original.timestamp.timeIntervalSince1970,
            accuracy: 1.0
        )
        XCTAssertEqual(decoded.promptTokens, original.promptTokens)
        XCTAssertEqual(decoded.completionTokens, original.completionTokens)
        XCTAssertEqual(decoded.cachedInputTokens, original.cachedInputTokens)
        XCTAssertEqual(decoded.cacheWriteTokens, original.cacheWriteTokens)
    }

    // MARK: - UsageSummary

    func test_usageSummary_storedPropertiesMatchInit() {
        let s = UsageSummary(
            totalPromptTokens: 300,
            totalCompletionTokens: 150,
            totalCachedInputTokens: 40,
            totalCacheWriteTokens: 10,
            turnCount: 5
        )
        XCTAssertEqual(s.totalPromptTokens, 300)
        XCTAssertEqual(s.totalCompletionTokens, 150)
        XCTAssertEqual(s.totalCachedInputTokens, 40)
        XCTAssertEqual(s.totalCacheWriteTokens, 10)
        XCTAssertEqual(s.turnCount, 5)
    }

    func test_usageSummary_zeroSummary() {
        let s = UsageSummary(
            totalPromptTokens: 0,
            totalCompletionTokens: 0,
            totalCachedInputTokens: 0,
            totalCacheWriteTokens: 0,
            turnCount: 0
        )
        XCTAssertEqual(s.turnCount, 0)
        XCTAssertEqual(s.totalPromptTokens, 0)
    }
}
