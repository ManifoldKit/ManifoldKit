import Testing
import Foundation
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference

/// E2E tests for context overflow behaviour.
///
/// Uses real `PromptAssembler`, `ContextWindowManager`, and `HeuristicTokenizer`
/// with no mocks. These are all pure computation, so the tests are fast and
/// deterministic.
@Suite("Context Overflow E2E")
struct ContextOverflowE2ETests {

    private let heuristicTok = HeuristicTokenizer()

    private func makeMessage(role: MessageRole, content: String) -> ChatMessageRecord {
        ChatMessageRecord(role: role, content: content, sessionID: UUID())
    }

    // MARK: - PromptAssembler: Progressive Overflow

    @Test func assembler_progressiveTruncation_keepsNewestMessages() {
        // Build a conversation with 20 messages, each ~100 chars = ~25 tokens (heuristic).
        let messages = (0..<20).map { i in
            makeMessage(
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "Message number \(i): " + String(repeating: "x", count: 80)
            )
        }

        // contextSize=200 tokens, responseBuffer=50 => 150 tokens for messages.
        // Each message ~25 tokens, so ~6 messages fit.
        let result = PromptAssembler.assemble(
            slots: [],
            messages: messages,
            systemPrompt: nil,
            contextSize: 200,
            responseBuffer: 50,
            tokenizer: heuristicTok
        )

        let historyMessages = result.messages.filter { $0.role != "system" }

        // Should have kept some, but not all 20.
        #expect(historyMessages.count > 0)
        #expect(historyMessages.count < 20)

        // The LAST message should always be the most recent one.
        #expect(historyMessages.last?.content == messages.last?.content)
    }

    @Test func assembler_tinyContext_alwaysKeepsLastMessage() {
        let messages = [
            makeMessage(role: .user, content: String(repeating: "a", count: 500)),
        ]

        // Context of 10 tokens is far too small for a 500-char message,
        // but assembler must keep at least the last message.
        let result = PromptAssembler.assemble(
            slots: [],
            messages: messages,
            systemPrompt: nil,
            contextSize: 10,
            responseBuffer: 5,
            tokenizer: heuristicTok
        )

        let historyMessages = result.messages.filter { $0.role != "system" }
        #expect(historyMessages.count == 1)
        #expect(historyMessages[0].content == messages[0].content)
    }

    @Test func assembler_slotsConsumeAllBudget_stillKeepsLastMessage() {
        let bigSlot = PromptSlot(
            id: "char",
            content: String(repeating: "c", count: 400),
            label: "Character"
        )
        let messages = [
            makeMessage(role: .user, content: "Hello"),
            makeMessage(role: .assistant, content: "Hi"),
            makeMessage(role: .user, content: "How are you?"),
        ]

        // Context=100, slot=400 chars=100 tokens (heuristic), responseBuffer=0.
        // No budget remains for history, but last message is always kept.
        let result = PromptAssembler.assemble(
            slots: [bigSlot],
            messages: messages,
            systemPrompt: nil,
            contextSize: 100,
            responseBuffer: 0,
            tokenizer: heuristicTok
        )

        let historyMessages = result.messages.filter { $0.role != "system" }
        #expect(historyMessages.count >= 1)
        #expect(historyMessages.last?.content == "How are you?")
    }

    // MARK: - ContextWindowManager: Direct Trimming

    @Test func contextWindowManager_trimMessages_preservesMostRecent() {
        let messages = (0..<50).map { i in
            makeMessage(role: .user, content: "Turn \(i) " + String(repeating: "w", count: 40))
        }

        let trimmed = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: "You are helpful.",
            maxTokens: 100,
            responseBuffer: 20,
            tokenizer: heuristicTok
        )

        // With maxTokens=100, responseBuffer=20, system prompt ~4 tokens,
        // available = ~76 tokens. Each message ~11 tokens -> ~6 messages.
        #expect(trimmed.count > 0)
        #expect(trimmed.count < 50)

        // Most recent message should be present.
        #expect(trimmed.last?.content == messages.last?.content)

