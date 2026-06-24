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
        <|end_of_turn>
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertTrue(claim.toolsExpressible)
        XCTAssertEqual(claim.declaredDialect?.openDelimiter, "<|tool_call>")
        // Gemma terminates the call at the turn delimiter; there is no close-tool tag.
        XCTAssertEqual(claim.declaredDialect?.closeDelimiter, "<|end_of_turn>")
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

    // MARK: - False positives — a tools-shaped substring must NOT trip the guard

    /// Prose that merely mentions the word "tools" (a system-prompt string, a
    /// comment) carries no Jinja guard construct and must stay toolless — the
    /// guard is anchored to the `{% if tools %}` / `[TOOL_CALLS]` shapes, not to
    /// the bare word.
    func testProseMentioningToolsIsNotExpressible() {
        let template = """
        {% for message in messages %}
        <|im_start|>{{ message.role }}
        You are a helpful assistant. You may use tools when the user asks.
        {{ message.content }}<|im_end|>
        {% endfor %}
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertFalse(claim.toolsExpressible)
        XCTAssertNil(claim.declaredDialect)
        XCTAssertEqual(claim.extractability, .toolless)
    }

    /// A `{% for tool_message in ... %}` loop iterates an unrelated variable that
    /// merely starts with "tool" — it is not the Hermes `for tool in tools`
    /// guard and must not be mistaken for one.
    func testForLoopOverToolPrefixedVariableIsNotExpressible() {
        let template = """
        {% for tool_message in history %}
        {{ tool_message.content }}
        {% endfor %}
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertFalse(claim.toolsExpressible)
        XCTAssertNil(claim.declaredDialect)
        XCTAssertEqual(claim.extractability, .toolless)
    }

    /// A guard literal that lives ONLY inside a Jinja `{# ... #}` comment is
    /// inert text the renderer never emits, so it must not trip the claim — even
    /// though the raw substring `{% if tools %}` is present in the source.
    func testGuardInsideJinjaCommentIsNotExpressible() {
        let template = """
        {# Historical note: {% if tools %} used to live here, and the model
           would emit [TOOL_CALLS] / <tool_call>, but tool support was dropped. #}
        {% for message in messages %}
        <|im_start|>{{ message.role }}{{ message.content }}<|im_end|>
        {% endfor %}
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertFalse(claim.toolsExpressible)
        XCTAssertNil(claim.declaredDialect)
        XCTAssertEqual(claim.extractability, .toolless)
    }

    /// A real guard outside a comment still wins even when a comment elsewhere in
    /// the template mentions a *different* dialect literal — comment stripping
    /// must not swallow the live guard, and the live dialect (Qwen `<tool_call>`)
    /// must be the one reported, not the commented `[TOOL_CALLS]`.
    func testLiveGuardSurvivesUnrelatedCommentMentioningAnotherDialect() {
        let template = """
        {# this model does NOT use [TOOL_CALLS]; see Mistral for that #}
        {%- if tools %}
        {%- endif %}
        <tool_call>
        {"name": "x"}
        </tool_call>
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertTrue(claim.toolsExpressible)
        XCTAssertEqual(claim.declaredDialect?.openDelimiter, "<tool_call>")
        XCTAssertEqual(claim.declaredDialect?.argEncoding, .json)
    }

    // MARK: - Codable round-trip (claim is shippable as catalog data)

    /// The claim is documented as catalog data a host may persist/transmit, so it
    /// must survive a JSON encode/decode round-trip with stable enum raw values.
    func testClaimCodableRoundTrips() throws {
        let original = ChatTemplateToolDescriptor(
            parsingChatTemplate: "{%- if tools %}{% endif %}<tool_call></tool_call>"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatTemplateToolDescriptor.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.declaredDialect?.argEncoding, .json)
    }

    /// Enum raw values are wire identifiers — pin them so a rename can't silently
    /// break a persisted catalog claim.
    func testEnumRawValuesAreStable() {
        XCTAssertEqual(ChatTemplateToolDescriptor.ArgEncoding.json.rawValue, "json")
        XCTAssertEqual(ChatTemplateToolDescriptor.ArgEncoding.keyValue.rawValue, "keyValue")
        XCTAssertEqual(ChatTemplateToolDescriptor.ArgEncoding.keyEqualsValue.rawValue, "keyEqualsValue")
        XCTAssertEqual(ChatTemplateToolDescriptor.Extractability.clean.rawValue, "clean")
        XCTAssertEqual(ChatTemplateToolDescriptor.Extractability.buried.rawValue, "buried")
        XCTAssertEqual(ChatTemplateToolDescriptor.Extractability.toolless.rawValue, "toolless")
    }

    // MARK: - Whitespace-control variants of the guard tag all normalise

    /// The `{%+` trim-plus marker and newlines inside the tag must normalise to
    /// the plain `{% if tools %}` guard just like `{%-` does.
    func testWhitespaceControlVariantsNormaliseToGuard() {
        for tag in ["{%+ if tools %}", "{%-\n if tools +%}", "{%   if tools   %}"] {
            let template = tag + "\n<tool_call>\n{\"name\": \"x\"}\n</tool_call>"
            let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)
            XCTAssertTrue(claim.toolsExpressible, "guard tag \(tag) should be recognised")
            XCTAssertEqual(claim.declaredDialect?.openDelimiter, "<tool_call>", "tag \(tag)")
        }
    }

    // MARK: - Real-world full template (snippet-vs-reality drift guard)

    /// A faithful excerpt of the *shipped* Qwen2.5-Instruct chat template — the
    /// real guard wording, the `<tools>` block, the System message scaffolding,
    /// and the `<tool_call>` emission — not the minimal snippet the other tests
    /// use. Catches drift between the parser's assumptions and a template that
    /// actually moves in the wild.
    func testRealWorldQwenTemplateExpressesToolsWithJSONDialect() {
        let template = """
        {%- if tools %}
            {{- '<|im_start|>system\\n' }}
            {%- if messages[0].role == 'system' %}
                {{- messages[0].content + '\\n\\n' }}
            {%- endif %}
            {{- "# Tools\\n\\nYou may call one or more functions to assist with the user query.\\n\\nYou are provided with function signatures within <tools></tools> XML tags:\\n<tools>" }}
            {%- for tool in tools %}
                {{- "\\n" }}
                {{- tool | tojson }}
            {%- endfor %}
            {{- "\\n</tools>\\n\\nFor each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:\\n<tool_call>\\n{\\"name\\": <function-name>, \\"arguments\\": <args-json-object>}\\n</tool_call><|im_end|>\\n" }}
        {%- else %}
            {%- if messages[0].role == 'system' %}
                {{- '<|im_start|>system\\n' + messages[0].content + '<|im_end|>\\n' }}
            {%- endif %}
        {%- endif %}
        {%- for message in messages %}
            {{- '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>' + '\\n' }}
        {%- endfor %}
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: template)

        XCTAssertTrue(claim.toolsExpressible)
        XCTAssertEqual(claim.declaredDialect?.openDelimiter, "<tool_call>")
        XCTAssertEqual(claim.declaredDialect?.closeDelimiter, "</tool_call>")
        XCTAssertEqual(claim.declaredDialect?.argEncoding, .json)
        XCTAssertEqual(claim.extractability, .clean)
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
