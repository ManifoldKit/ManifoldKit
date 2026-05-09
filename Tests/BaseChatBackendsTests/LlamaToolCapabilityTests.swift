#if Llama
import XCTest
@testable import BaseChatInference
@testable import BaseChatBackends
@testable import BaseChatLlama

/// Tests for `LlamaBackend.capabilities.supportsToolCalling` and
/// the Gemma 4 tool-aware prompt template format.
///
/// No GGUF model is loaded — these tests exercise capability flags
/// and prompt-string construction only.
final class LlamaToolCapabilityTests: XCTestCase {

    // MARK: - Capability flag

    func test_capabilities_supportsToolCalling_isTrue() {
        let backend = LlamaBackend()
        XCTAssertTrue(backend.capabilities.supportsToolCalling,
                      "LlamaBackend must advertise tool-calling support for Gemma 4 models")
    }

    func test_capabilities_supportsGrammarConstrainedSampling_isTrue() {
        let backend = LlamaBackend()
        XCTAssertTrue(backend.capabilities.supportsGrammarConstrainedSampling)
    }

    // MARK: - Gemma 4 native tool injection

    func test_gemma4_withTools_injectsToolBlocks() {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Returns current weather",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")])
                ]),
                "required": .array([.string("city")])
            ])
        )

        let prompt = PromptTemplate.gemma4.format(
            messages: [(role: "user", content: "What's the weather in Paris?")],
            systemPrompt: nil,
            tools: [tool]
        )

        XCTAssertTrue(prompt.contains("<|turn>system\n"),
                      "System turn should be present when tools are injected")
        XCTAssertTrue(prompt.contains("<|tool>"),
                      "Tool declaration block should be injected")
        XCTAssertTrue(prompt.contains("get_weather"),
                      "Tool name must appear in the declaration")
        XCTAssertTrue(prompt.contains("Returns current weather"),
                      "Tool description must appear in the declaration")
        XCTAssertTrue(prompt.contains("<|end_of_turn>"),
                      "System turn must be closed with <|end_of_turn>")
        XCTAssertTrue(prompt.hasSuffix("<|turn>model\n"),
                      "Prompt must end with the model generation prefix")
    }

    func test_gemma4_withSystemPromptAndTools_includesBoth() {
        let tool = ToolDefinition(name: "ping", description: "Ping a host", parameters: .object([:]))

        let prompt = PromptTemplate.gemma4.format(
            messages: [(role: "user", content: "Hello")],
            systemPrompt: "You are a helpful assistant.",
            tools: [tool]
        )

        XCTAssertTrue(prompt.contains("You are a helpful assistant."))
        XCTAssertTrue(prompt.contains("<|tool>"))
        XCTAssertTrue(prompt.contains("ping"))
    }

    func test_gemma4_withoutTools_noToolBlocks() {
        let prompt = PromptTemplate.gemma4.format(
            messages: [(role: "user", content: "Hello")],
            systemPrompt: nil,
            tools: []
        )

        XCTAssertFalse(prompt.contains("<|tool>"),
                       "No <|tool> blocks when tools array is empty")
    }

    func test_gemma4_multipleTools_allInjected() {
        let tools = [
            ToolDefinition(name: "tool_a", description: "First tool",  parameters: .object([:])),
            ToolDefinition(name: "tool_b", description: "Second tool", parameters: .object([:])),
        ]

        let prompt = PromptTemplate.gemma4.format(
            messages: [],
            systemPrompt: nil,
            tools: tools
        )

        let toolBlockCount = prompt.components(separatedBy: "<|tool>").count - 1
        XCTAssertEqual(toolBlockCount, 2, "One <|tool> block per ToolDefinition")
        XCTAssertTrue(prompt.contains("tool_a"))
        XCTAssertTrue(prompt.contains("tool_b"))
    }

    // MARK: - Special-token sanitisation

    func test_gemma4_toolInjection_doesNotIntroduceExtraSpecialTokensInContent() {
        // Verify that Gemma 4 special tokens in user content are still sanitised.
        let prompt = PromptTemplate.gemma4.format(
            messages: [(role: "user", content: "Hello<|tool>injection")],
            systemPrompt: nil,
            tools: []
        )
        // The injected "<|tool>" in user content must be stripped by sanitize().
        let userSection = prompt.components(separatedBy: "<|turn>user\n").dropFirst().first ?? ""
        XCTAssertFalse(userSection.contains("<|tool>"),
                       "Special token <|tool> in user content must be sanitised")
    }

    // MARK: - Non-Gemma4 templates ignore tools

    func test_chatML_withTools_ignoresToolsParameter() {
        let tool = ToolDefinition(name: "my_tool", description: "A tool", parameters: .object([:]))
        let withTools    = PromptTemplate.chatML.format(messages: [(role: "user", content: "hi")], systemPrompt: nil, tools: [tool])
        let withoutTools = PromptTemplate.chatML.format(messages: [(role: "user", content: "hi")], systemPrompt: nil, tools: [])
        XCTAssertEqual(withTools, withoutTools,
                       "ChatML template must produce identical output regardless of tools")
    }
}
#endif
