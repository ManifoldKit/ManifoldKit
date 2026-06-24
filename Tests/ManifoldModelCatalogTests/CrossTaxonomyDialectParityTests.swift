import XCTest
@testable import ManifoldModelCatalog
import ManifoldHardware

/// Cross-taxonomy tool-call dialect parity (#2005, plan Phase 1a / Layer 1b).
///
/// ManifoldKit hand-maintains the *same* per-family tool-call facts in three
/// overlapping taxonomies, each re-deriving them from the same chat templates:
///
/// 1. `ManifoldHardware.ToolCallDialect` — the canonical dialect presets
///    (`.hermes`, `.qwen`, `.gemma`, `.mistral`, `.llamaPythonTag`).
/// 2. `ManifoldModelCatalog.ChatTemplateToolDescriptor` — the template-derived
///    *claim* (a separate, nested `ToolCallDialect`).
/// 3. The actual runtime parser markers (`ToolCallMarker` in `ManifoldContract`,
///    instantiated per-family in the companion targets).
///
/// Because each is hand-maintained, they can — and today do — disagree. This
/// suite pins each taxonomy against a single **adjudicated ground-truth table**
/// so a disagreement fails CI deterministically (in milliseconds, no model)
/// instead of surfacing only in a multi-hour live conformance soak. It is the
/// precursor tripwire for the `ChatProfile` consolidation (plan Phase 1b): the
/// consolidation is "produce the same goldens".
///
/// ## Ground-truth source
///
/// The table below is adjudicated against the code that *actually parses* model
/// output, not against either descriptor's hand-written constant:
/// - Gemma-4 tool calls open with `<|tool_call>` and close at the turn
///   terminator `<|end_of_turn>` — there is no dedicated close-tool tag. This is
///   what the runtime marker uses: companion `LlamaToolMarkers.swift`
///   (`gemma4OpenTag = "<|tool_call>"`, `gemma4EndTurn = "<|end_of_turn>"`,
///   wired as `ToolCallMarker(open: gemma4OpenTag, close: gemma4EndTurn)`),
///   corroborated by `ToolCallTransform`'s doc ("Gemma-4 native `<|tool_call>`…
///   `<|end_of_turn>`") and `PromptTemplate.gemma4`'s special-token set (which
///   carries `<|tool_call>` and `<|end_of_turn>` but neither `<tool_call|>` nor
///   `<|/tool_call>`).
/// - The two descriptors each invented a *different, never-parsed* close spelling
///   (`<tool_call|>` and `<|/tool_call>`). Both are wrong; `<|end_of_turn>` is the
///   adjudicated truth.
final class CrossTaxonomyDialectParityTests: XCTestCase {

    /// One adjudicated dialect both descriptor taxonomies are expected to model
    /// identically, with a representative template that drives the
    /// `ChatTemplateToolDescriptor` heuristic down the matching branch.
    private struct DialectGroundTruth {
        let family: String
        let representativeTemplate: String
        let hardwarePreset: ManifoldHardware.ToolCallDialect
        let expectedOpen: String?
        let expectedClose: String?
        /// `true` → `keyValue` arg encoding; `false` → `json`.
        let expectedKeyValueArgs: Bool
    }

    private let groundTruth: [DialectGroundTruth] = [
        // Hermes-2-Pro: `{% for tool in tools %}` guard, `<tool_call>…</tool_call>` JSON.
        DialectGroundTruth(
            family: "hermes",
            representativeTemplate: """
            {% for tool in tools %}{{ tool.function | tojson }}{% endfor %}
            <tool_call>
            {"name": "get_weather", "arguments": {"location": "Paris"}}
            </tool_call>
            """,
            hardwarePreset: .hermes,
            expectedOpen: "<tool_call>",
            expectedClose: "</tool_call>",
            expectedKeyValueArgs: false
        ),
        // Qwen2.5-Instruct: `{% if tools %}` guard, same `<tool_call>` wrapper as Hermes.
        // (The descriptor has no notion of family; it maps both to `<tool_call>`.)
        DialectGroundTruth(
            family: "qwen",
            representativeTemplate: """
            {%- if tools %}<tools>{%- for tool in tools %}{{ tool | tojson }}{%- endfor %}</tools>{%- endif %}
            <tool_call>
            {"name": "get_weather", "arguments": {"location": "Paris"}}
            </tool_call>
            """,
            hardwarePreset: .qwen,
            expectedOpen: "<tool_call>",
            expectedClose: "</tool_call>",
            expectedKeyValueArgs: false
        ),
        // Mistral-v0.3: `tools is not none` guard, `[TOOL_CALLS]` sentinel, no close tag.
        DialectGroundTruth(
            family: "mistral",
            representativeTemplate: """
            {%- if tools is not none %}[AVAILABLE_TOOLS] {{ tools | tojson }} [/AVAILABLE_TOOLS]{%- endif %}
            [TOOL_CALLS] [{"name": "get_weather", "arguments": {"location": "Paris"}}]
            """,
            hardwarePreset: .mistral,
            expectedOpen: "[TOOL_CALLS]",
            expectedClose: nil,
            expectedKeyValueArgs: false
        ),
        // Gemma-4: `{% if tools %}` guard, `<|tool_call>` open, turn-terminated close
        // `<|end_of_turn>`, key:value args. THE adjudicated contradiction — before the
        // fix both taxonomies report a different (and wrong) close delimiter.
        DialectGroundTruth(
            family: "gemma",
            representativeTemplate: """
            {%- if tools %}You may call tools.{%- endif %}
            <|tool_call>
            name: get_weather
            location: Paris
            <|end_of_turn>
            """,
            hardwarePreset: .gemma,
            expectedOpen: "<|tool_call>",
            expectedClose: "<|end_of_turn>",
            expectedKeyValueArgs: true
        ),
    ]

