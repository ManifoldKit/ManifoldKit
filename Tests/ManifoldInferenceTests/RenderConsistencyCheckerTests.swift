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

    // MARK: - Committed family-template corpus (single source of truth)
    //
    // The gate test (`testKnownGoodFamilyTemplatesNeverRenderInconsistent`) and
    // the per-family round-trip tests both fold over these constants, so the
    // CI invariant and the documented behaviour can never drift. The corpus is
    // deliberately committed (not runtime-discovered) so CI stays deterministic.

    /// Qwen / Hermes `<tool_call>…</tool_call>` JSON dialect behind `{% if tools %}`.
    static let qwenStyleTemplate = """
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

    /// Gemma-style `<|tool_call>` key/value dialect behind `{% if tools %}`.
    static let gemmaStyleTemplate = """
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

    /// Mistral-v0.3 `[TOOL_CALLS]` dialect behind a `tools is not none` guard.
    static let mistralStyleTemplate = """
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

    /// Hermes-style `<tool_call>` dialect behind a bare `{% for tool in tools %}`
    /// guard (no `if`).
    static let hermesStyleTemplate = """
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

    /// Llama-3.1 `Environment: ipython` guard, bare-JSON dialect — declares NO
    /// open delimiter, so consistency hinges on the tool name alone.
    static let llamaStyleTemplate = """
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

    /// Phi-4-style: no tools guard at all → trustworthy negative claim
    /// (`notApplicable`, not `inconsistent` — there is nothing to round-trip).
    static let phiToollessTemplate = """
    {%- for message in messages %}
    <|im_start|>{{ message.role }}<|im_sep|>{{ message.content }}<|im_end|>
    {%- endfor %}
    <|im_start|>assistant<|im_sep|>
    """

    /// The known-good family corpus the CI gate folds over. Includes both
    /// tool-bearing families (which must render `.consistent`) and the toolless
    /// Phi-4 case (which must render `.notApplicable`) — the gate's invariant is
    /// "no known-good family template ever renders `.inconsistent`".
    static let familyCorpus: [(name: String, template: String)] = [
        ("Qwen/Hermes", qwenStyleTemplate),
        ("Gemma", gemmaStyleTemplate),
        ("Mistral-v0.3", mistralStyleTemplate),
        ("Hermes (for-guard)", hermesStyleTemplate),
        ("Llama-3.1", llamaStyleTemplate),
        ("Phi-4 (toolless)", phiToollessTemplate),
    ]

    // MARK: - CI gate (the regression spine)

    /// Folds ``RenderConsistencyChecker/check(chatTemplateRaw:)`` over the whole
    /// committed family corpus and **fails on any `.inconsistent`** verdict.
    ///
    /// This encodes the #2005 acceptance invariant: these known-good family
    /// templates declare tool dialects MK's renderer actually emits, so the
    /// render path can never silently drop their tool grammar (the #1909 class)
    /// without this gate going red. `.consistent` and `.notApplicable` both pass
    /// — only `.inconsistent` is the regression we guard against.
    func testKnownGoodFamilyTemplatesNeverRenderInconsistent() {
        for entry in Self.familyCorpus {
            let result = RenderConsistencyChecker.check(chatTemplateRaw: entry.template)
            XCTAssertNotEqual(
                result.status,
                .inconsistent,
                "Family template '\(entry.name)' regressed to .inconsistent — "
                + "its declared tool dialect no longer survives MK's render path "
                + "(the #1909 class). Detail: \(result.detail)"
            )
        }
    }

    // MARK: - Recognised families render consistently

    func testQwenStyleRendersConsistently() {
        let result = RenderConsistencyChecker.check(chatTemplateRaw: Self.qwenStyleTemplate)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertEqual(result.declaredDelimiterRendered, true)
        XCTAssertEqual(result.claim.declaredDialect?.openDelimiter, "<tool_call>")
        XCTAssertEqual(result.detail, "")
    }

    func testGemmaStyleRendersConsistently() {
        let result = RenderConsistencyChecker.check(chatTemplateRaw: Self.gemmaStyleTemplate)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertEqual(result.declaredDelimiterRendered, true)
        XCTAssertEqual(result.claim.declaredDialect?.openDelimiter, "<|tool_call>")
    }

    func testMistralStyleRendersConsistently() {
        let result = RenderConsistencyChecker.check(chatTemplateRaw: Self.mistralStyleTemplate)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertEqual(result.declaredDelimiterRendered, true)
        XCTAssertEqual(result.claim.declaredDialect?.openDelimiter, "[TOOL_CALLS]")
    }

    func testHermesStyleRendersConsistently() {
        let result = RenderConsistencyChecker.check(chatTemplateRaw: Self.hermesStyleTemplate)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertEqual(result.declaredDelimiterRendered, true)
    }

    func testLlamaStyleNoDelimiterRendersConsistently() {
        // Llama-3.1: the claim declares NO open delimiter, so
        // declaredDelimiterRendered must be nil and consistency must hinge on
        // the tool name alone.
        let result = RenderConsistencyChecker.check(chatTemplateRaw: Self.llamaStyleTemplate)

        XCTAssertEqual(result.status, .consistent, result.detail)
        XCTAssertTrue(result.toolDefinitionRendered)
        XCTAssertNil(result.declaredDelimiterRendered, "bare-JSON dialect has no opener to assert")
        XCTAssertNil(result.claim.declaredDialect?.openDelimiter)
    }

    // MARK: - Not applicable

    func testToollessTemplateIsNotApplicable() {
        // Phi-style: no tools guard at all → trustworthy negative claim.
        let result = RenderConsistencyChecker.check(chatTemplateRaw: Self.phiToollessTemplate)

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
