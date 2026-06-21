import XCTest
@testable import ManifoldModelCatalog

/// Verifies the static, template-derived tool-call **claim** parser
/// (``ChatTemplateToolDescriptor``, #2005 Layer 1) across the six common
/// open-weight families plus the empty/nil trustworthy-negative case.
///
/// The snippets are intentionally minimal — only the tools guard and the
/// call-dialect markers the parser keys on, not full templates. The parser is a
/// heuristic substring/regex match (the leaf catalog cannot trial-render), so
/// these assert the recognised shapes, not template completeness.
final class ChatTemplateToolDescriptorTests: XCTestCase {

    // MARK: - Gemma 4 — {% if tools %} guard, <|tool_call> / key:value

    func testGemmaExpressesToolsWithKeyValueDialect() {
        let template = """
        {{ bos_token }}
        {%- if tools %}
        You may call the following tools:
        {%- for tool in tools %}{{ tool.name }}{%- endfor %}
        {%- endif %}
        <|tool_call>
        name: get_weather
        location: Paris
        <|/tool_call>
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertTrue(claim.toolsExpressible)
        XCTAssertEqual(claim.declaredDialect?.openDelimiter, "<|tool_call>")
        XCTAssertEqual(claim.declaredDialect?.argEncoding, .keyValue)
        XCTAssertEqual(claim.extractability, .clean)
    }

    // MARK: - Qwen2.5-Instruct — {% if tools %} guard, <tool_call> / json

    func testQwenExpressesToolsWithJSONDialect() {
        let template = """
        {%- if tools %}
        <tools>
        {%- for tool in tools %}{{ tool | tojson }}{%- endfor %}
        </tools>
        {%- endif %}
        <tool_call>
        {"name": "get_weather", "arguments": {"location": "Paris"}}
        </tool_call>
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertTrue(claim.toolsExpressible)
        XCTAssertEqual(claim.declaredDialect?.openDelimiter, "<tool_call>")
        XCTAssertEqual(claim.declaredDialect?.closeDelimiter, "</tool_call>")
        XCTAssertEqual(claim.declaredDialect?.argEncoding, .json)
        XCTAssertEqual(claim.extractability, .clean)
    }

    // MARK: - Hermes-2-Pro — {% for tool %} guard, <tool_call> / json

    func testHermesExpressesToolsWithJSONDialect() {
        let template = """
        {% for tool in tools %}
        {{ tool.function | tojson }}
        {% endfor %}
        <tool_call>
        {"name": "search", "arguments": {"q": "weather"}}
        </tool_call>
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertTrue(claim.toolsExpressible)
        XCTAssertEqual(claim.declaredDialect?.openDelimiter, "<tool_call>")
        XCTAssertEqual(claim.declaredDialect?.argEncoding, .json)
        XCTAssertEqual(claim.extractability, .clean)
    }

    // MARK: - Llama-3.1-Instruct — Environment: ipython guard, bare/python_tag

    func testLlamaExpressesToolsButBuried() {
        let template = """
        <|start_header_id|>system<|end_header_id|>
        Environment: ipython
        You have access to the following functions.
        <|python_tag|>{"name": "get_weather", "parameters": {"location": "Paris"}}
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertTrue(claim.toolsExpressible)
        XCTAssertNil(claim.declaredDialect?.openDelimiter)
        XCTAssertNil(claim.declaredDialect?.closeDelimiter)
        XCTAssertEqual(claim.declaredDialect?.argEncoding, .json)
        XCTAssertEqual(claim.extractability, .buried)
    }

    // MARK: - Mistral-v0.3 — tools is not none guard, [TOOL_CALLS] / json

    func testMistralExpressesToolsWithJSONDialect() {
        let template = """
        {%- if tools is not none %}
        [AVAILABLE_TOOLS] {{ tools | tojson }} [/AVAILABLE_TOOLS]
        {%- endif %}
        [TOOL_CALLS] [{"name": "get_weather", "arguments": {"location": "Paris"}}]
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertTrue(claim.toolsExpressible)
        XCTAssertEqual(claim.declaredDialect?.openDelimiter, "[TOOL_CALLS]")
        XCTAssertEqual(claim.declaredDialect?.argEncoding, .json)
        XCTAssertEqual(claim.extractability, .clean)
    }

    // MARK: - Phi-4 — no tools guard, toolless (trustworthy negative)

    func testPhi4IsToolless() {
        let template = """
        {% for message in messages %}
        <|im_start|>{{ message.role }}<|im_sep|>{{ message.content }}<|im_end|>
        {% endfor %}
        <|im_start|>assistant<|im_sep|>
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertFalse(claim.toolsExpressible)
        XCTAssertNil(claim.declaredDialect)
        XCTAssertEqual(claim.extractability, .toolless)
    }

    // MARK: - Empty / nil templates — trustworthy negative

    func testNilTemplateIsToolless() {
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: nil)

        XCTAssertFalse(claim.toolsExpressible)
        XCTAssertNil(claim.declaredDialect)
        XCTAssertEqual(claim.extractability, .toolless)
    }

    func testEmptyTemplateIsToolless() {
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: "   \n  ")

        XCTAssertFalse(claim.toolsExpressible)
        XCTAssertNil(claim.declaredDialect)
        XCTAssertEqual(claim.extractability, .toolless)
    }

    // MARK: - ModelInfo accessor wiring

    func testModelInfoExposesClaimFromChatTemplate() {
        let model = ModelInfo(
            name: "Qwen",
            fileName: "qwen.gguf",
            url: URL(fileURLWithPath: "/tmp/qwen.gguf"),
            fileSize: 1024,
            modelType: .gguf,
            chatTemplateRaw: "{%- if tools %}{% endif %}<tool_call></tool_call>"
        )

        XCTAssertTrue(model.toolCallClaim.toolsExpressible)
        XCTAssertEqual(model.toolCallClaim.declaredDialect?.openDelimiter, "<tool_call>")
    }
}
