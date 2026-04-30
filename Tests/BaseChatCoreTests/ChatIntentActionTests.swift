import XCTest
@testable import BaseChatRuntime

final class ChatIntentActionTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_codable_roundTrips_continueSession() throws {
        try assertRoundTrip(.continueSession)
    }

    func test_codable_roundTrips_startNewSession() throws {
        try assertRoundTrip(.startNewSession)
    }

    func test_codable_roundTrips_readLastMessage() throws {
        try assertRoundTrip(.readLastMessage)
    }

    func test_codable_roundTrips_summariseSession() throws {
        try assertRoundTrip(.summariseSession)
    }

    /// Catches the case where a future contributor adds a case but forgets
    /// to update the dispatch / persistence sites that assume the existing
    /// vocabulary.
    func test_codable_roundTrips_allCases() throws {
        let allCases: [ChatIntentAction] = [
            .continueSession,
            .startNewSession,
            .readLastMessage,
            .summariseSession,
        ]
        for action in allCases {
            try assertRoundTrip(action)
        }
    }

    // MARK: - Equatable

    func test_equatable_sameCase_isEqual() {
        XCTAssertEqual(ChatIntentAction.continueSession, .continueSession)
        XCTAssertEqual(ChatIntentAction.startNewSession, .startNewSession)
        XCTAssertEqual(ChatIntentAction.readLastMessage, .readLastMessage)
        XCTAssertEqual(ChatIntentAction.summariseSession, .summariseSession)
    }

    func test_equatable_differentCases_areNotEqual() {
        XCTAssertNotEqual(ChatIntentAction.continueSession, .startNewSession)
        XCTAssertNotEqual(ChatIntentAction.continueSession, .readLastMessage)
        XCTAssertNotEqual(ChatIntentAction.continueSession, .summariseSession)
        XCTAssertNotEqual(ChatIntentAction.startNewSession, .readLastMessage)
        XCTAssertNotEqual(ChatIntentAction.startNewSession, .summariseSession)
        XCTAssertNotEqual(ChatIntentAction.readLastMessage, .summariseSession)
    }

    // MARK: - Helpers

    private func assertRoundTrip(
        _ action: ChatIntentAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(action)
        let decoded = try decoder.decode(ChatIntentAction.self, from: data)
        XCTAssertEqual(decoded, action, file: file, line: line)
    }
}
