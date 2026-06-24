import XCTest
@testable import ManifoldInference

/// Layer-2 (#2005) render round-trip checks. These exercise the *real*
/// ``JinjaPromptRenderer`` so the templates here must be evaluable by
/// swift-jinja — unlike the Layer-1 ``ChatTemplateToolDescriptorTests``
/// fixtures, which only need to satisfy the substring parser. Each consistent
/// fixture both (a) emits the tool name from its `{% if tools %}` branch and
/// (b) emits the declared call delimiter from its
/// `{% for tc in message.tool_calls %}` branch, so the assertion proves the
/// grammar survives rendering rather than appearing as static text.
///
/// The renderable shapes mirror the proven `nativeToolTemplate` in
/// ``JinjaPromptRendererTests`` (per-message `{% if message.tool_calls %}`
/// nested in the message loop) rather than the Layer-1 substring fixtures,
/// which are not swift-jinja-evaluable.
final class RenderConsistencyCheckerTests: XCTestCase {

    // MARK: - Recognised families render consistently

    func testQwenStyleRendersConsistently() {
        // {% if tools %} guard + <tool_call>…</tool_call> JSON dialect.
        let template = """
        {%- if tools %}
        <tools>
        {%- for tool in tools %}{{ tool.name }}
        {%- endfor %}
        </tools>
        {%- endif %}
        {%- for message in messages %}
        <|{{ message.role }}|>{{ message.content }}
        {%- if message.tool_calls %}
            {%- for tc in message.tool_calls %}<tool_call>
        {"name": "{{ tc.function.name }}"}
        </tool_call>
            {%- endfor %}
        {%- endif %}
        {%- endfor %}
        """
        let result = RenderConsistencyChecker.check(chatTemplateRaw: template)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertEqual(result.declaredDelimiterRendered, true)
        XCTAssertEqual(result.claim.declaredDialect?.openDelimiter, "<tool_call>")
        XCTAssertEqual(result.detail, "")
    }

    func testGemmaStyleRendersConsistently() {
        // {% if tools %} guard + <|tool_call> key/value dialect.
        let template = """
        {%- if tools %}
        Tools:
        {%- for tool in tools %}{{ tool.name }}
        {%- endfor %}
        {%- endif %}
        {%- for message in messages %}
        {{ message.role }}: {{ message.content }}
        {%- if message.tool_calls %}
            {%- for tc in message.tool_calls %}<|tool_call>
        name: {{ tc.function.name }}
        <|end_of_turn>
            {%- endfor %}
        {%- endif %}
        {%- endfor %}
        """
        let result = RenderConsistencyChecker.check(chatTemplateRaw: template)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertEqual(result.declaredDelimiterRendered, true)
        XCTAssertEqual(result.claim.declaredDialect?.openDelimiter, "<|tool_call>")
    }

    func testMistralStyleRendersConsistently() {
        // tools-is-not-none guard + [TOOL_CALLS] dialect.
        let template = """
        {%- if tools is not none %}
        [AVAILABLE_TOOLS]
        {%- for tool in tools %}{{ tool.name }}
        {%- endfor %}
        [/AVAILABLE_TOOLS]
        {%- endif %}
        {%- for message in messages %}
        {{ message.role }}: {{ message.content }}
        {%- if message.tool_calls %}
            {%- for tc in message.tool_calls %}[TOOL_CALLS] {{ tc.function.name }}
            {%- endfor %}
        {%- endif %}
        {%- endfor %}
        """
        let result = RenderConsistencyChecker.check(chatTemplateRaw: template)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertEqual(result.declaredDelimiterRendered, true)
        XCTAssertEqual(result.claim.declaredDialect?.openDelimiter, "[TOOL_CALLS]")
    }