    /// Both taxonomies must agree with the adjudicated ground truth on the
    /// open/close delimiters and argument encoding for every modelled family.
    func testTaxonomiesAgreeWithAdjudicatedGroundTruth() {
        for truth in groundTruth {
            let claim = ChatTemplateToolDescriptor(parsingChatTemplate: truth.representativeTemplate)
            let derived = claim.declaredDialect

            XCTAssertNotNil(derived, "[\(truth.family)] descriptor failed to derive a dialect")

            // --- Open delimiter ---
            XCTAssertEqual(
                derived?.openDelimiter, truth.expectedOpen,
                "[\(truth.family)] ChatTemplateToolDescriptor open delimiter diverges from ground truth"
            )
            XCTAssertEqual(
                truth.hardwarePreset.openDelimiter, truth.expectedOpen,
                "[\(truth.family)] ManifoldHardware.ToolCallDialect open delimiter diverges from ground truth"
            )

            // --- Close delimiter (the Gemma contradiction lives here) ---
            XCTAssertEqual(
                derived?.closeDelimiter, truth.expectedClose,
                "[\(truth.family)] ChatTemplateToolDescriptor close delimiter diverges from ground truth"
            )
            XCTAssertEqual(
                truth.hardwarePreset.closeDelimiter, truth.expectedClose,
                "[\(truth.family)] ManifoldHardware.ToolCallDialect close delimiter diverges from ground truth"
            )

            // --- Argument encoding (compared by stable raw value across the two enums) ---
            let expectedEncodingRaw = truth.expectedKeyValueArgs ? "keyValue" : "json"
            XCTAssertEqual(
                derived?.argEncoding.rawValue, expectedEncodingRaw,
                "[\(truth.family)] ChatTemplateToolDescriptor arg encoding diverges from ground truth"
            )
            XCTAssertEqual(
                truth.hardwarePreset.argEncoding.rawValue, expectedEncodingRaw,
                "[\(truth.family)] ManifoldHardware.ToolCallDialect arg encoding diverges from ground truth"
            )
        }
    }

    /// Direct cross-taxonomy check, independent of the ground-truth table: for
    /// every modelled family the two hand-maintained descriptors must agree on
    /// open and close delimiters. This is the parity the `ChatProfile`
    /// consolidation will make structural.
    func testDescriptorAndHardwareDialectsAgreePairwise() {
        for truth in groundTruth {
            let claim = ChatTemplateToolDescriptor(parsingChatTemplate: truth.representativeTemplate)
            guard let derived = claim.declaredDialect else {
                XCTFail("[\(truth.family)] descriptor failed to derive a dialect")
                continue
            }
            XCTAssertEqual(
                derived.openDelimiter, truth.hardwarePreset.openDelimiter,
                "[\(truth.family)] open delimiter disagrees between the catalog claim and the hardware preset"
            )
            XCTAssertEqual(
                derived.closeDelimiter, truth.hardwarePreset.closeDelimiter,
                "[\(truth.family)] close delimiter disagrees between the catalog claim and the hardware preset"
            )
            XCTAssertEqual(
                derived.argEncoding.rawValue, truth.hardwarePreset.argEncoding.rawValue,
                "[\(truth.family)] arg encoding disagrees between the catalog claim and the hardware preset"
            )
        }
    }

    /// Llama-3.1 is deliberately modelled by the two taxonomies as *different*
    /// sub-dialects, and that divergence is intentional — pin it so a future
    /// reader does not "fix" it into a false agreement:
    ///
    /// - `ManifoldHardware.ToolCallDialect.llamaPythonTag` models the python-tag
    ///   custom-tool path (`<|python_tag|>` opener, key:value args).
    /// - `ChatTemplateToolDescriptor` models the *default* Llama-3.1 bare-JSON
    ///   path (no opener, JSON args), which is the `buried` extractability case.
    ///
    /// Both are real Llama-3.1 emission shapes; the descriptor reports the one a
    /// pure template parse can claim (bare JSON), while the hardware preset names
    /// the explicit python-tag variant. Unifying them is a `ChatProfile`-era
    /// decision, not a Phase-1a delimiter bug.
    func testLlamaPythonTagVersusBareJSONIsAnIntentionalSplit() {
        let llamaTemplate = """
        <|start_header_id|>system<|end_header_id|>
        Environment: ipython
        <|python_tag|>{"name": "get_weather", "parameters": {"location": "Paris"}}
        """
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: llamaTemplate)

        // Descriptor: the bare-JSON / buried path — no opener.
        XCTAssertNil(claim.declaredDialect?.openDelimiter)
        XCTAssertEqual(claim.extractability, .buried)

        // Hardware preset: the explicit python-tag path — an opener, key:value args.
        XCTAssertEqual(ManifoldHardware.ToolCallDialect.llamaPythonTag.openDelimiter, "<|python_tag|>")
        XCTAssertEqual(ManifoldHardware.ToolCallDialect.llamaPythonTag.extractability, .buried)

        // The split is the point: the two openers genuinely differ by design.
        XCTAssertNotEqual(
            claim.declaredDialect?.openDelimiter,
            ManifoldHardware.ToolCallDialect.llamaPythonTag.openDelimiter,
            "Llama python-tag vs bare-JSON split changed shape — re-adjudicate before unifying"
        )
    }
}
