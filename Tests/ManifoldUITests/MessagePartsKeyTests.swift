@preconcurrency import XCTest
@testable import ManifoldUI
@testable import ManifoldInference

/// Verifies `MessagePartsView.keyedParts` produces stable, unique per-part
/// identities for `ForEach`.
///
/// Regression target: #1496. The view previously keyed `ForEach` on the array
/// offset. Because the streaming coordinator inserts `.thinking` *before* the
/// first text part, an offset key renumbered every following part's identity on
/// insert — tearing down and rebuilding `AssistantMarkdownView` /
/// `ToolInvocationView` instead of moving them. The kind+ordinal scheme keeps
/// the existing parts' keys fixed across that insertion.
@MainActor
final class MessagePartsKeyTests: XCTestCase {

    private func call(_ id: String) -> MessagePart {
        .toolCall(ToolCall(id: id, toolName: "search", arguments: "{}"))
    }

    private func result(_ callId: String) -> MessagePart {
        .toolResult(ToolResult(callId: callId, content: "ok"))
    }

    // MARK: - Uniqueness

    func test_keys_areUnique_acrossMixedParts() {
        let parts: [MessagePart] = [
            .thinking("reasoning"),
            .text("first"),
            .text("second"),
            call("c1"),
            result("c1"),
            .text("third"),
        ]

        let keys = MessagePartsView.keyedParts(parts).map(\.key)

        XCTAssertEqual(keys.count, parts.count)
        XCTAssertEqual(Set(keys).count, keys.count, "Every part must get a distinct key")
    }

    func test_twoTextParts_getDistinctKeys() {
        let parts: [MessagePart] = [.text("a"), .text("b")]
        let keys = MessagePartsView.keyedParts(parts).map(\.key)
        XCTAssertEqual(keys, ["text-0", "text-1"])
    }

    func test_toolParts_keyOnCallID() {
        let parts: [MessagePart] = [call("abc"), result("abc")]
        let keys = MessagePartsView.keyedParts(parts).map(\.key)
        XCTAssertEqual(keys, ["tool:call:abc", "tool:result:abc"])
    }

    // MARK: - The #1496 regression: non-terminal thinking insert

    func test_insertingThinkingAheadOfText_preservesTextKeys() {
        // Mirrors the coordinator's `.thinkingStarted` mutation: a `.thinking`
        // part is inserted before the first text part mid-stream.
        let before: [MessagePart] = [
            .text("hello"),
            .text("world"),
        ]
        let after: [MessagePart] = [
            .thinking(""),       // inserted ahead of the text parts
            .text("hello"),
            .text("world"),
        ]

        let beforeKeys = Dictionary(
            uniqueKeysWithValues: MessagePartsView.keyedParts(before).enumerated().map { ($0.offset, $0.element.key) }
        )
        let afterKeyed = MessagePartsView.keyedParts(after)

        // The two text parts keep "text-0"/"text-1" — the thinking insert does
        // NOT renumber them (the bug an offset key would introduce).
        XCTAssertEqual(beforeKeys[0], "text-0")
        XCTAssertEqual(beforeKeys[1], "text-1")

        XCTAssertEqual(afterKeyed[0].key, "thinking-0")
        XCTAssertEqual(afterKeyed[1].key, "text-0", "First text part keeps its identity after a non-terminal thinking insert")
        XCTAssertEqual(afterKeyed[2].key, "text-1", "Second text part keeps its identity after a non-terminal thinking insert")
    }

    func test_toolKeysStable_whenThinkingInsertedAhead() {
        let before: [MessagePart] = [call("c1"), result("c1")]
        let after: [MessagePart] = [.thinking("x"), call("c1"), result("c1")]

        let beforeKeys = MessagePartsView.keyedParts(before).map(\.key)
        let afterKeys = MessagePartsView.keyedParts(after).map(\.key)

        XCTAssertEqual(beforeKeys, ["tool:call:c1", "tool:result:c1"])
        // Tool keys are id-derived, so they are untouched regardless of position.
        XCTAssertEqual(Array(afterKeys.dropFirst()), beforeKeys)
    }
}
