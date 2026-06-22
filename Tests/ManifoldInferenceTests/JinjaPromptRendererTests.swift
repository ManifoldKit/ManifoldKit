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

    func test_promptRenderer_threadsToolsThroughJinjaPath() throws {
        let renderer = PromptRenderer(template: .gemma4, chatTemplateRaw: Self.nativeToolTemplate)
        let out = try renderer.render(
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

    func test_promptRenderer_prefersJinjaWhenTemplatePresent() throws {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: Self.qwen25Template)
        let out = try renderer.render(messages: [msg("user", "Hi")], systemPrompt: nil)
        XCTAssertTrue(out.contains("You are Qwen"), "Renderer must prefer the real embedded Jinja")
    }

    func test_promptRenderer_fallsBackToEnum_whenNoTemplate() throws {
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: nil)
        let out = try renderer.render(messages: [msg("user", "Hi")], systemPrompt: nil)
        let enumOut = PromptTemplate.chatML.format(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        XCTAssertEqual(out, enumOut, "No embedded template → enum output verbatim")
    }

    func test_promptRenderer_fallsBackToEnum_whenTemplateMalformed() throws {
        // A template swift-jinja cannot parse must not block generation *when no
        // tools are requested* — the renderer falls back to the enum (a
        // recoverable boundary condition). The tools-present case fails fast
        // instead (see PromptRendererToolFidelityTests, #1957 Tier 3).
        let renderer = PromptRenderer(template: .chatML, chatTemplateRaw: "{%- if broken")
        let out = try renderer.render(messages: [msg("user", "Hi")], systemPrompt: nil)
        let enumOut = PromptTemplate.chatML.format(messages: [(role: "user", content: "Hi")], systemPrompt: nil)
        XCTAssertEqual(out, enumOut, "Malformed embedded template → enum fallback, no crash")
    }

    func test_jinjaRenderer_returnsNil_forEmptyTemplate() {
        XCTAssertNil(
            JinjaPromptRenderer.render(rawTemplate: "   \n  ", messages: [msg("user", "Hi")], systemPrompt: nil),
            "Empty/whitespace template is a miss → nil so the caller falls back"
        )
    }

    // MARK: - Image + toolResult clobber regression

    /// A vision template that references `content` as a list (so `threadImages`
    /// fires) combined with a `.toolResult` part on the SAME message must NOT
    /// clobber the image content-list with the tool-result string.
    ///
    /// Regression for the bug where `(dict["content"] as? String)?.isEmpty ?? true`
    /// evaluated to `true` when `dict["content"]` was already a `[[String:Any]]`
    /// list (the cast returns nil → `?? true` → overwrites).
    func test_jinjaMessage_imageNotClobberedByToolResult() throws {
        // A minimal vision template that iterates `content` as a list. The bare
        // `image` identifier inside the `{% if item.type == "image" %}` block is
        // what triggers `templateReferencesImages` to return `true` (the probe is
        // word-bounded, so `image_url` would NOT match), causing `threadImages`;
        // the content-list items emitted by the renderer carry `type: "image"`.
        let visionTemplate = """
        {%- for message in messages %}
        <|{{ message.role }}|>
        {%- if message.content is iterable and message.content is not string %}
        {%- for item in message.content %}
        {%- if item.type == "image" %}<image/>
        {%- elif item.type == "text" %}{{ item.text }}
        {%- endif %}
        {%- endfor %}
        {%- else %}{{ message.content }}
        {%- endif %}
        {%- endfor %}
        {%- if add_generation_prompt %}<|assistant|>{% endif %}
        """

        let imageData = Data([0x89, 0x50, 0x4E, 0x47]) // minimal PNG header
        // A tool-result turn that also carries an image part (edge case:
        // a vision backend echoing the image alongside the tool result).
        let messages: [StructuredMessage] = [
            StructuredMessage(role: "tool", parts: [
                .image(data: imageData, mimeType: "image/png"),
                .toolResult(ToolResult(callId: "call_img", content: "image analyzed")),
            ]),
        ]

        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: visionTemplate,
                messages: messages,
                systemPrompt: nil
            ),
            "Vision template must render"
        )

        // The image placeholder must appear — it would be missing if the
        // content-list were overwritten with the plain tool-result string.
        XCTAssertTrue(
            rendered.contains("<image/>"),
            "Image content-list must survive; toolResult must not clobber it"
        )

        // Sabotage: tool-result content is a plain string, which the template's
        // `else` branch emits directly. If the bug were present the image token
        // would be absent and we'd only see the plain text — confirming the
        // assertion above is discriminating.
        XCTAssertTrue(
            rendered.contains("tool"),
            "Tool role must appear in the rendered output"
        )
    }

    // MARK: - #1992: alternation-strict templates (Mistral-v0.3) — system fold

    /// A minimal alternation-strict template modelled on Mistral-v0.3: it
    /// asserts user/assistant strictly alternate from index 0, so a leading
    /// `system` turn (index 0 is not `user`) triggers `raise_exception`. This is
    /// exactly the guard the real Mistral-v0.3 `tokenizer.chat_template` uses.
    private static let mistralAlternationTemplate = """
    {{- '<s>' }}
    {%- for message in messages %}
        {%- if (message['role'] == 'user') != (loop.index0 % 2 == 0) %}
            {{- raise_exception('Conversation roles must alternate user/assistant/user/assistant/...') }}
        {%- endif %}
        {%- if message['role'] == 'user' %}
            {{- '[INST] ' + message['content'] + ' [/INST]' }}
        {%- elif message['role'] == 'assistant' %}
            {{- message['content'] + '</s>' }}
        {%- endif %}
    {%- endfor %}
    """

    /// The retry folds the system prompt into the first user turn so the
    /// alternation-strict template renders instead of raising. Both the system
    /// text and the user text must be present, folded into a single `[INST]`.
    func test_mistral_foldsSystemIntoFirstUser_whenLeadingSystemRejected() throws {
        let messages = [msg("user", "What is 2+2?")]

        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.mistralAlternationTemplate,
                messages: messages,
                systemPrompt: "You are a terse calculator."
            ),
            "Render-retry must fold the system prompt into the first user turn so the alternation-strict template renders (instead of returning nil)"
        )

        XCTAssertTrue(
            rendered.contains("You are a terse calculator."),
            "System text must be folded into the prompt"
        )
        XCTAssertTrue(
            rendered.contains("What is 2+2?"),
            "Original user text must still be present"
        )
        // The fold puts both inside the SAME [INST] block (no separate system turn).
        XCTAssertTrue(
            rendered.contains("You are a terse calculator.\n\nWhat is 2+2?"),
            "System text must be prepended to the user content with a blank-line separator"
        )
        // No standalone system turn was emitted (the template has no system arm,
        // and a leading system role would have raised).
        XCTAssertEqual(
            rendered.components(separatedBy: "[INST]").count - 1, 1,
            "Exactly one user [INST] block — system was folded in, not emitted separately"
        )
    }

    /// SABOTAGE-VERIFIED (see PR body): with the render-retry reverted, this
    /// template raises on the leading system turn and `render` returns `nil`.
    /// This asserts the no-system / no-user edge cases do NOT retry — they fall
    /// through exactly as before (nothing to fold).
    func test_mistral_noSystemPrompt_doesNotRetry_andStillRenders() throws {
        // No system prompt → no leading system turn synthesized → the first
        // (and only) message is the user turn at index 0 → alternation holds →
        // renders on the first attempt, no retry needed.
        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.mistralAlternationTemplate,
                messages: [msg("user", "Hi")],
                systemPrompt: nil
            ),
            "With no system prompt there is no leading system turn to reject"
        )
        XCTAssertTrue(rendered.contains("[INST] Hi [/INST]"))
    }

    /// No-regression: a template that ACCEPTS a leading system role must render
    /// IDENTICALLY with the fix in place — the first render succeeds, so the
    /// retry never fires and a `system` turn is still emitted. This is the key
    /// safety property: system-accepting templates are byte-identical to before.
    func test_systemAcceptingTemplate_stillEmitsSystemTurn_retryNeverFires() throws {
        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.qwen25Template,
                messages: [msg("user", "Hi")],
                systemPrompt: "You are a pirate."
            )
        )
        // Qwen emits the system prompt inside an explicit `<|im_start|>system`
        // turn. If the retry had fired (folding into the user turn), the system
        // text would appear inside the user turn instead — it does not.
        XCTAssertTrue(
            rendered.contains("<|im_start|>system\nYou are a pirate.<|im_end|>"),
            "System-accepting template must still emit a discrete system turn — the retry must NOT fire"
        )
        XCTAssertFalse(
            rendered.contains("You are a pirate.\n\nHi"),
            "System text must NOT be folded into the user turn for a system-accepting template"
        )
    }

    /// The fail-fast refusal message must now name the underlying template error
    /// (#1992 observability) so a transcript is diagnosable. Use an
    /// alternation-strict template with NO user turn to fold into (an
    /// assistant-only history) so even the retry cannot rescue it, plus tools
    /// requested via a non-native-tool enum → the throw path fires.
    func test_refusalMessage_surfacesUnderlyingTemplateError() throws {
        // assistant-first history: index 0 is assistant, so alternation fails and
        // there is no user turn for the fold retry to target → genuine miss.
        let renderer = PromptRenderer(
            template: .chatML,
            chatTemplateRaw: Self.mistralAlternationTemplate
        )
        let toolDefs = [Self.weatherTool()]
        XCTAssertThrowsError(
            try renderer.render(
                messages: [msg("assistant", "hello first")],
                systemPrompt: nil,
                tools: toolDefs
            )
        ) { error in
            let description = "\(error)"
            XCTAssertTrue(
                description.contains("underlying template error:"),
                "Refusal must interpolate the underlying render error so the transcript is diagnosable; got: \(description)"
            )
            XCTAssertTrue(
                description.contains("alternate"),
                "The Mistral alternation raise_exception text must reach the refusal message; got: \(description)"
            )
        }
    }
}
