@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference

/// Tests for the data model and layout logic that drives MessageBubbleView.
///
/// MessageBubbleView renders differently based on message role, streaming state,
/// pin status, and content. These tests verify the model behavior and computed
/// properties that determine the view's appearance.
@MainActor
final class MessageBubbleViewLogicTests: XCTestCase {

    private let sessionID = UUID()

    // MARK: - ChatMessageRecord construction

    func test_messageRecord_userRole_hasCorrectContent() {
        let msg = ChatMessageRecord(
            role: .user,
            content: "Hello, world!",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.content, "Hello, world!")
        XCTAssertEqual(msg.sessionID, sessionID)
    }

    func test_messageRecord_assistantRole_hasCorrectContent() {
        let msg = ChatMessageRecord(
            role: .assistant,
            content: "Once upon a time...",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.content, "Once upon a time...")
    }

    func test_messageRecord_systemRole_hasCorrectContent() {
        let msg = ChatMessageRecord(
            role: .system,
            content: "You are a helpful assistant.",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.role, .system)
        XCTAssertEqual(msg.content, "You are a helpful assistant.")
    }

    // MARK: - Content parts

    func test_messageRecord_contentViaPartsAccessor() {
        let msg = ChatMessageRecord(
            role: .user,
            content: "Test content",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.contentParts.count, 1, "Single text content should produce one part")
        if case .text(let text) = msg.contentParts.first {
            XCTAssertEqual(text, "Test content")
        } else {
            XCTFail("First content part should be .text")
        }
    }

    func test_messageRecord_settingContentReplacesAllParts() {
        var msg = ChatMessageRecord(
            role: .user,
            content: "Original",
            sessionID: sessionID
        )
        msg.content = "Updated"
        XCTAssertEqual(msg.content, "Updated")
        XCTAssertEqual(msg.contentParts.count, 1, "Setting content should replace all parts with a single text part")
    }

    func test_messageRecord_multiplePartsJoinForContent() {
        let msg = ChatMessageRecord(
            role: .assistant,
            contentParts: [.text("Hello"), .text(" world")],
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, "Hello world", "Content should be the concatenation of all text parts")
    }

    // MARK: - Empty content edge cases

    func test_messageRecord_emptyContent() {
        let msg = ChatMessageRecord(
            role: .assistant,
            content: "",
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, "")
        XCTAssertTrue(msg.contentParts.isEmpty || msg.content.isEmpty,
                       "Empty content message should have empty content accessor")
    }

    func test_messageRecord_veryLongContent() {
        let longContent = String(repeating: "A", count: 100_000)
        let msg = ChatMessageRecord(
            role: .user,
            content: longContent,
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content.count, 100_000, "Should handle very long content without truncation")
    }

    func test_messageRecord_specialCharacters() {
        let specialContent = "Hello <world> & \"friends\" — it's a 'test' with émojis 🎉 and CJK 你好"
        let msg = ChatMessageRecord(
            role: .user,
            content: specialContent,
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, specialContent, "Should preserve special characters exactly")
    }

    func test_messageRecord_multilineContent() {
        let multiline = "Line 1\nLine 2\n\nLine 4"
        let msg = ChatMessageRecord(
            role: .assistant,
            content: multiline,
            sessionID: sessionID
        )
        XCTAssertEqual(msg.content, multiline, "Should preserve newlines in content")
    }

    // MARK: - Token counts

    func test_messageRecord_completionTokens() {
        let msg = ChatMessageRecord(
            role: .assistant,
            content: "Response text",
            sessionID: sessionID,
            completionTokens: 42
        )
        XCTAssertEqual(msg.completionTokens, 42, "Should store completion token count")
    }

    func test_messageRecord_promptTokens() {
        let msg = ChatMessageRecord(
            role: .user,
            content: "Prompt text",
            sessionID: sessionID,
            promptTokens: 15
        )
        XCTAssertEqual(msg.promptTokens, 15, "Should store prompt token count")
    }

    func test_messageRecord_nilTokenCounts() {
        let msg = ChatMessageRecord(
            role: .assistant,
            content: "No tokens tracked",
            sessionID: sessionID
        )
        XCTAssertNil(msg.completionTokens, "Completion tokens should be nil by default")
        XCTAssertNil(msg.promptTokens, "Prompt tokens should be nil by default")
    }

    // MARK: - Role enumeration coverage

    func test_allRoles_areDistinct() {
        let roles: [MessageRole] = [.user, .assistant, .system]
        XCTAssertEqual(Set(roles).count, 3, "All three roles should be distinct values")
    }

    // MARK: - Streaming state data model

    /// Empty content produces empty contentParts — the view uses this to decide
    /// whether to show a typing indicator vs partial content.
    func test_emptyContent_hasEmptyParts() {
        let msg = ChatMessageRecord(role: .assistant, content: "", sessionID: sessionID)
        XCTAssertTrue(msg.content.isEmpty)
        XCTAssertTrue(msg.contentParts.isEmpty || msg.contentParts.allSatisfy {
            if case .text(let t) = $0 { return t.isEmpty } else { return false }
        }, "Empty content should produce empty or blank parts")
    }

    /// Non-empty content produces non-empty contentParts — the view uses this
    /// to show content + streaming cursor.
    func test_nonEmptyContent_hasNonEmptyParts() {
        let msg = ChatMessageRecord(role: .assistant, content: "Partial response...", sessionID: sessionID)
        XCTAssertFalse(msg.contentParts.isEmpty, "Non-empty content should produce non-empty parts")
    }

    // MARK: - Identifiable conformance

    func test_messageRecord_identifiable_uniqueIDs() {
        let msg1 = ChatMessageRecord(role: .user, content: "First", sessionID: sessionID)
        let msg2 = ChatMessageRecord(role: .user, content: "Second", sessionID: sessionID)
        XCTAssertNotEqual(msg1.id, msg2.id, "Each message should have a unique ID")
    }

    func test_messageRecord_hashable_sameIDsEqual() {
        let sharedID = UUID()
        let sharedTimestamp = Date(timeIntervalSince1970: 1000)
        let msg1 = ChatMessageRecord(id: sharedID, role: .user, content: "Content", timestamp: sharedTimestamp, sessionID: sessionID)
        let msg2 = ChatMessageRecord(id: sharedID, role: .user, content: "Content", timestamp: sharedTimestamp, sessionID: sessionID)
        XCTAssertEqual(msg1, msg2, "Messages with the same ID and content should be equal")
    }

    // MARK: - Timestamp

    func test_messageRecord_timestampDefaultsToNow() {
        let before = Date()
        let msg = ChatMessageRecord(role: .user, content: "Test", sessionID: sessionID)
        let after = Date()
        XCTAssertGreaterThanOrEqual(msg.timestamp, before, "Timestamp should be >= creation start time")
        XCTAssertLessThanOrEqual(msg.timestamp, after, "Timestamp should be <= creation end time")
    }

    func test_messageRecord_customTimestamp() {
        let customDate = Date(timeIntervalSince1970: 1000)
        let msg = ChatMessageRecord(
            role: .user,
            content: "Test",
            timestamp: customDate,
            sessionID: sessionID
        )
        XCTAssertEqual(msg.timestamp, customDate, "Should use the provided custom timestamp")
    }
}
