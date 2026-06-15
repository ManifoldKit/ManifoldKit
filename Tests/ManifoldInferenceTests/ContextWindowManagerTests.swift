import XCTest
@testable import ManifoldInference

final class ContextWindowManagerTests: XCTestCase {

    // MARK: - Token Estimation

    func test_estimateTokenCount_emptyString() {
        XCTAssertEqual(ContextWindowManager.estimateTokenCount(""), 1,
                       "Empty string should return minimum of 1")
    }

    func test_estimateTokenCount_shortString() {
        // "hello" = 5 chars → 5/4 = 1
        XCTAssertEqual(ContextWindowManager.estimateTokenCount("hello"), 1)
    }

    func test_estimateTokenCount_mediumString() {
        // 100 chars → 25 tokens
        let text = String(repeating: "a", count: 100)
        XCTAssertEqual(ContextWindowManager.estimateTokenCount(text), 25)
    }

    func test_estimateTokenCount_longString() {
        // 1000 chars → 250 tokens
        let text = String(repeating: "a", count: 1000)
        XCTAssertEqual(ContextWindowManager.estimateTokenCount(text), 250)
    }

    func test_estimateTokenCount_singleChar() {
        // 1 char → 1/4 = 0, but min is 1
        XCTAssertEqual(ContextWindowManager.estimateTokenCount("a"), 1)
    }

    // MARK: - Per-part / per-message estimation (#1885 finding 9)

    func test_estimateTokenCount_textPart_matchesStringOverload() {
        let text = String(repeating: "a", count: 100)  // 25 tokens
        XCTAssertEqual(ContextWindowManager.estimateTokenCount(MessagePart.text(text)),
                       ContextWindowManager.estimateTokenCount(text))
    }

    func test_estimateTokenCount_imagePart_isNonZeroFixed() {
        let part = MessagePart.image(data: Data(repeating: 0, count: 8), mimeType: "image/png")
        XCTAssertEqual(ContextWindowManager.estimateTokenCount(part),
                       ContextWindowManager.imagePartTokenEstimate)
        XCTAssertGreaterThan(ContextWindowManager.estimateTokenCount(part), 0,
                             "image must not estimate as zero")
    }

    func test_estimateTokenCount_audioPart_isNonZeroFixed() {
        let part = MessagePart.audio(url: URL(fileURLWithPath: "/tmp/a.m4a"), duration: 3, waveform: nil)
        XCTAssertEqual(ContextWindowManager.estimateTokenCount(part),
                       ContextWindowManager.audioPartTokenEstimate)
    }

    func test_estimateTokenCount_toolCallPart_countsNameAndArgs() {
        let part = MessagePart.toolCall(ToolCall(
            id: "c1", toolName: "get_weather",
            arguments: String(repeating: "x", count: 80)))
        XCTAssertGreaterThan(ContextWindowManager.estimateTokenCount(part), 0,
                             "tool call args must be counted")
    }

    func test_estimateTokenCount_toolResultPart_countsPayload() {
        let part = MessagePart.toolResult(ToolResult(
            callId: "c1", content: String(repeating: "y", count: 120)))
        XCTAssertGreaterThan(ContextWindowManager.estimateTokenCount(part), 0)
    }

    /// The crux: a message with ONLY non-text parts used to estimate as zero
    /// via `.content`. The per-message estimate must be non-zero.
    func test_estimateTokenCount_imageOnlyMessage_isNonZero() {
        let msg = ChatMessage(
            role: .user,
            contentParts: [.image(data: Data(repeating: 0, count: 8), mimeType: "image/png")],
            sessionID: UUID())
        XCTAssertEqual(msg.content, "", "precondition: .content is empty for image-only message")
        XCTAssertGreaterThan(ContextWindowManager.estimateTokenCount(msg), 0,
                             "image-only message must not estimate as zero")
    }

    func test_estimateTokenCount_message_sumsAcrossParts() {
        let text = String(repeating: "a", count: 100)  // 25 tokens
        let msg = ChatMessage(
            role: .user,
            contentParts: [
                .text(text),
                .image(data: Data(repeating: 0, count: 8), mimeType: "image/png"),
            ],
            sessionID: UUID())
        let expected = ContextWindowManager.estimateTokenCount(text)
            + ContextWindowManager.imagePartTokenEstimate
        XCTAssertEqual(ContextWindowManager.estimateTokenCount(msg), expected)
    }

    // MARK: - Context Size Resolution