    func testHermesStyleRendersConsistently() {
        // {% for tool in tools %} guard (no `if`) + <tool_call> dialect.
        let template = """
        {%- for tool in tools %}{{ tool.name }}
        {%- endfor %}
        {%- for message in messages %}
        {{ message.role }}: {{ message.content }}
        {%- if message.tool_calls %}
            {%- for tc in message.tool_calls %}<tool_call>
        {"name": "{{ tc.function.name }}"}
        </tool_call>
            {%- endfor %}
        {%- endif %}
        {%- endfor %}
        """
        let result = RenderConsistencyChecker.check(chatTemplateRaw: template)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertEqual(result.declaredDelimiterRendered, true)
    }

    func testLlamaStyleNoDelimiterRendersConsistently() {
        // Llama-3.1: Environment: ipython guard, bare-JSON dialect — the claim
        // declares NO open delimiter, so declaredDelimiterRendered must be nil
        // and consistency must hinge on the tool name alone.
        let template = """
        {%- if tools %}
        Environment: ipython
        {%- for tool in tools %}{{ tool.name }}
        {%- endfor %}
        {%- endif %}
        {%- for message in messages %}
        {{ message.role }}: {{ message.content }}
        {%- if message.tool_calls %}
            {%- for tc in message.tool_calls %}{"name": "{{ tc.function.name }}"}
            {%- endfor %}
        {%- endif %}
        {%- endfor %}
        """
        let result = RenderConsistencyChecker.check(chatTemplateRaw: template)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertNil(result.declaredDelimiterRendered, "bare-JSON dialect has no opener to assert")
        XCTAssertNil(result.claim.declaredDialect?.openDelimiter)
    }

    // MARK: - Not applicable

    func testToollessTemplateIsNotApplicable() {
        // Phi-style: no tools guard at all → trustworthy negative claim.
        let template = """
        {%- for message in messages %}
        <|im_start|>{{ message.role }}<|im_sep|>{{ message.content }}<|im_end|>
        {%- endfor %}
        <|im_start|>assistant<|im_sep|>
        """
        let result = RenderConsistencyChecker.check(chatTemplateRaw: template)

        XCTAssertEqual(result.status, .notApplicable)
        XCTAssertFalse(result.claim.toolsExpressible)
        XCTAssertFalse(result.toolDefinitionRendered)
        XCTAssertNil(result.declaredDelimiterRendered)
    }

    func testNilTemplateIsNotApplicable() {
        let result = RenderConsistencyChecker.check(chatTemplateRaw: nil)
        XCTAssertEqual(result.status, .notApplicable)
        XCTAssertFalse(result.claim.toolsExpressible)
    }

    func testBlankTemplateIsNotApplicable() {
        let result = RenderConsistencyChecker.check(chatTemplateRaw: "   \n\t  ")
        XCTAssertEqual(result.status, .notApplicable)
        XCTAssertFalse(result.claim.toolsExpressible)
    }

    // MARK: - Broken template: claims tools, never emits the tool name

    func testGuardPresentButToolNameNeverEmittedIsInconsistent() {
        // The `{% if tools %}` guard makes the Layer-1 claim positive, but the
        // body never iterates `tools` nor emits any tool name — the #1909 class.
        // The renderer produces a non-nil prompt that simply lacks `get_weather`.
        let template = """
        {%- if tools %}
        (this model supports tools)
        {%- endif %}
        {%- for message in messages %}
        {{ message.role }}: {{ message.content }}
        {%- endfor %}
        """
        let result = RenderConsistencyChecker.check(chatTemplateRaw: template)

        XCTAssertEqual(result.status, .inconsistent)
        XCTAssertFalse(result.toolDefinitionRendered)
        XCTAssertTrue(
            result.detail.contains("get_weather"),
            "detail should name the missing tool definition; was: \(result.detail)"
        )

        // SABOTAGE (verified 2026-06-22, then removed): asserting the opposite
        // here — XCTAssertEqual(result.status, .consistent) — fails, proving the
        // test catches a checker that stops flagging the dropped tool grammar.
    }
}
