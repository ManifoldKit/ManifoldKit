@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Direct unit coverage of ``TurnPreparation`` pure helpers and the
/// history-shaper validation rules extracted from ConversationTurnExecutor
/// (#1957 Priority 3). Full prepareHistory/prepareGeneration paths remain
/// covered by ConversationRuntimeTurnPreparationTests + characterization
/// goldens; these pin the now-isolated seams.
final class TurnPreparationTests: XCTestCase {

    // MARK: composeSystemPrompt

    func test_composeSystemPrompt_nilBase_noSlots_returnsNil() {
        XCTAssertNil(TurnPreparation.composeSystemPrompt(nil, slots: []))
    }

    func test_composeSystemPrompt_nilBase_withSlots_returnsJoinedSlots() {
        let slots = [
            PromptSlot(id: "a", content: "slot-a", label: "A"),
            PromptSlot(id: "b", content: "slot-b", label: "B")
        ]
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt(nil, slots: slots),
            "slot-a\n\nslot-b"
        )
    }

    func test_composeSystemPrompt_baseOnly_returnsBase() {
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt("you are helpful", slots: []),
            "you are helpful"
        )
    }

    func test_composeSystemPrompt_emptyBase_withSlots_returnsSlots() {
        let slots = [PromptSlot(id: "a", content: "only-slot", label: "A")]
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt("", slots: slots),
            "only-slot"
        )
    }

    func test_composeSystemPrompt_baseAndSlots_joinsWithBlankLine() {
        let slots = [PromptSlot(id: "a", content: "ctx", label: "A")]
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt("base", slots: slots),
            "base\n\nctx"
        )
    }

    func test_composeSystemPrompt_disabledAndEmptySlots_areSkipped() {
        let slots = [
            PromptSlot(id: "on", content: "keep", label: "On"),
            PromptSlot(id: "off", content: "drop", isEnabled: false, label: "Off"),
            PromptSlot(id: "empty", content: "", label: "Empty")
        ]
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt("base", slots: slots),
            "base\n\nkeep"
        )
    }

    // MARK: validateShapedHistory

    func test_validateShapedHistory_identity_passes() throws {
        let sid = UUID()
        let a = ChatMessage(role: .user, content: "a", sessionID: sid)
        let b = ChatMessage(role: .assistant, content: "b", sessionID: sid)
        try TurnPreparation.validateShapedHistory([a, b], against: [a, b])
    }

    func test_validateShapedHistory_subsetPreservingOrder_passes() throws {
        let sid = UUID()
        let a = ChatMessage(role: .user, content: "a", sessionID: sid)
        let b = ChatMessage(role: .assistant, content: "b", sessionID: sid)
        let c = ChatMessage(role: .user, content: "c", sessionID: sid)
        try TurnPreparation.validateShapedHistory([a, c], against: [a, b, c])
    }

    func test_validateShapedHistory_duplicateIDs_throws() {
        let a = ChatMessage(role: .user, content: "a", sessionID: UUID())
        XCTAssertThrowsError(
            try TurnPreparation.validateShapedHistory([a, a], against: [a])
        )
    }

    func test_validateShapedHistory_nonCanonicalID_throws() {
        let sid = UUID()
        let a = ChatMessage(role: .user, content: "a", sessionID: sid)
        let foreign = ChatMessage(role: .user, content: "x", sessionID: sid)
        XCTAssertThrowsError(
            try TurnPreparation.validateShapedHistory([foreign], against: [a])
        )
    }

    func test_validateShapedHistory_orderViolation_throws() {
        let sid = UUID()
        let a = ChatMessage(role: .user, content: "a", sessionID: sid)
        let b = ChatMessage(role: .assistant, content: "b", sessionID: sid)
        XCTAssertThrowsError(
            try TurnPreparation.validateShapedHistory([b, a], against: [a, b])
        )
    }
}