    func test_resolveContextSize_sessionOverrideTakesPriority() {
        let result = ContextWindowManager.resolveContextSize(
            sessionOverride: 8192,
            modelContextLength: 4096,
            backendMaxTokens: 2048,
            defaultSize: 1024
        )
        XCTAssertEqual(result, 8192)
    }

    func test_resolveContextSize_fallsToModelMetadata() {
        let result = ContextWindowManager.resolveContextSize(
            sessionOverride: nil,
            modelContextLength: 4096,
            backendMaxTokens: 2048,
            defaultSize: 1024
        )
        XCTAssertEqual(result, 4096)
    }

    func test_resolveContextSize_fallsToBackendCapabilities() {
        let result = ContextWindowManager.resolveContextSize(
            sessionOverride: nil,
            modelContextLength: nil,
            backendMaxTokens: 2048,
            defaultSize: 1024
        )
        XCTAssertEqual(result, 2048)
    }

    func test_resolveContextSize_fallsToDefault() {
        let result = ContextWindowManager.resolveContextSize(
            sessionOverride: nil,
            modelContextLength: nil,
            backendMaxTokens: nil,
            defaultSize: 1024
        )
        XCTAssertEqual(result, 1024)
    }

    func test_resolveContextSize_defaultDefaultIs2048() {
        let result = ContextWindowManager.resolveContextSize(
            sessionOverride: nil,
            modelContextLength: nil,
            backendMaxTokens: nil
        )
        XCTAssertEqual(result, 2048)
    }

    // MARK: - Message Trimming

    private func makeMessage(role: MessageRole, content: String) -> ChatMessage {
        ChatMessage(role: role, content: content, sessionID: UUID())
    }

    func test_trimMessages_emptyInput() {
        let result = ContextWindowManager.trimMessages(
            [],
            systemPrompt: nil,
            maxTokens: 4096
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_trimMessages_allFit() {
        let messages = [
            makeMessage(role: .user, content: "Hello"),       // ~2 tokens
            makeMessage(role: .assistant, content: "Hi there") // ~2 tokens
        ]

        let result = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: nil,
            maxTokens: 4096
        )

        XCTAssertEqual(result.count, 2, "All messages should be kept when under budget")
    }

    func test_trimMessages_trimsOldest() {
        // Create messages where total exceeds budget
        let messages = [
            makeMessage(role: .user, content: String(repeating: "a", count: 400)),      // ~100 tokens
            makeMessage(role: .assistant, content: String(repeating: "b", count: 400)),  // ~100 tokens
            makeMessage(role: .user, content: String(repeating: "c", count: 400)),       // ~100 tokens
            makeMessage(role: .assistant, content: String(repeating: "d", count: 400))   // ~100 tokens
        ]

        // maxTokens = 800, responseBuffer = 512 → available = 288
        // Each message ~100 tokens. Should keep last 2 messages (200 tokens)
        let result = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: nil,
            maxTokens: 800,
            responseBuffer: 512
        )

        XCTAssertTrue(result.count < messages.count, "Some messages should be trimmed")
        // The last message should always be preserved
        XCTAssertEqual(result.last?.content, messages.last?.content,
                       "Most recent message should be preserved")
    }

    func test_trimMessages_alwaysKeepsLastUserMessage() {
        // One huge user message that exceeds the entire budget
        let hugeMessage = makeMessage(role: .user, content: String(repeating: "x", count: 10000))

        let result = ContextWindowManager.trimMessages(
            [hugeMessage],
            systemPrompt: nil,
            maxTokens: 100,
            responseBuffer: 50
        )

        XCTAssertEqual(result.count, 1, "Should keep at least the last message even if over budget")
    }

    func test_trimMessages_respectsSystemPromptBudget() {
        let messages = [
            makeMessage(role: .user, content: String(repeating: "a", count: 200)),      // ~50 tokens
            makeMessage(role: .assistant, content: String(repeating: "b", count: 200)),  // ~50 tokens
        ]

        // With system prompt: uses tokens from the budget
        let longSystemPrompt = String(repeating: "s", count: 800) // ~200 tokens

        let withoutSystem = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: nil,
            maxTokens: 700,
            responseBuffer: 512
        )