        // Messages should be in chronological order.
        for i in 1..<trimmed.count {
            #expect(trimmed[i].timestamp >= trimmed[i - 1].timestamp)
        }
    }

    @Test func contextWindowManager_largeSystemPrompt_leavesRoomForLastMessage() {
        let messages = [
            makeMessage(role: .user, content: "Short question"),
        ]

        // System prompt that consumes almost all context.
        let bigSystemPrompt = String(repeating: "s", count: 380)

        let trimmed = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: bigSystemPrompt,
            maxTokens: 100,
            responseBuffer: 10,
            tokenizer: heuristicTok
        )

        // System prompt = 380/4 = 95 tokens, available = 100-95-10 = -5.
        // Budget exhausted, but last user message must be kept.
        #expect(trimmed.count == 1)
        #expect(trimmed[0].content == "Short question")
    }

    // MARK: - Budget Breakdown Accuracy

    @Test func budgetBreakdown_sumsCorrectly() {
        let messages = (0..<10).map { i in
            makeMessage(role: .user, content: "Message \(i)")
        }

        let budget = ContextWindowManager.calculateBudget(
            systemPrompt: "System prompt",
            messages: messages,
            maxTokens: 4096,
            responseBuffer: 512,
            tokenizer: heuristicTok
        )

        #expect(budget.maxTokens == 4096)
        #expect(budget.responseBuffer == 512)
        #expect(budget.systemPromptTokens > 0)
        #expect(budget.messageTokens > 0)
        // Available should be maxTokens - system - responseBuffer.
        #expect(budget.availableForHistory == budget.maxTokens - budget.systemPromptTokens - budget.responseBuffer)
    }

    @Test func budgetBreakdown_usageRatio_scalesCorrectly() {
        let messages = (0..<100).map { i in
            makeMessage(role: .user, content: String(repeating: "x", count: 40))
        }

        let budget = ContextWindowManager.calculateBudget(
            systemPrompt: nil,
            messages: messages,
            maxTokens: 200,
            responseBuffer: 0,
            tokenizer: heuristicTok
        )

        // 100 messages x 10 tokens each = 1000 tokens, maxTokens=200.
        // usageRatio should be well above 1.0.
        #expect(budget.usageRatio > 1.0)
    }

    // MARK: - PromptAssembler with Slots and System Prompt

    @Test func assembler_systemPromptAndSlots_budgetedCorrectly() {
        let slots = [
            PromptSlot(id: "note", content: "Author's note", position: .atDepth(2), label: "Note"),
        ]
        let messages = (0..<10).map { i in
            makeMessage(
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "Turn \(i)"
            )
        }

        let result = PromptAssembler.assemble(
            slots: slots,
            messages: messages,
            systemPrompt: "Be helpful",
            contextSize: 500,
            responseBuffer: 50,
            tokenizer: heuristicTok
        )

        // Budget breakdown should include system, note, and history.
        #expect(result.budgetBreakdown["system"] != nil)
        #expect(result.budgetBreakdown["note"] != nil)
        #expect(result.budgetBreakdown["history"] != nil)

        // Total tokens should equal the sum of the breakdown.
        let breakdownSum = result.budgetBreakdown.values.reduce(0, +)
        #expect(result.totalTokens == breakdownSum)
    }

    // MARK: - Escalating Context Pressure

    @Test func escalatingHistory_gracefullyDegrades() {
        // Simulate progressively longer conversations and verify the assembler
        // always produces valid output without crashing.
        let contextSize = 100
        let responseBuffer = 20

        for messageCount in [1, 5, 10, 50, 200, 1000] {
            let messages = (0..<messageCount).map { i in
                makeMessage(
                    role: i.isMultiple(of: 2) ? .user : .assistant,
                    content: "Message \(i) content here"
                )
            }

            let result = PromptAssembler.assemble(
                slots: [],
                messages: messages,
                systemPrompt: "System",
                contextSize: contextSize,
                responseBuffer: responseBuffer,
                tokenizer: heuristicTok
            )

            // Must always produce at least the last message + system slot.
            let historyMessages = result.messages.filter { $0.role != "system" }
            #expect(
                historyMessages.count >= 1,
                "Must keep at least 1 history message for \(messageCount) input messages"
            )

            // Total tokens should never be negative.
            #expect(result.totalTokens >= 0)
        }
    }

    // MARK: - Token Estimation Consistency

    @Test func heuristicTokenizer_consistency() {
        // The heuristic is ~4 chars per token, minimum 1.
        let tok = HeuristicTokenizer()

        #expect(tok.tokenCount("") == 1)        // empty -> minimum 1
        #expect(tok.tokenCount("hi") == 1)       // 2 chars / 4 = 0 -> 1 min
        #expect(tok.tokenCount("hello") == 1)    // 5 / 4 = 1
        #expect(tok.tokenCount("abcdefgh") == 2) // 8 / 4 = 2

        // Longer strings scale linearly.
        let long = String(repeating: "x", count: 400)
        #expect(tok.tokenCount(long) == 100) // 400 / 4 = 100
    }

    @Test func contextWindowManager_estimateTokenCount_matchesHeuristic() {
        let text = String(repeating: "a", count: 100)

        let cwmEstimate = ContextWindowManager.estimateTokenCount(text)
        let tokEstimate = HeuristicTokenizer().tokenCount(text)

        // Both should use the same heuristic when no custom tokenizer is provided.
        #expect(cwmEstimate == tokEstimate)
    }
}
