import Testing
import Foundation
@testable import ManifoldInference

/// Deterministic tokenizer: 1 token per character.
private struct CharTokenizer: TokenizerProvider {
    func tokenCount(_ text: String) -> Int {
        max(1, text.count)
    }
}

@Suite("PromptAssembler")
struct PromptAssemblerTests {

    private let tok = CharTokenizer()

    private func makeMessage(role: MessageRole, content: String) -> ChatMessageRecord {
        ChatMessageRecord(role: role, content: content, sessionID: UUID())
    }

    // MARK: - Basic

    @Test func test_assemble_emptyInputs_returnsEmptyPrompt() {
        let result = PromptAssembler.assemble(
            slots: [], messages: [], systemPrompt: nil,
            contextSize: 1000, tokenizer: tok
        )
        #expect(result.orderedSlots.isEmpty)
        #expect(result.messages.isEmpty)
        #expect(result.totalTokens == 0)
    }

    @Test func test_assemble_systemPrompt_createsSlotAtDepthZero() {
        let result = PromptAssembler.assemble(
            slots: [], messages: [], systemPrompt: "Be helpful",
            contextSize: 1000, tokenizer: tok
        )
        #expect(result.orderedSlots.count == 1)
        #expect(result.orderedSlots[0].id == "system")
        #expect(result.orderedSlots[0].position == .systemPreamble)
        #expect(result.orderedSlots[0].content == "Be helpful")
    }

    @Test func test_assemble_messagesPreserveOrder() {
        let messages = [
            makeMessage(role: .user, content: "Hello"),
            makeMessage(role: .assistant, content: "Hi"),
            makeMessage(role: .user, content: "How?"),
        ]
        let result = PromptAssembler.assemble(
            slots: [], messages: messages, systemPrompt: nil,
            contextSize: 1000, tokenizer: tok
        )
        #expect(result.messages.count == 3)
        #expect(result.messages[0].content == "Hello")
        #expect(result.messages[1].content == "Hi")
        #expect(result.messages[2].content == "How?")
    }

    // MARK: - Slots

    @Test func test_assemble_disabledSlots_areSkipped() {
        let slots = [
            PromptSlot(id: "a", content: "enabled", isEnabled: true, label: "A"),
            PromptSlot(id: "b", content: "disabled", isEnabled: false, label: "B"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 1000, tokenizer: tok
        )
        #expect(result.orderedSlots.count == 1)
        #expect(result.orderedSlots[0].id == "a")
    }

    @Test func test_assemble_slotsAreSortedByPosition() {
        // atDepth(5) is higher in history (5 messages from bottom) than atDepth(1),
        // so it should appear first (lower sort index) in the assembled prompt.
        let messages = (0..<6).map {
            ChatMessageRecord(role: .user, content: "msg\($0)", sessionID: UUID())
        }
        let slots = [
            PromptSlot(id: "deep", content: "deep", position: .atDepth(5), label: "Deep"),
            PromptSlot(id: "shallow", content: "shallow", position: .atDepth(1), label: "Shallow"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: tok
        )
        #expect(result.orderedSlots[0].id == "deep")
        #expect(result.orderedSlots[1].id == "shallow")
    }

    @Test func test_assemble_tokenBudget_capsSlotTokens() {
        let slots = [
            PromptSlot(id: "big", content: String(repeating: "x", count: 100), tokenBudget: 10, label: "Big"),
        ]
        let result = PromptAssembler.assemble(
            slots: slots, messages: [], systemPrompt: nil,
            contextSize: 1000, tokenizer: tok
        )
        #expect(result.budgetBreakdown["big"] == 10)
    }

    // MARK: - Budget & Trimming

    @Test func test_assemble_historyTrimmedWhenSlotsConsumeSpace() {
        let slots = [
            PromptSlot(id: "char", content: String(repeating: "c", count: 50), label: "Char"),
        ]
        let messages = (0..<10).map { i in
            makeMessage(role: .user, content: String(repeating: "m", count: 10))
        }
        // contextSize=100, slot=50, responseBuffer=512 default → no room for messages
        // Use small buffer instead
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 100, responseBuffer: 10, tokenizer: tok
        )
        // Available for messages: 100 - 50 - 10 = 40 tokens = 4 history messages of 10 chars
        // result.messages includes the contextSetup slot as a system message too
        let historyMessages = result.messages.filter { $0.role != "system" }
        #expect(historyMessages.count == 4)
    }

    @Test func test_assemble_alwaysKeepsLastMessage() {
        let messages = [
            makeMessage(role: .user, content: String(repeating: "x", count: 200)),
        ]
        // Context is tiny but last message should still be kept
        let result = PromptAssembler.assemble(
            slots: [], messages: messages, systemPrompt: nil,
            contextSize: 10, responseBuffer: 5, tokenizer: tok
        )
        #expect(result.messages.count == 1)
    }

    // MARK: - Depth Insertion

    @Test func test_assemble_atDepthSlot_insertedCorrectly() {
        let slots = [
            PromptSlot(id: "note", content: "author note", position: .atDepth(2), label: "Author's Note"),
        ]
        let messages = (0..<5).map { i in
            makeMessage(role: .user, content: "msg\(i)")
        }
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: tok
        )
        // atDepth(2) = 2 turns from bottom. Messages: msg0, msg1, msg2, [note], msg3, msg4
        let contents = result.messages.map { $0.content }
        #expect(contents.contains("author note"))
        if let noteIndex = contents.firstIndex(of: "author note") {
            // Should be 2 from the end (before last 2 messages)
            #expect(contents.count - noteIndex - 1 == 2)
        }
    }

    // MARK: - Budget Breakdown

    @Test func test_assemble_budgetBreakdown_includesAllSlots() {
        let slots = [
            PromptSlot(id: "a", content: "aaaa", label: "A"),
            PromptSlot(id: "b", content: "bb", label: "B"),
        ]
        let messages = [makeMessage(role: .user, content: "hello")]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: "sys",
            contextSize: 10000, responseBuffer: 0, tokenizer: tok
        )
        #expect(result.budgetBreakdown["a"] == 4)
        #expect(result.budgetBreakdown["b"] == 2)
        #expect(result.budgetBreakdown["system"] == 3)
        #expect(result.budgetBreakdown["history"] == 5)
    }

    @Test func test_assemble_totalTokens_matchesBreakdownSum() {
        let slots = [
            PromptSlot(id: "x", content: "xxxx", label: "X"),
        ]
        let messages = [makeMessage(role: .user, content: "hello")]
        let result = PromptAssembler.assemble(
            slots: slots, messages: messages, systemPrompt: nil,
            contextSize: 10000, responseBuffer: 0, tokenizer: tok
        )
        let breakdownSum = result.budgetBreakdown.values.reduce(0, +)
        #expect(result.totalTokens == breakdownSum)
    }

    @Test func test_assemble_nilTokenizer_fallsBackToHeuristic() {
        let messages = [makeMessage(role: .user, content: "abcdefgh")]
        let result = PromptAssembler.assemble(
            slots: [], messages: messages, systemPrompt: nil,
            contextSize: 10000, tokenizer: nil
        )
        // Heuristic: 8 chars / 4 = 2 tokens
        #expect(result.budgetBreakdown["history"] == 2)
    }
}
