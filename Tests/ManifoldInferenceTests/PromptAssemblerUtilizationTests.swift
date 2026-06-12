import XCTest
@testable import ManifoldInference
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldContract

/// Coverage for ``AssembledPrompt/contextUtilization`` — the fraction of the
/// context window consumed by a prompt assembly pass.
final class PromptAssemblerUtilizationTests: XCTestCase {

    private static let sessionID = UUID()

    private func makeMessages(_ texts: [String], roles: [MessageRole]? = nil) -> [ChatMessage] {
        texts.enumerated().map { i, text in
            let role = roles?[i] ?? (i % 2 == 0 ? .user : .assistant)
            return ChatMessage(role: role, content: text, sessionID: Self.sessionID)
        }
    }

    // MARK: - Test 1: utilization computed correctly

    func test_contextUtilization_isRatioOfTotalTokensToContextSize() {
        // Use HeuristicTokenizer (the default): ~1 token per 4 chars.
        // "hello" ≈ 1 token. Build a small message set.
        let messages = makeMessages(["hello world", "how are you"])
        let contextSize = 100

        let assembled = PromptAssembler.assemble(
            slots: [],
            messages: messages,
            systemPrompt: nil,
            contextSize: contextSize
        )

        // Utilization must equal totalTokens / contextSize, capped at 1.0.
        let expected = min(1.0, Double(assembled.totalTokens) / Double(contextSize))
        XCTAssertEqual(assembled.contextUtilization, expected, accuracy: 1e-9)
        // Should be positive (there are messages), and at most 1.0.
        XCTAssertGreaterThan(assembled.contextUtilization, 0.0)
        XCTAssertLessThanOrEqual(assembled.contextUtilization, 1.0)
    }

    // MARK: - Test 2: utilization capped at 1.0

    func test_contextUtilization_cappedAtOneWhenTokensExceedContextSize() {
        // A tiny context window forces utilization to 1.0 even with few tokens.
        let messages = makeMessages(["This is a somewhat longer message that should exceed a tiny context."])
        let contextSize = 1  // impossibly small

        let assembled = PromptAssembler.assemble(
            slots: [],
            messages: messages,
            systemPrompt: nil,
            contextSize: contextSize
        )

        // Regardless of how many tokens the message has, utilization ≤ 1.0.
        XCTAssertLessThanOrEqual(
            assembled.contextUtilization,
            1.0,
            "contextUtilization must never exceed 1.0 even when totalTokens > contextSize"
        )
        XCTAssertEqual(
            assembled.contextUtilization,
            1.0,
            accuracy: 1e-9,
            "contextUtilization should be 1.0 when the prompt is at or over capacity"
        )
    }

    // MARK: - Test 3: utilization is 0.0 when contextSize is 0

    func test_contextUtilization_isZeroWhenContextSizeIsZero() {
        let messages = makeMessages(["hello"])
        let assembled = PromptAssembler.assemble(
            slots: [],
            messages: messages,
            systemPrompt: nil,
            contextSize: 0
        )

        XCTAssertEqual(
            assembled.contextUtilization,
            0.0,
            accuracy: 1e-9,
            "contextUtilization should be 0.0 when contextSize is unknown (0)"
        )
    }

    // MARK: - Test 4: capabilities overload populates utilization

    func test_contextUtilization_populatedByCapabilitiesOverload() {
        let messages = makeMessages(["hi there"])
        let caps = BackendCapabilities(
            supportedParameters: [],
            maxContextTokens: 200,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )

        let assembled = PromptAssembler.assemble(
            slots: [],
            messages: messages,
            systemPrompt: nil,
            capabilities: caps
        )

        // contextWindowSize = Int(maxContextTokens) = 200.
        let expected = min(1.0, Double(assembled.totalTokens) / Double(caps.contextWindowSize))
        XCTAssertEqual(assembled.contextUtilization, expected, accuracy: 1e-9)
    }
}
