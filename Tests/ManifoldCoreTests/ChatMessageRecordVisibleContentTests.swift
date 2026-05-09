import XCTest
import ManifoldInference

/// Tests for `ChatMessageRecord.hasVisibleContent` and the interaction between
/// `.thinking` parts and the `content` property.
final class ChatMessageRecordVisibleContentTests: XCTestCase {

    // MARK: - 1. Thinking-only message has no visible content

    func test_hasVisibleContent_false_forThinkingOnly() {
        let record = ChatMessageRecord(
            role: .assistant,
            contentParts: [.thinking("I reasoned about this."), .thinking("And then some more.")],
            sessionID: UUID()
        )

        XCTAssertFalse(record.hasVisibleContent,
            "A message containing only .thinking parts must report hasVisibleContent == false")

        // Sabotage check: if hasVisibleContent returned true unconditionally, a thinking-only
        // message would incorrectly appear to have content, breaking the UI visibility check.
    }

    // MARK: - 2. Text-only message has visible content

    func test_hasVisibleContent_true_forText() {
        let record = ChatMessageRecord(
            role: .assistant,
            content: "Here is the answer.",
            sessionID: UUID()
        )

        XCTAssertTrue(record.hasVisibleContent,
            "A message with a .text part must report hasVisibleContent == true")
    }

    // MARK: - 3. Mixed parts — thinking + text

    func test_hasVisibleContent_true_forMixed() {
        let record = ChatMessageRecord(
            role: .assistant,
            contentParts: [.thinking("internal reasoning"), .text("The answer is 42.")],
            sessionID: UUID()
        )

        XCTAssertTrue(record.hasVisibleContent,
            "A message with both .thinking and .text parts must report hasVisibleContent == true")

        // Sabotage check: if hasVisibleContent only checked the first part, a message
        // starting with .thinking would incorrectly return false.
    }

    // MARK: - 4. content property excludes thinking parts

    func test_contentProperty_excludesThinking() {
        let record = ChatMessageRecord(
            role: .assistant,
            contentParts: [.thinking("internal reasoning"), .text("answer")],
            sessionID: UUID()
        )

        XCTAssertEqual(record.content, "answer",
            ".content must concatenate only .text parts, excluding .thinking parts")

        // Sabotage check: if textContent on .thinking returned the thinking string,
        // content would be "internal reasoninganswer" instead of "answer".
    }

    func test_contentProperty_withMultipleTextParts_concatenatesBoth() {
        let record = ChatMessageRecord(
            role: .assistant,
            contentParts: [
                .thinking("step 1"),
                .text("Part A "),
                .thinking("step 2"),
                .text("Part B"),
            ],
            sessionID: UUID()
        )

        XCTAssertEqual(record.content, "Part A Part B",
            ".content must concatenate all .text parts in order, skipping .thinking parts")
    }

    // MARK: - 5. MessagePart.thinking Codable round-trip

    func test_messagePart_thinking_codableRoundTrip() throws {
        let part = MessagePart.thinking("hello thinking")
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part],
            ".thinking MessagePart must survive a Codable encode/decode round trip intact")

        // Sabotage check: if the Codable implementation for .thinking fell back to
        // .text, the decoded value would be .text("hello thinking") ≠ .thinking("hello thinking").
    }

    func test_messagePart_thinkingContent_accessor() {
        let part = MessagePart.thinking("reasoning text")
        XCTAssertEqual(part.thinkingContent, "reasoning text",
            ".thinkingContent accessor must return the associated string")
        XCTAssertNil(part.textContent,
            ".textContent must return nil for a .thinking part (it is not visible text)")
    }

    func test_messagePart_text_thinkingContent_isNil() {
        let part = MessagePart.text("visible")
        XCTAssertNil(part.thinkingContent,
            ".thinkingContent must return nil for a .text part")
    }
}
