import XCTest
@testable import ManifoldInference

/// Fixture tests for #1811 and #1909: render a model's *real* embedded GGUF
/// Jinja chat template via `swift-jinja` and confirm it produces ground-truth
/// formatting the hand-rolled ``PromptTemplate`` enum cannot reproduce —
/// including the native tool grammar an earlier version silently dropped.
///
/// Each fixture is a real, in-use model whose `tokenizer.chat_template` does NOT
/// map cleanly onto the enum case the detector picks for it. The enum picks the
/// nearest family (ChatML / Llama 3) and produces a *structurally different*
/// prompt — the silent-correctness gap this issue closes.
final class JinjaPromptRendererTests: XCTestCase {

    // MARK: - Helpers

    /// A plain text turn in the structured shape the renderer now consumes.
    private func msg(_ role: String, _ content: String) -> StructuredMessage {
        StructuredMessage(role: role, content: content)
    }

    // MARK: - Fixtures (abbreviated canonical HF chat templates)

    /// Qwen2.5-Instruct. Bespoke behaviour the `.chatML` enum case drops:
    /// when no system message is present, the template injects a mandatory
    /// default system turn ("You are Qwen, created by Alibaba Cloud…").
    private static let qwen25Template = """
    {%- if messages[0]['role'] == 'system' %}
        {{- '<|im_start|>system\\n' + messages[0]['content'] + '<|im_end|>\\n' }}
    {%- else %}
        {{- '<|im_start|>system\\nYou are Qwen, created by Alibaba Cloud. You are a helpful assistant.<|im_end|>\\n' }}
    {%- endif %}
    {%- for message in messages %}
        {%- if message.role == "user" or (message.role == "assistant" and message.content) %}
            {{- '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>\\n' }}
        {%- endif %}
    {%- endfor %}
    {%- if add_generation_prompt %}
        {{- '<|im_start|>assistant\\n' }}
    {%- endif %}
    """

    /// Llama-3.2-Instruct. Bespoke behaviour the `.llama3` enum case drops:
    /// it always emits a "Cutting Knowledge Date / Today Date" preamble inside
    /// the system turn, even when the host supplies no system prompt.
    private static let llama32Template = """
    {{- '<|begin_of_text|>' }}
    {%- if messages[0]['role'] == 'system' %}
        {%- set system_message = messages[0]['content'] %}
    {%- else %}
        {%- set system_message = "" %}
    {%- endif %}
    {{- '<|start_header_id|>system<|end_header_id|>\\n\\n' }}
    {{- 'Cutting Knowledge Date: December 2023\\n' }}
    {{- 'Today Date: 26 Jul 2024\\n\\n' }}
    {{- system_message }}
    {{- '<|eot_id|>' }}
    {%- for message in messages %}
        {%- if message['role'] != 'system' %}
            {{- '<|start_header_id|>' + message['role'] + '<|end_header_id|>\\n\\n' + message['content'] | trim + '<|eot_id|>' }}
        {%- endif %}
    {%- endfor %}
    {%- if add_generation_prompt %}
        {{- '<|start_header_id|>assistant<|end_header_id|>\\n\\n' }}
    {%- endif %}
    """

    /// A native tool-calling template that exercises every structured field the
    /// text-only projection used to drop (#1909): the `{% if tools %}`
    /// declaration block, per-message `tool_calls`, and the paired
    /// `tool_call_id` on the tool turn. Written against both the flat
    /// (`tool.name`) and OpenAI-nested (`tool.function.name`) conventions the
    /// renderer exposes, so it stands in for gemma-4 / Qwen / Hermes families.
    private static let nativeToolTemplate = """
    {%- if tools %}
    <|tools|>
    {%- for tool in tools %}
    <|tool|>{{ tool.name }}:{{ tool.function.name }}<|/tool|>
    {%- endfor %}
    <|/tools|>
    {%- endif %}
    {%- for message in messages %}
    <|{{ message.role }}|>{{ message.content }}
    {%- if message.tool_calls %}
        {%- for tc in message.tool_calls %}
    <|call|>{{ tc.function.name }}<|/call|>
        {%- endfor %}
    {%- endif %}
    {%- if message.tool_call_id %}
    <|result_for|>{{ message.tool_call_id }}<|/result_for|>
    {%- endif %}
    {%- endfor %}
    {%- if add_generation_prompt %}<|assistant|>{% endif %}
    """

