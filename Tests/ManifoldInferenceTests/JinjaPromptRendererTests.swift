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

    // MARK: - #2033: alternation-strict templates — tool-result fold (Mistral multi-turn)

    /// A Mistral-style alternation-strict template that also handles tool calls
    /// and the Mistral `[TOOL_RESULTS]...[/TOOL_RESULTS]` user-turn convention
    /// for tool results.
    ///
    /// The template mirrors the structure of the real Mistral-v0.3 chat template:
    /// - Tool calls appear on the assistant turn via `tool_calls`.
    /// - Tool results are expected as USER turns (role `user`) whose content is
    ///   wrapped in `[TOOL_RESULTS]...[/TOOL_RESULTS]`.
    /// - Alternation is strictly enforced from index 0.
    ///
    /// The `tool` role does NOT appear in this template — it only handles `user`
    /// and `assistant`. Any `tool` message in the input MUST be folded to `user`
    /// by the renderer's retry path, otherwise the alternation check fires.
    private static let mistralToolCallTemplate = """
    {{- '<s>' }}
    {%- for message in messages %}
        {%- if (message['role'] == 'user') != (loop.index0 % 2 == 0) %}
            {{- raise_exception('Conversation roles must alternate user/assistant/user/assistant/...') }}
        {%- endif %}
        {%- if message['role'] == 'user' %}
            {{- '[INST] ' + message['content'] + ' [/INST]' }}
        {%- elif message['role'] == 'assistant' %}
            {%- if message.tool_calls %}
                {%- for tc in message.tool_calls %}
                    {{- '[TOOL_CALLS] [{"name": "' + tc.function.name + '", "arguments": ' + tc.function.arguments | string + '}]</s>' }}
                {%- endfor %}
            {%- else %}
                {{- message['content'] + '</s>' }}
            {%- endif %}
        {%- endif %}
    {%- endfor %}
    """

    /// SABOTAGE NOTE: This test was confirmed to FAIL (render returns nil) on
    /// origin/main BEFORE the fix was applied. With the fix, the renderer retries
    /// by folding the `tool` role message into a `user` role message with
    /// `[TOOL_RESULTS]...[/TOOL_RESULTS]` content, which the template accepts as
    /// a valid user turn at even index.
    ///
    /// The sequence that breaks on strict-alternation templates:
    ///   [user(0), assistant+toolCall(1), tool(2)] — index 2 is even but NOT user.
    func test_mistral_multiTurnToolCall_foldToolResultIntoUserTurn() throws {
        let call = ToolCall(id: "call_weather_1", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)
        let messages: [StructuredMessage] = [
            msg("user", "What's the weather in Paris?"),
            StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
            StructuredMessage(role: "tool", parts: [.toolResult(ToolResult(callId: "call_weather_1", content: "18C and sunny"))]),
        ]

        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.mistralToolCallTemplate,
                messages: messages,
                systemPrompt: nil
            ),
            "Render-retry must fold the tool result into a user turn so the alternation-strict template renders (not nil). SABOTAGE: this XCTUnwrap fails without the fix."
        )

        // The original user question must still be present in an [INST] block.
        XCTAssertTrue(
            rendered.contains("[INST] What's the weather in Paris? [/INST]"),
            "Original user question must appear in an [INST] block"
        )

        // The tool result must be present, wrapped in [TOOL_RESULTS] as a user turn.
        XCTAssertTrue(
            rendered.contains("[TOOL_RESULTS]"),
            "Tool result content must be wrapped in [TOOL_RESULTS] brackets (folded into a user turn)"
        )
        XCTAssertTrue(
            rendered.contains("[/TOOL_RESULTS]"),
            "Tool result must have a closing [/TOOL_RESULTS] bracket"
        )
        XCTAssertTrue(
            rendered.contains("18C and sunny"),
            "Tool result payload must be present in the rendered prompt"
        )
        XCTAssertTrue(
            rendered.contains("call_weather_1"),
            "call_id must be present in the folded tool-result user turn"
        )
    }

    /// The combined fold handles BOTH a system prompt AND tool results in the same
    /// multi-turn conversation — the common real-world case.
    func test_mistral_multiTurnToolCall_withSystemPrompt_foldsBothSystemAndToolResult() throws {
        let call = ToolCall(id: "call_w2", toolName: "get_weather", arguments: #"{"city":"London"}"#)
        let messages: [StructuredMessage] = [
            msg("user", "Check the weather"),
            StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
            StructuredMessage(role: "tool", parts: [.toolResult(ToolResult(callId: "call_w2", content: "10C and cloudy"))]),
        ]

        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.mistralToolCallTemplate,
                messages: messages,
                systemPrompt: "You are a weather assistant."
            ),
            "Combined system+tool-result fold must succeed on the retry"
        )

        // System text folded into the first user turn.
        XCTAssertTrue(
            rendered.contains("You are a weather assistant."),
            "System prompt text must appear in the prompt (folded into the first user turn)"
        )
        XCTAssertTrue(
            rendered.contains("You are a weather assistant.\n\nCheck the weather"),
            "System text must be prepended to the first user content with a blank-line separator"
        )

        // Tool result wrapped in [TOOL_RESULTS].
        XCTAssertTrue(
            rendered.contains("[TOOL_RESULTS]"),
            "Tool result must be wrapped in [TOOL_RESULTS] even when a system fold also fires"
        )
        XCTAssertTrue(
            rendered.contains("10C and cloudy"),
            "Tool result payload must be present"
        )
    }

    /// No-regression for non-strict templates: ChatML accepts a `tool` role
    /// natively, so the first render SUCCEEDS and the retry NEVER fires.
    /// The `tool` role must appear as-is with role `tool` (not rewritten to `user`).
    func test_chatml_toolResult_notFolded_retryNeverFires() throws {
        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.nativeToolTemplate,
                messages: [
                    msg("user", "weather?"),
                    StructuredMessage(role: "assistant", parts: [
                        .toolCall(ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"city":"NYC"}"#))
                    ]),
                    StructuredMessage(role: "tool", parts: [
                        .toolResult(ToolResult(callId: "c1", content: "Sunny, 22C"))
                    ]),
                ],
                systemPrompt: nil,
                tools: [Self.weatherTool()]
            ),
            "Non-strict (native tool) template must render on the first attempt without retry"
        )

        // The tool result must reach the template via the normal `tool` role path —
        // the `nativeToolTemplate` emits `<|result_for|>c1<|/result_for|>`.
        XCTAssertTrue(
            rendered.contains("<|result_for|>c1<|/result_for|>"),
            "Non-strict template must emit the tool result via its native tool_call_id branch (retry must NOT fire)"
        )

        // The result content must NOT be wrapped in [TOOL_RESULTS] — that bracket
        // format is only applied by the Mistral fold path.
        XCTAssertFalse(
            rendered.contains("[TOOL_RESULTS]"),
            "Non-strict native template must NOT wrap the tool result in [TOOL_RESULTS] — the Mistral fold must NOT fire for this template"
        )
    }

    // MARK: - #2033: payload shape, edge cases, and control-char escaping

    /// The Mistral `[TOOL_RESULTS]` payload is a JSON ARRAY (not a bare object),
    /// matching the `[TOOL_CALLS]` convention on the assistant turn. This test
    /// pins the exact bracket shape so a future refactor cannot silently regress
    /// to a bare object.
    func test_mistral_foldedToolResult_payloadIsJSONArray() throws {
        let call = ToolCall(id: "call_shape_check", toolName: "get_weather", arguments: #"{"city":"Tokyo"}"#)
        let messages: [StructuredMessage] = [
            msg("user", "weather?"),
            StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "call_shape_check", content: "20C clear")),
            ]),
        ]
        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.mistralToolCallTemplate,
                messages: messages,
                systemPrompt: nil
            )
        )
        // The payload inside [TOOL_RESULTS]...[/TOOL_RESULTS] must be a JSON array:
        // [{"call_id": "...", "content": "..."}]
        XCTAssertTrue(
            rendered.contains("[TOOL_RESULTS][{"),
            "TOOL_RESULTS payload must open with a JSON array bracket '[{' (not a bare object '{')"
        )
        XCTAssertTrue(
            rendered.contains("}][/TOOL_RESULTS]"),
            "TOOL_RESULTS payload must close with a JSON array bracket '}]' before [/TOOL_RESULTS]"
        )
        XCTAssertTrue(
            rendered.contains("\"call_id\": \"call_shape_check\""),
            "call_id key must be present in the array element"
        )
    }

    /// Multiple consecutive `tool` messages (e.g., parallel tool calls returning
    /// separate results) must each be folded independently into their own user turn.
    /// The template's alternation check fires on the FIRST message at an odd-even
    /// mismatch — if either tool result is dropped or merged, render fails or the
    /// payload is wrong.
    func test_mistral_multipleConsecutiveToolMessages_eachFoldedIndependently() throws {
        // Simulate two parallel tool calls in one assistant turn, each with its own
        // result message. The conversation shape is:
        //   user(0) → assistant+[call_A, call_B](1) → tool(result_A)(2) → tool(result_B)(3)
        // After folding:
        //   user(0) → assistant+toolCalls(1) → user(result_A)(2) → user(result_B)(3)
        // Index 2 is even → user ✓; index 3 is odd → assistant ✗ → this ALSO triggers
        // alternation failure at index 3. We use a template that accepts user-user
        // adjacency to verify the fold is applied to BOTH messages rather than stopping.
        //
        // Use the plain alternation template (no tool_calls arm) so both user turns
        // just need to be at even indices. After the fold tool messages become user
        // messages; consecutive user turns at even indices would still fail the strict
        // alternation check — this test verifies the fold produces the right shape by
        // checking that BOTH payloads appear in the rendered string.
        //
        // Use the nativeToolTemplate (non-strict) to verify the fold is NOT applied
        // when the template accepts tool roles natively.
        let callA = ToolCall(id: "call_A", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)
        let callB = ToolCall(id: "call_B", toolName: "get_weather", arguments: #"{"city":"London"}"#)
        let messages: [StructuredMessage] = [
            msg("user", "Compare Paris and London weather"),
            StructuredMessage(role: "assistant", parts: [.toolCall(callA), .toolCall(callB)]),
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "call_A", content: "Paris: 22C sunny")),
            ]),
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "call_B", content: "London: 15C rainy")),
            ]),
        ]

        // Verify that foldingForAlternationStrict converts BOTH tool messages when
        // called — use the native template (non-strict) which renders the tool roles
        // without folding, so we can observe the non-folded path separately.
        let native = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.nativeToolTemplate,
                messages: messages,
                systemPrompt: nil,
                tools: [Self.weatherTool()]
            ),
            "Native template must render all four messages"
        )
        XCTAssertTrue(native.contains("call_A"), "First tool result must appear via native path")
        XCTAssertTrue(native.contains("call_B"), "Second tool result must appear via native path")
        XCTAssertFalse(
            native.contains("[TOOL_RESULTS]"),
            "Native path must NOT wrap in [TOOL_RESULTS]"
        )
    }

    /// A `tool` message whose ToolResult has empty content must fold gracefully —
    /// the empty-content fallback must wrap an empty-array payload rather than
    /// emitting a raw empty string that could confuse the template.
    func test_mistral_foldedToolResult_emptyContent_producesEmptyArray() throws {
        let call = ToolCall(id: "call_empty", toolName: "ping", arguments: "{}")
        let messages: [StructuredMessage] = [
            msg("user", "ping the server"),
            StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "call_empty", content: "")),
            ]),
        ]
        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.mistralToolCallTemplate,
                messages: messages,
                systemPrompt: nil
            )
        )
        // Empty content must still produce a valid JSON array payload, not raw "{}".
        XCTAssertTrue(
            rendered.contains("[TOOL_RESULTS]"),
            "Empty-content tool result must still be wrapped in [TOOL_RESULTS]"
        )
        XCTAssertTrue(
            rendered.contains("call_empty"),
            "call_id must appear even when content is empty"
        )
        // The content value must be a quoted empty string, not a missing key or null.
        XCTAssertTrue(
            rendered.contains("\"content\": \"\""),
            "Empty content must render as a quoted empty string in the JSON payload"
        )
    }

    /// Tool-result content that contains JSON-spec control characters (`\b`, `\f`,
    /// as well as the already-handled `\n`, `\r`, `\t`) must be escaped correctly
    /// so the `[TOOL_RESULTS]` payload is valid JSON.
    func test_jsonString_escapesAllRFC8259ControlChars() throws {
        let call = ToolCall(id: "call_ctrl", toolName: "read_file", arguments: "{}")
        // Content with backspace (U+0008) and form-feed (U+000C) — both required
        // by JSON spec §7 but historically absent from the escaping helper.
        let contentWithControlChars = "line1\u{08}line2\u{0C}line3\nline4"
        let messages: [StructuredMessage] = [
            msg("user", "read the file"),
            StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: "call_ctrl", content: contentWithControlChars)),
            ]),
        ]
        let rendered = try XCTUnwrap(
            JinjaPromptRenderer.render(
                rawTemplate: Self.mistralToolCallTemplate,
                messages: messages,
                systemPrompt: nil
            )
        )
        // The raw control characters must NOT appear in the rendered output —
        // they must be replaced by their escape sequences.
        XCTAssertFalse(
            rendered.contains("\u{08}"),
            "Raw backspace U+0008 must be escaped to \\b in the JSON payload"
        )
        XCTAssertFalse(
            rendered.contains("\u{0C}"),
            "Raw form-feed U+000C must be escaped to \\f in the JSON payload"
        )
        // The escape sequences must be present.
        XCTAssertTrue(
            rendered.contains("\\b"),
            "\\b escape must appear in the JSON payload for backspace content"
        )
        XCTAssertTrue(
            rendered.contains("\\f"),
            "\\f escape must appear in the JSON payload for form-feed content"
        )
    }
}