        let withSystem = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: longSystemPrompt,
            maxTokens: 700,
            responseBuffer: 512
        )

        // With the system prompt consuming budget, fewer messages may fit
        XCTAssertTrue(withSystem.count <= withoutSystem.count,
                      "System prompt should reduce available space for messages")
    }

    // MARK: - Boundary Conditions

    func test_trimMessages_responseBufferExceedsMaxTokens_stillKeepsLastMessage() {
        // available = 100 - estimateTokenCount("") - 150
        // estimateTokenCount("") = max(1, 0/4) = 1
        // available = 100 - 1 - 150 = -51  →  ≤ 0 branch
        // Fallback: return the last user message
        let messages = [
            makeMessage(role: .assistant, content: "Earlier reply"),
            makeMessage(role: .user, content: "Final question"),
        ]

        let result = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: nil,
            maxTokens: 100,
            responseBuffer: 150
        )

        XCTAssertEqual(result.count, 1, "Should return exactly one message from the fallback path")
        XCTAssertEqual(result.first?.content, "Final question",
                       "The last user message must survive when responseBuffer exceeds maxTokens")
    }

    func test_trimMessages_systemPromptAloneExceedsBudget_keepsLastMessage() {
        // System prompt: 400 chars → estimateTokenCount = 400/4 = 100 tokens
        // maxTokens = 50, responseBuffer = 512 (default)
        // available = 50 - 100 - 512 = -562  →  ≤ 0 branch
        // Fallback: return the last user message
        let bigSystemPrompt = String(repeating: "s", count: 400)   // 100 tokens
        let messages = [
            makeMessage(role: .user, content: "First question"),
            makeMessage(role: .assistant, content: "Some answer"),
            makeMessage(role: .user, content: "Last question"),
        ]

        let result = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: bigSystemPrompt,
            maxTokens: 50
        )

        XCTAssertEqual(result.count, 1,
                       "Should return exactly one message when system prompt alone exceeds the budget")
        XCTAssertEqual(result.first?.content, "Last question",
                       "The last user message must be kept when system prompt consumes the entire budget")
    }

    func test_trimMessages_zeroMaxTokens_keepsLastMessage() {
        // available = 0 - 1 - 512 = -513  →  ≤ 0 branch
        // Fallback: return the last user message
        let messages = [
            makeMessage(role: .assistant, content: "Hello"),
            makeMessage(role: .user, content: "World"),
        ]

        let result = ContextWindowManager.trimMessages(
            messages,
            systemPrompt: nil,
            maxTokens: 0
        )

        XCTAssertEqual(result.count, 1, "Should return exactly one message even with maxTokens of 0")
        XCTAssertEqual(result.first?.content, "World",
                       "The last user message must survive when maxTokens is 0")
    }

    func test_trimMessages_emptyHistory_returnsEmpty() {
        // guard !messages.isEmpty else { return [] }  — must not crash
        let result = ContextWindowManager.trimMessages(
            [],
            systemPrompt: "You are helpful.",
            maxTokens: 4096
        )

        XCTAssertTrue(result.isEmpty, "Empty input should return an empty array without crashing")
    }

    func test_trimMessages_singleMessage_alwaysKept() {
        // Loop condition: usedTokens + messageTokens > available && !kept.isEmpty
        // On the first (only) iteration kept.isEmpty == true, so the condition short-circuits
        // and the message is always appended regardless of size.
        let bigMessage = makeMessage(role: .user, content: String(repeating: "z", count: 8000))  // 2000 tokens

        let result = ContextWindowManager.trimMessages(
            [bigMessage],
            systemPrompt: nil,
            maxTokens: 200,
            responseBuffer: 50
        )

        XCTAssertEqual(result.count, 1, "A single message must never be trimmed regardless of its size")
        XCTAssertEqual(result.first?.content, bigMessage.content,
                       "The sole message must be returned intact")
    }

    // MARK: - Context Budget

    func test_contextBudget_reservesResponseBuffer() {
        let budget = ContextWindowManager.calculateBudget(
            systemPrompt: nil,
            messages: [],
            maxTokens: 4096,
            responseBuffer: 512
        )

        XCTAssertEqual(budget.maxTokens, 4096)
        XCTAssertEqual(budget.responseBuffer, 512)
    }

    func test_contextBudget_usageRatio() {
        let messages = [
            makeMessage(role: .user, content: String(repeating: "a", count: 400))  // ~100 tokens
        ]

        let budget = ContextWindowManager.calculateBudget(
            systemPrompt: "Be helpful",  // ~3 tokens
            messages: messages,
            maxTokens: 1000
        )

        XCTAssertGreaterThan(budget.usageRatio, 0)
        XCTAssertLessThan(budget.usageRatio, 1.0)
    }
}
