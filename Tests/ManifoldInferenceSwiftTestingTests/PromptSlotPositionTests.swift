import Testing
import Foundation
@testable import ManifoldInference

@Suite("PromptSlotPosition")
struct PromptSlotPositionTests {

    // MARK: - Sort ordering

    @Test func test_sortIndex_systemPreamble_isLowestAmongTopSlots() {
        let mc = 10
        #expect(
            PromptSlotPosition.systemPreamble.sortIndex(messageCount: mc) <
            PromptSlotPosition.contextSetup.sortIndex(messageCount: mc)
        )
    }

    @Test func test_sortIndex_contextSetup_comesBeforeAllHistorySlots() {
        let mc = 10
        let ctxIdx = PromptSlotPosition.contextSetup.sortIndex(messageCount: mc)
        #expect(ctxIdx < PromptSlotPosition.bottomOfHistory.sortIndex(messageCount: mc))
        #expect(ctxIdx < PromptSlotPosition.inline.sortIndex(messageCount: mc))
        #expect(ctxIdx < PromptSlotPosition.atDepth(1).sortIndex(messageCount: mc))
        #expect(ctxIdx < PromptSlotPosition.topOfHistory.sortIndex(messageCount: mc))
    }

    @Test func test_sortIndex_atDepth_orderedByN() {
        // Larger n means higher placement in history (further from latest turn),
        // so it should have a smaller sort index (appears earlier in the prompt).
        let mc = 10
        #expect(
            PromptSlotPosition.atDepth(5).sortIndex(messageCount: mc) <
            PromptSlotPosition.atDepth(1).sortIndex(messageCount: mc)
        )
    }

    @Test func test_sortIndex_topOfHistory_higherThanAtDepthMessageCountMinusOne() {
        // topOfHistory has the lowest history sort index (2), so it appears before
        // any atDepth(n) slot regardless of n.
        let mc = 5
        #expect(
            PromptSlotPosition.topOfHistory.sortIndex(messageCount: mc) <
            PromptSlotPosition.atDepth(mc - 1).sortIndex(messageCount: mc)
        )
    }

    // MARK: - Insertion depth

    @Test func test_insertionDepth_atDepthZero_equalsBottomOfHistory() {
        let mc = 5
        #expect(
            PromptSlotPosition.atDepth(0).insertionDepth(messageCount: mc) ==
            PromptSlotPosition.bottomOfHistory.insertionDepth(messageCount: mc)
        )
    }

    @Test func test_insertionDepth_topOfHistory_equalsMessageCount() {
        let mc = 7
        #expect(PromptSlotPosition.topOfHistory.insertionDepth(messageCount: mc) == mc)
    }

    @Test func test_insertionDepth_inline_equalsZero() {
        #expect(PromptSlotPosition.inline.insertionDepth(messageCount: 10) == 0)
    }

    @Test func test_insertionDepth_bottomOfHistory_equalsZero() {
        #expect(PromptSlotPosition.bottomOfHistory.insertionDepth(messageCount: 10) == 0)
    }

    // MARK: - isTopSlot

    @Test func test_isTopSlot_systemPreambleAndContextSetup_areTopSlots() {
        #expect(PromptSlotPosition.systemPreamble.isTopSlot)
        #expect(PromptSlotPosition.contextSetup.isTopSlot)
    }

    @Test func test_isTopSlot_historyPositions_areNotTopSlots() {
        #expect(!PromptSlotPosition.atDepth(0).isTopSlot)
        #expect(!PromptSlotPosition.atDepth(3).isTopSlot)
        #expect(!PromptSlotPosition.topOfHistory.isTopSlot)
        #expect(!PromptSlotPosition.bottomOfHistory.isTopSlot)
        #expect(!PromptSlotPosition.inline.isTopSlot)
    }

    @Test func test_decode_atDepth_rejectsNegativeDepth() throws {
        let json = #"{"type":"atDepth","depth":-1}"#
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PromptSlotPosition.self, from: data)
        }
    }

    // MARK: - Codable round-trip

    @Test func test_codable_roundTrip_allCases() throws {
        let cases: [PromptSlotPosition] = [
            .systemPreamble, .contextSetup, .atDepth(0), .atDepth(3),
            .topOfHistory, .bottomOfHistory, .inline,
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for position in cases {
            let data = try encoder.encode(position)
            let decoded = try decoder.decode(PromptSlotPosition.self, from: data)
            #expect(decoded == position)
        }
    }

    // MARK: - Assembler placement

    private func makeMessage(role: MessageRole, content: String) -> ChatMessage {
        ChatMessage(role: role, content: content, sessionID: UUID())
    }

    private struct CharTokenizer: TokenizerProvider {
        func tokenCount(_ text: String) -> Int { max(1, text.count) }
    }

    @Test func test_assembler_systemPreamble_appearsBeforeContextSetup() {
        let slots = [
            PromptSlot(id: "ctx", content: "context", position: .contextSetup, label: "Ctx"),
            PromptSlot(id: "pre", content: "preamble", position: .systemPreamble, label: "Pre"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 1000, tokenizer: CharTokenizer()
        )
        #expect(result.orderedSlots[0].id == "pre")
        #expect(result.orderedSlots[1].id == "ctx")
        #expect(result.messages[0].content == "preamble")
        #expect(result.messages[1].content == "context")
    }

    @Test func test_assembler_atDepth_insertedNFromBottom() {
        let messages = (0..<5).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "note", content: "note", position: .atDepth(2), label: "Note"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        let contents = result.messages.map { $0.content }
        if let noteIndex = contents.firstIndex(of: "note") {
            #expect(contents.count - noteIndex - 1 == 2)
        } else {
            Issue.record("note slot not found in messages")
        }
    }

    @Test func test_assembler_topOfHistory_appearsBeforeAllMessages() {
        let messages = (0..<3).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "top", content: "top note", position: .topOfHistory, label: "Top"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(result.messages.first?.content == "top note")
    }

    @Test func test_assembler_bottomOfHistory_appearsAfterAllMessages() {
        let messages = (0..<3).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "bottom", content: "bottom note", position: .bottomOfHistory, label: "Bottom"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(result.messages.last?.content == "bottom note")
    }

    @Test func test_assembler_atDepthZero_placedSameAsBottomOfHistory() {
        let messages = (0..<3).map { makeMessage(role: .user, content: "msg\($0)") }
        let r1 = PromptAssembler.assemble(
            slots: [PromptSlot(id: "a", content: "note", position: .atDepth(0), label: "A")],
            messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        let r2 = PromptAssembler.assemble(
            slots: [PromptSlot(id: "b", content: "note", position: .bottomOfHistory, label: "B")],
            messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(r1.messages.map { $0.content } == r2.messages.map { $0.content })
    }

    @Test func test_assembler_inline_placedAtEnd() {
        let messages = (0..<3).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "il", content: "inline note", position: .inline, label: "Inline"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        #expect(result.messages.last?.content == "inline note")
    }

    @Test func test_assembler_multipleAtDepth_insertionIndicesStable() {
        // Regression: with two slots at different depths, each slot should end up the
        // correct number of original messages from the bottom — inserting one slot must
        // not shift the target index of the other.
        let messages = (0..<5).map { makeMessage(role: .user, content: "msg\($0)") }
        let slots = [
            PromptSlot(id: "deep", content: "deep",    position: .atDepth(4), label: "Deep"),
            PromptSlot(id: "shallow", content: "shallow", position: .atDepth(1), label: "Shallow"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: CharTokenizer()
        )
        let contents = result.messages.map { $0.content }
        // "deep" should have 4 original messages after it; "shallow" should have 1.
        guard let deepIdx = contents.firstIndex(of: "deep"),
              let shallowIdx = contents.firstIndex(of: "shallow") else {
            Issue.record("slots not found in messages")
            return
        }
        let afterDeep    = contents[(deepIdx + 1)...].filter { $0.hasPrefix("msg") }.count
        let afterShallow = contents[(shallowIdx + 1)...].filter { $0.hasPrefix("msg") }.count
        #expect(afterDeep == 4)
        #expect(afterShallow == 1)
    }
}
