import XCTest
@testable import ManifoldInference

final class ToolGrammarBuilderTests: XCTestCase {

    private let builder = ToolGrammarBuilder()

    private func tool(_ name: String, parameters: JSONSchemaValue = .object([:])) -> ToolDefinition {
        ToolDefinition(name: name, description: "d", parameters: parameters)
    }

    // MARK: - Empty / nil cases

    func test_emptyTools_returnsNil() {
        XCTAssertNil(builder.buildGrammar(for: []))
    }

    // MARK: - Structural sanity

    func test_singleTool_hasRootRuleAndQuotedName() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("get_weather")]))
        XCTAssertTrue(grammar.contains("root"), "grammar must define a root rule")
        XCTAssertTrue(grammar.contains("toolname"), "grammar must define a toolname rule")
        // The name appears as a JSON-quoted literal inside a GBNF literal.
        XCTAssertTrue(
            grammar.contains("\\\"get_weather\\\""),
            "tool name must appear as a quoted literal; got:\n\(grammar)"
        )
        // The envelope constrains the "name" and "arguments" keys.
        XCTAssertTrue(grammar.contains("\\\"name\\\""))
        XCTAssertTrue(grammar.contains("\\\"arguments\\\""))
    }

    func test_multipleTools_produceAlternationOfNames() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("a"), tool("b"), tool("c")]))
        XCTAssertTrue(grammar.contains("\\\"a\\\""))
        XCTAssertTrue(grammar.contains("\\\"b\\\""))
        XCTAssertTrue(grammar.contains("\\\"c\\\""))
        // Alternation: the toolname rule must join names with `|`.
        let toolnameLine = grammar
            .split(separator: "\n")
            .first { $0.hasPrefix("toolname") }
            .map(String.init) ?? ""
        XCTAssertTrue(toolnameLine.contains("|"), "multiple tools must alternate with `|`; got: \(toolnameLine)")
        XCTAssertEqual(toolnameLine.components(separatedBy: "|").count, 3, "three tools → two `|` separators")
    }

    func test_duplicateNames_deduplicated() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("dup"), tool("dup")]))
        let toolnameLine = grammar
            .split(separator: "\n")
            .first { $0.hasPrefix("toolname") }
            .map(String.init) ?? ""
        XCTAssertFalse(toolnameLine.contains("|"), "duplicate names collapse to a single alternative")
    }

    // MARK: - Escaping

    func test_escaping_quoteInName() {
        // A name containing a double quote must not produce an unbalanced literal.
        let escaped = ToolGrammarBuilder.escapeForGBNFLiteral("a\"b")
        // JSON-escaped quote (\") then GBNF-escaped → backslash-backslash-backslash-quote.
        XCTAssertEqual(escaped, "a\\\\\\\"b")
    }

    func test_escaping_backslashInName() {
        let escaped = ToolGrammarBuilder.escapeForGBNFLiteral("a\\b")
        XCTAssertEqual(escaped, "a\\\\\\\\b")
    }

    func test_escaping_controlCharsAndTab() {
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\tb"), "a\\\\tb")
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\nb"), "a\\\\nb")
        // A bell (U+0007) is an "other" control char → \u escape.
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\u{07}b"), "a\\\\u0007b")
    }

    func test_escaping_plainNameUnchanged() {
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("get_weather-2"), "get_weather-2")
    }

    func test_nameWithQuote_appearsEscapedInGrammar_noBareQuote() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("a\"b")]))
        XCTAssertTrue(grammar.contains("a\\\\\\\"b"), "quoted name must be doubly escaped in the grammar")
    }

    // MARK: - Pre-validator fallback

    func test_preValidatorRejectedSchema_droppedFromEnum() {
        // `anyOf` is rejected by the (conservative) pre-validator.
        let rejected = tool("bad", parameters: .object([
            "anyOf": .array([.object(["type": .string("string")])])
        ]))
        let ok = tool("good")
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [rejected, ok]))
        XCTAssertTrue(grammar.contains("\\\"good\\\""))
        XCTAssertFalse(grammar.contains("\\\"bad\\\""), "tool with rejected schema must be dropped")
    }

    func test_allToolsRejected_returnsNil() {
        let rejected = tool("bad", parameters: .object([
            "oneOf": .array([.object(["type": .string("string")])])
        ]))
        XCTAssertNil(builder.buildGrammar(for: [rejected]))
    }

    // MARK: - Golden snapshot (fixed 2-tool input)

    func test_goldenSnapshot_twoTools() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("alpha"), tool("beta")]))
        let expected = """
        root      ::= "{" ws "\\"name\\"" ws ":" ws toolname ws "," ws "\\"arguments\\"" ws ":" ws object ws "}"
        toolname  ::= "\\"alpha\\"" | "\\"beta\\""
        object    ::= "{" ws ( member ( ws "," ws member )* )? ws "}"
        member    ::= string ws ":" ws value
        array     ::= "[" ws ( value ( ws "," ws value )* )? ws "]"
        value     ::= object | array | string | number | "true" | "false" | "null"
        string    ::= "\\"" char* "\\""
        char      ::= [^"\\\\] | "\\\\" escape
        escape    ::= ["\\\\/bfnrt] | "u" hex hex hex hex
        hex       ::= [0-9a-fA-F]
        number    ::= "-"? int frac? exp?
        int       ::= "0" | [1-9] [0-9]*
        frac      ::= "." [0-9]+
        exp       ::= [eE] [+-]? [0-9]+
        ws        ::= [ \\t\\n]*
        """
        XCTAssertEqual(grammar, expected)
    }
}