    private static func weatherTool() -> ToolDefinition {
        ToolDefinition(
            name: "get_weather",
            description: "Look up the weather for a city",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")])
                ]),
                "required": .array([.string("city")]),
            ])
        )
    }

    // MARK: - Model 1: Qwen2.5 default-system injection

    func test_qwen25_injectsDefaultSystemTurn_thatEnumDrops() throws {
        let messages = [msg("user", "What is 2+2?")]

        let jinja = JinjaPromptRenderer.render(
            rawTemplate: Self.qwen25Template,
            messages: messages,
            systemPrompt: nil
        )
        let enumOut = PromptTemplate.chatML.format(messages: [(role: "user", content: "What is 2+2?")], systemPrompt: nil)

        let rendered = try XCTUnwrap(jinja, "swift-jinja should render the Qwen2.5 template")

        // Ground truth: the real template injects the default Qwen system turn.
        XCTAssertTrue(
            rendered.contains("You are Qwen, created by Alibaba Cloud."),
            "Real Jinja must emit Qwen's default system prompt"
        )
        // The enum approximation silently drops it — that's the gap.
        XCTAssertFalse(
            enumOut.contains("You are Qwen"),
            "Enum .chatML does not know about Qwen's default system prompt"
        )
        XCTAssertNotEqual(rendered, enumOut, "Real Jinja must differ from the enum approximation")
    }

    // MARK: - Model 2: Llama-3.2 knowledge-date preamble

    func test_llama32_emitsKnowledgeDatePreamble_thatEnumDrops() throws {
        let messages = [msg("user", "Hi")]

        let jinja = JinjaPromptRenderer.render(
            rawTemplate: Self.llama32Template,
            messages: messages,
            systemPrompt: nil
        )
        let enumOut = PromptTemplate.llama3.format(messages: [(role: "user", content: "Hi")], systemPrompt: nil)

        let rendered = try XCTUnwrap(jinja, "swift-jinja should render the Llama-3.2 template")

        XCTAssertTrue(
            rendered.contains("Cutting Knowledge Date: December 2023"),
            "Real Jinja must emit Llama-3.2's knowledge-date preamble"
        )
        XCTAssertTrue(rendered.contains("Today Date:"), "Real Jinja must emit the Today Date line")
        XCTAssertFalse(
            enumOut.contains("Cutting Knowledge Date"),
            "Enum .llama3 does not emit the knowledge-date preamble"
        )
        XCTAssertNotEqual(rendered, enumOut, "Real Jinja must differ from the enum approximation")
    }

    // MARK: - Host system prompt is honoured (no double-injection)

    func test_qwen25_hostSystemPrompt_overridesDefault() throws {
        let messages = [msg("user", "Hi")]
        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.qwen25Template,
                messages: messages,
                systemPrompt: "You are a pirate."
            )
        )
        XCTAssertTrue(rendered.contains("You are a pirate."), "Host system prompt must reach the template")
        XCTAssertFalse(
            rendered.contains("You are Qwen"),
            "When the host supplies a system prompt, the template's default branch must NOT fire"
        )
    }

    // MARK: - #1909 Ring 0/1: tool definitions reach the native template

    func test_nativeToolTemplate_rendersToolDeclarations() throws {
        // The bug: tools were hard-coded to [] in the Jinja context, so the
        // entire `{% if tools %}` declaration block never rendered.
        let withTools = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.nativeToolTemplate,
                messages: [msg("user", "weather in Paris?")],
                systemPrompt: nil,
                tools: [Self.weatherTool()]
            )
        )
        XCTAssertTrue(withTools.contains("<|tools|>"), "tools block must render when tools are present")
        XCTAssertTrue(
            withTools.contains("get_weather:get_weather"),
            "both flat (tool.name) and nested (tool.function.name) shapes must resolve"
        )

        // Sabotage: with no tools the declaration block must be falsey/absent —
        // proving the assertion above tracks the tools array, not a constant.
        let noTools = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.nativeToolTemplate,
                messages: [msg("user", "weather in Paris?")],
                systemPrompt: nil,
                tools: []
            )
        )
        XCTAssertFalse(noTools.contains("<|tools|>"), "no tools → declaration block must not render")
    }

    func test_promptRenderer_threadsToolsThroughJinjaPath() {
        let renderer = PromptRenderer(template: .gemma4, chatTemplateRaw: Self.nativeToolTemplate)
        let out = renderer.render(
            messages: [StructuredMessage(role: "user", content: "weather?")],
            systemPrompt: nil,
            tools: [Self.weatherTool()]
        )
        XCTAssertTrue(out.contains("get_weather"), "PromptRenderer must forward tools into the Jinja path (#1909)")
    }

    // MARK: - #1909 Ring 2: prior tool call + result render on the next turn

    func test_nativeToolTemplate_rendersPriorToolCallAndResult() throws {
        let call = ToolCall(id: "call_1", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)
        let messages: [StructuredMessage] = [
            msg("user", "weather in Paris?"),
            StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
            StructuredMessage(role: "tool", parts: [.toolResult(ToolResult(callId: "call_1", content: "18C and sunny"))]),
        ]
        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.nativeToolTemplate,
                messages: messages,
                systemPrompt: nil,
                tools: [Self.weatherTool()]
            )
        )
        XCTAssertTrue(rendered.contains("<|call|>get_weather<|/call|>"), "prior assistant tool_call must render")
        XCTAssertTrue(rendered.contains("<|result_for|>call_1<|/result_for|>"), "tool result must pair to its call id")
        XCTAssertTrue(rendered.contains("18C and sunny"), "tool result content must reach the template as message content")
    }

    // MARK: - rendersToolsNatively governs the preamble-fold decision

    func test_rendersToolsNatively_flag() {
        XCTAssertTrue(
            PromptRenderer(template: .chatML, chatTemplateRaw: Self.nativeToolTemplate).rendersToolsNatively,
            "embedded template that references tools → native"
        )
        XCTAssertFalse(
            PromptRenderer(template: .chatML, chatTemplateRaw: Self.qwen25Template).rendersToolsNatively,
            "embedded template with no tools branch → not native (host folds the preamble)"
        )
        XCTAssertTrue(
            PromptRenderer(template: .gemma4, chatTemplateRaw: nil).rendersToolsNatively,
            "templateless gemma4 → enum renders tools natively"
        )
        XCTAssertFalse(
            PromptRenderer(template: .chatML, chatTemplateRaw: nil).rendersToolsNatively,
            "templateless non-gemma → not native"
        )
    }

    /// A bare-substring probe (`chatTemplateRaw.contains("tools")`) marks this
    /// template native and skips the preamble — but the template renders **no**
    /// tool block, so the model would get zero tool guidance. The word `tools`
    /// here lives only in static prose and a literal output token, never inside a
    /// Jinja control/expression block, so `rendersToolsNatively` must be false and
    /// the host must fold the preamble in.
    func test_rendersToolsNatively_falseForProseOnlyMention() {
        let proseOnly = """
        {%- for message in messages %}
        <|tools|>You have access to the following tools, but only via prose.
        <|{{ message.role }}|>{{ message.content }}
        {%- endfor %}
        """
        XCTAssertFalse(
            PromptRenderer(template: .chatML, chatTemplateRaw: proseOnly).rendersToolsNatively,
            "`tools` only in prose / literal output → NOT native; the preamble must still be folded"
        )
    }

    /// Word-boundary guard: a template that references `tool_calls` (and prints
    /// `tools` only as a literal token) but never the `tools` *variable* renders
    /// no declaration block, so it must not be classified native.
    func test_rendersToolsNatively_falseForToolCallsButNoToolsVariable() {
        let toolCallsOnly = """
        {%- for message in messages %}
        {%- if message.tool_calls %}<|tool_call|>{% endif %}
        {%- endfor %}
        """
        XCTAssertFalse(
            PromptRenderer(template: .chatML, chatTemplateRaw: toolCallsOnly).rendersToolsNatively,
            "`tool_calls` is not the `tools` variable; word-bounded probe must not match"
        )
    }

    // MARK: - PromptRenderer prefers Jinja, falls back to the enum

    func test_promptRenderer_prefersJinjaWhenTemplatePresent() {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: Self.qwen25Template)
        let out = renderer.render(messages: [msg("user", "Hi")], systemPrompt: nil)
        XCTAssertTrue(out.contains("You are Qwen"), "Renderer must prefer the real embedded Jinja")
    }

    func test_promptRenderer_fallsBackToEnum_whenNoTemplate() {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: nil)
        let out = renderer.render(messages: [msg("user", "Hi")], systemPrompt: nil)
        let enumOut = PromptTemplate.chatML.format(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        XCTAssertEqual(out, enumOut, "No embedded template → enum output verbatim")
    }

    func test_promptRenderer_fallsBackToEnum_whenTemplateMalformed() {
        // A template swift-jinja cannot parse must not block generation — the
        // renderer falls back to the enum (a recoverable boundary condition).
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: "{%- if broken")
        let out = renderer.render(messages: [msg("user", "Hi")], systemPrompt: nil)
        let enumOut = PromptTemplate.chatML.format(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        XCTAssertEqual(out, enumOut, "Malformed embedded template → enum fallback, no crash")
    }

    func test_jinjaRenderer_returnsNil_forEmptyTemplate() {
        XCTAssertNil(
            JinjaPromptRenderer.render(rawTemplate: "   \n  ", messages: [msg("user", "Hi")], systemPrompt: nil),
            "Empty/whitespace template is a miss → nil so the caller falls back"
        )
    }
}
