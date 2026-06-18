import XCTest
@testable import ManifoldInference

/// Fixture tests for #1811: render a model's *real* embedded GGUF Jinja chat
/// template via `swift-jinja` and confirm it produces ground-truth formatting
/// the hand-rolled ``PromptTemplate`` enum cannot reproduce.
///
/// Each fixture is a real, in-use model whose `tokenizer.chat_template` does NOT
/// map cleanly onto the enum case the detector picks for it. The enum picks the
/// nearest family (ChatML / Llama 3) and produces a *structurally different*
/// prompt — the silent-correctness gap this issue closes.
final class JinjaPromptRendererTests: XCTestCase {

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

    // MARK: - Model 1: Qwen2.5 default-system injection

    func test_qwen25_injectsDefaultSystemTurn_thatEnumDrops() throws {
        let messages = [(role: "user", content: "What is 2+2?")]

        let jinja = JinjaPromptRenderer.render(
            rawTemplate: Self.qwen25Template,
            messages: messages,
            systemPrompt: nil
        )
        let enumOut = PromptTemplate.chatML.format(messages: messages, systemPrompt: nil)

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
        let messages = [(role: "user", content: "Hi")]

        let jinja = JinjaPromptRenderer.render(
            rawTemplate: Self.llama32Template,
            messages: messages,
            systemPrompt: nil
        )
        let enumOut = PromptTemplate.llama3.format(messages: messages, systemPrompt: nil)

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
        let messages = [(role: "user", content: "Hi")]
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

    // MARK: - PromptRenderer prefers Jinja, falls back to the enum

    func test_promptRenderer_prefersJinjaWhenTemplatePresent() {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: Self.qwen25Template)
        let out = renderer.render(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        XCTAssertTrue(out.contains("You are Qwen"), "Renderer must prefer the real embedded Jinja")
    }

    func test_promptRenderer_fallsBackToEnum_whenNoTemplate() {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: nil)
        let out = renderer.render(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        let enumOut = PromptTemplate.chatML.format(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        XCTAssertEqual(out, enumOut, "No embedded template → enum output verbatim")
    }

    func test_promptRenderer_fallsBackToEnum_whenTemplateMalformed() {
        // A template swift-jinja cannot parse must not block generation — the
        // renderer falls back to the enum (a recoverable boundary condition).
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: "{%- if broken")
        let out = renderer.render(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        let enumOut = PromptTemplate.chatML.format(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        XCTAssertEqual(out, enumOut, "Malformed embedded template → enum fallback, no crash")
    }

    func test_jinjaRenderer_returnsNil_forEmptyTemplate() {
        XCTAssertNil(
            JinjaPromptRenderer.render(rawTemplate: "   \n  ", messages: [(role: "user", content: "Hi")], systemPrompt: nil),
            "Empty/whitespace template is a miss → nil so the caller falls back"
        )
    }
}
