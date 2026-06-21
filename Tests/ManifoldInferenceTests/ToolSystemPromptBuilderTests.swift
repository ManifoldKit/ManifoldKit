import XCTest
@testable import ManifoldInference

/// Unit tests for ``ToolSystemPromptBuilder``.
///
/// These tests pin the shape of the generated preamble so that downstream
/// regression checks (e.g. tool-call hit-rate evaluators) have a stable
/// reference. The AI-product review that motivated this helper tracked
/// invocation rates across prompt variants; if we ever change the canonical
/// phrasing we want the change to be a deliberate, tested update rather
/// than a silent edit in a different file.
final class ToolSystemPromptBuilderTests: XCTestCase {

    // MARK: - Fixtures

    /// Two tools with different required-args shapes: a single-required-arg
    /// object schema (weather/city) and a no-required-args helper (clock).
    /// Covers the "(requires: …)" suffix both with and without args.
    private func fixtureTools() -> [ToolDefinition] {
        let weatherSchema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")])
            ]),
            "required": .array([.string("city")])
        ])
        let clockSchema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return [
            ToolDefinition(name: "get_weather", description: "Returns weather for a city.", parameters: weatherSchema),
            ToolDefinition(name: "get_current_time", description: "Returns the current wall-clock time.", parameters: clockSchema)
        ]
    }

    // MARK: - Style variants produce distinct but valid prompts

    func test_standardStyle_includesAllTools() {
        let tools = fixtureTools()
        let prompt = ToolSystemPromptBuilder.preferTools(for: tools, style: .standard)

        // SABOTAGE TARGET: the `definitions.map(renderTool)` call. Replacing
        // it with `[]` or `[definitions.first!]` will make these asserts fail.
        XCTAssertTrue(prompt.contains("get_weather"), "standard must enumerate every tool by name")
        XCTAssertTrue(prompt.contains("get_current_time"))
        XCTAssertTrue(prompt.contains("Returns weather for a city."))
        XCTAssertTrue(prompt.contains("Returns the current wall-clock time."))
        XCTAssertTrue(prompt.contains("requires: city"), "required-arg tools list their required names")

        // Imperative phrasing — the core "MUST call" shaping.
        XCTAssertTrue(prompt.contains("MUST call"))
        XCTAssertTrue(prompt.contains("Never guess"))
    }

    func test_strictStyle_includesRefusalClause() {
        let prompt = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .strict)

        XCTAssertTrue(prompt.contains("MUST call"))
        // The differentiating clause vs .standard.
        XCTAssertTrue(prompt.contains("I don't have a tool for that"))
    }

    func test_minimalStyle_listsToolsWithoutImperatives() {
        let prompt = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .minimal)

        XCTAssertTrue(prompt.contains("get_weather"))
        XCTAssertTrue(prompt.contains("get_current_time"))
        // Imperatives must not leak into .minimal — the consumer is driving.
        XCTAssertFalse(prompt.contains("MUST call"), "minimal preset must not include imperative phrasing")
        XCTAssertFalse(prompt.contains("I don't have a tool"), "minimal preset must not include refusal clause")
    }

    // MARK: - Templateless JSON tool-call format (#2002)

    /// The imperative presets must spell out the concrete JSON envelope local
    /// parsers consume — templateless models (Phi-3.5, Mistral GGUF) reach the
    /// model through this preamble alone and otherwise improvise an unparseable
    /// Pythonic `tool_call(...)` shape.
    func test_standardStyle_specifiesJSONToolCallFormat() {
        let prompt = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .standard)

        // SABOTAGE TARGET: `toolCallFormatInstruction`. Reverting it to the old
        // vague "emit the appropriate tool_call" phrasing fails these asserts.
        XCTAssertTrue(prompt.contains("{\"name\":"), "must show the JSON envelope key \"name\"")
        XCTAssertTrue(prompt.contains("\"arguments\":"), "must show the JSON envelope key \"arguments\"")
        XCTAssertTrue(
            prompt.contains("Python-style function call"),
            "must explicitly prohibit the Pythonic positional-call shape (#2002)"
        )
    }

    func test_strictStyle_specifiesJSONToolCallFormat() {
        let prompt = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .strict)

        XCTAssertTrue(prompt.contains("{\"name\":"))
        XCTAssertTrue(prompt.contains("\"arguments\":"))
        XCTAssertTrue(prompt.contains("Python-style function call"))
        // Strict still carries its differentiating refusal clause alongside the format.
        XCTAssertTrue(prompt.contains("I don't have a tool for that"))
    }

    /// The JSON-format instruction is an imperative — `.minimal` (app drives the
    /// format) must not carry it.
    func test_minimalStyle_omitsJSONFormatInstruction() {
        let prompt = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .minimal)

        XCTAssertFalse(prompt.contains("{\"name\":"), "minimal must not dictate a tool-call format")
        XCTAssertFalse(prompt.contains("Python-style function call"))
    }

    /// The listing names every parameter (the JSON keys the model must use),
    /// not just the required subset.
    func test_listing_namesAllArguments() {
        let prompt = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .standard)
        // weather declares one property `city`, which is also required.
        XCTAssertTrue(prompt.contains("(arguments: city)"), "must enumerate the tool's argument names")
    }

    /// Argument ordering is deterministic: required args lead in schema order,
    /// optional properties follow alphabetically (properties is an unordered
    /// dictionary, so a raw key walk would be byte-unstable).
    func test_argumentNames_requiredLeadThenOptionalSorted() {
        let schema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")]),
                "zebra": .object(["type": .string("string")]),
                "apple": .object(["type": .string("string")])
            ]),
            "required": .array([.string("city")])
        ])
        let def = ToolDefinition(name: "weather", description: "x", parameters: schema)
        let prompt = ToolSystemPromptBuilder.preferTools(for: [def], style: .minimal)
        XCTAssertTrue(
            prompt.contains("(arguments: city, apple, zebra)"),
            "required `city` leads; optional `apple`/`zebra` follow alphabetically; got:\n\(prompt)"
        )
    }

    func test_stylesProduceDistinctOutput() {
        let standard = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .standard)
        let strict = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .strict)
        let minimal = ToolSystemPromptBuilder.preferTools(for: fixtureTools(), style: .minimal)

        XCTAssertNotEqual(standard, strict)
        XCTAssertNotEqual(standard, minimal)
        XCTAssertNotEqual(strict, minimal)
    }

    // MARK: - Empty tools list

    func test_emptyTools_returnsEmptyString_safeToConcat() {
        // The doc-commented contract: empty-tools returns "" (not a
        // descriptive note), so `preamble + systemPrompt` is safe.
        let prompt = ToolSystemPromptBuilder.preferTools(for: [], style: .standard)
        XCTAssertEqual(prompt, "", "empty tools list must return empty string — safe to concat verbatim")

        let strict = ToolSystemPromptBuilder.preferTools(for: [], style: .strict)
        XCTAssertEqual(strict, "")

        let minimal = ToolSystemPromptBuilder.preferTools(for: [], style: .minimal)
        XCTAssertEqual(minimal, "")
    }

    // MARK: - Special-character tool names

    func test_toolNamesWithSpecialChars_includedVerbatim() {
        // Tool name with dots, dashes, underscores, unicode. Some backends
        // reject these at dispatch time, but the builder itself must not
        // mangle them — that's the caller's problem.
        let odd = ToolDefinition(
            name: "weather.ν2-lookup_tool",
            description: "Exotic name.",
            parameters: .object([:])
        )
        let prompt = ToolSystemPromptBuilder.preferTools(for: [odd], style: .standard)
        XCTAssertTrue(prompt.contains("weather.ν2-lookup_tool"), "special-char names must be emitted verbatim")
    }

    // MARK: - Required args ordering

    func test_requiredArgs_preserveSchemaOrder() {
        // Schema order: city, units, date. The preamble must list them in
        // the same order — consumers who care about prompt ordering pin it
        // here.
        let schema: JSONSchemaValue = .object([
            "type": .string("object"),
            "required": .array([.string("city"), .string("units"), .string("date")])
        ])
        let def = ToolDefinition(name: "weather", description: "x", parameters: schema)
        let prompt = ToolSystemPromptBuilder.preferTools(for: [def], style: .minimal)
        XCTAssertTrue(
            prompt.contains("requires: city, units, date"),
            "required-arg order must match schema declaration order; got:\n\(prompt)"
        )
    }

    func test_toolWithoutRequiredArgs_omitsRequiresClause() {
        let def = ToolDefinition(name: "ping", description: "no args", parameters: .object([:]))
        let prompt = ToolSystemPromptBuilder.preferTools(for: [def], style: .minimal)
        XCTAssertFalse(prompt.contains("requires:"), "tools with no required args must not emit '(requires: )' suffix")
    }
}
