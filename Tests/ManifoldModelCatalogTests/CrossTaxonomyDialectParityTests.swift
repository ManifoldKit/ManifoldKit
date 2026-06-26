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
/// - Correction to the #2039 record: of the two pre-fix close spellings, only
///   `<|/tool_call>` was genuinely invented (it appears in no template). `<tool_call|>`
///   is NOT invented — it is the literal close the Ollama `gemma3-4b-tools` community
///   model's baked template emits (`<|tool_call>call:NAME{…}<tool_call|>`, verified
///   2026-06 via `ollama show gemma3-4b-tools --template`). But that model is
///   **Gemma-3**, a different family from the repo's Gemma-4 `.gemma` dialect, so its
///   close legitimately differs. `<|end_of_turn>` remains the adjudicated truth for the
///   Gemma-4 `.gemma` dialect; the Gemma-3 vs Gemma-4 close split is pinned by
///   `testGemma3CommunityCloseIsADistinctFamilyNotTheGemma4Close` below.
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

    /// The Ollama `gemma3-4b-tools` community model bakes a tool-call template whose
    /// close delimiter is `<tool_call|>` — NOT the `<|end_of_turn>` the repo's Gemma-4
    /// `.gemma` dialect uses. Verified 2026-06 against the live template, which emits:
    ///
    ///     {{- '<|tool_call>call:' + function['name'] + '{' -}} … {{- '}<tool_call|>' -}}
    ///
    /// i.e. `<|tool_call>call:get_weather{location:<|"|>Paris<|"|>}<tool_call|>`.
    ///
    /// This corrects the #2039 record: `<tool_call|>` is not an "invented" spelling —
    /// it is a real Gemma-3 emission. But Gemma-3 is a *different family* from the repo's
    /// Gemma-4 `.gemma` dialect (`PromptTemplate.gemma4`, `ThinkingMarkers.gemma4`,
    /// companion `LlamaToolMarkers.gemma4EndTurn`), so the two closes genuinely differ.
    /// Pin the split so a future reader — or a stale overnight brief pointing at the
    /// gemma3 Ollama model as "ground truth" — does not "fix" the Gemma-4 `.gemma` close
    /// back to `<tool_call|>` and break the whole-repo Gemma-4 consensus. NB: Ollama
    /// returns structured `tool_calls` JSON, so the marker parser never scans this
    /// template's raw close at runtime — the divergence is a catalog/descriptor concern,
    /// not a live parse bug.
    func testGemma3CommunityCloseIsADistinctFamilyNotTheGemma4Close() {
        // Ground truth: the literal close the Gemma-3 community template emits.
        let gemma3CommunityClose = "<tool_call|>"
        // The repo's `.gemma` dialect models Gemma-4, closing at the turn terminator.
        let gemma4DialectClose = ManifoldHardware.ToolCallDialect.gemma.closeDelimiter

        XCTAssertEqual(
            gemma4DialectClose, "<|end_of_turn>",
            "Gemma-4 `.gemma` dialect close changed — re-confirm against PromptTemplate.gemma4 / LlamaToolMarkers"
        )
        XCTAssertNotEqual(
            gemma3CommunityClose, gemma4DialectClose,
            "Gemma-3 community close and Gemma-4 dialect close collapsed to one value — re-adjudicate the family split before unifying"
        )

        // The catalog descriptor's heuristic maps any `<|tool_call>` template to the
        // Gemma-4 close `<|end_of_turn>` — correct for the modelled family, and notably
        // independent of the (Gemma-3) `<tool_call|>` literal present in the same input.
        let claim = ChatTemplateToolDescriptor(parsingChatTemplate: """
        {%- if tools %}You may call tools.{%- endif %}
        <|tool_call>call:get_weather{location:<|"|>Paris<|"|>}<tool_call|>
        """)
        XCTAssertEqual(
            claim.declaredDialect?.closeDelimiter, "<|end_of_turn>",
            "ChatTemplateToolDescriptor Gemma close drifted from the Gemma-4 dialect"
        )
        XCTAssertNotEqual(
            claim.declaredDialect?.closeDelimiter, gemma3CommunityClose,
            "Descriptor now reports the Gemma-3 community close — family split lost"
        )
    }
}
