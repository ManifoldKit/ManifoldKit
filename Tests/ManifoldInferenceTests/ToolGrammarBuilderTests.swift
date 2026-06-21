import XCTest
@testable import ManifoldInference

final class ToolGrammarBuilderTests: XCTestCase {

    private let builder = ToolGrammarBuilder()

    private func tool(_ name: String, parameters: JSONSchemaValue = .object([:])) -> ToolDefinition {
        ToolDefinition(name: name, description: "d", parameters: parameters)
    }

    /// The shared generic-JSON rule block appended to every grammar. Pulled out
    /// so the structural goldens below stay focused on the per-tool prologue.
    private let genericTail = #"""
    object ::= "{" ws ( member ( ws "," ws member )* )? ws "}"
    member ::= string ws ":" ws value
    array ::= "[" ws ( value ( ws "," ws value )* )? ws "]"
    value ::= object | array | string | number | "true" | "false" | "null"
    string ::= "\"" char* "\""
    char ::= [^"\\] | "\\" escape
    escape ::= ["\\/bfnrt] | "u" hex hex hex hex
    hex ::= [0-9a-fA-F]
    number ::= "-"? int frac? exp?
    integer ::= "-"? int
    int ::= "0" | [1-9] [0-9]*
    frac ::= "." [0-9]+
    exp ::= [eE] [+-]? [0-9]+
    ws ::= [ \t\n]*
    """#

    // MARK: - Empty / nil cases

    func test_emptyTools_returnsNil() {
        XCTAssertNil(builder.buildGrammar(for: []))
    }

    // MARK: - Structural sanity

    func test_singleTool_hasRootRuleAndQuotedName() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("get_weather")]))
        XCTAssertTrue(grammar.hasPrefix("root ::="), "grammar must define a root rule first")
        XCTAssertTrue(grammar.contains("toolcall-0"), "single tool → one toolcall branch")
        // The name appears as a JSON-quoted literal inside a GBNF literal.
        XCTAssertTrue(
            grammar.contains(#""\"get_weather\"""#),
            "tool name must appear as a quoted literal; got:\n\(grammar)"
        )
        XCTAssertTrue(grammar.contains(#""\"name\"""#))
        XCTAssertTrue(grammar.contains(#""\"arguments\"""#))
    }

    func test_multipleTools_produceUnionOfBranches() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("a"), tool("b"), tool("c")]))
        let rootLine = grammar.split(separator: "\n").first.map(String.init) ?? ""
        // root alternates the per-tool branches.
        XCTAssertEqual(rootLine, "root ::= toolcall-0 | toolcall-1 | toolcall-2")
        XCTAssertTrue(grammar.contains(#""\"a\"""#))
        XCTAssertTrue(grammar.contains(#""\"b\"""#))
        XCTAssertTrue(grammar.contains(#""\"c\"""#))
    }

    func test_duplicateNames_deduplicated() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("dup"), tool("dup")]))
        let rootLine = grammar.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertEqual(rootLine, "root ::= toolcall-0", "duplicate names collapse to a single branch")
    }

    // MARK: - toolChoice modes (#1961)

    private func rootLine(_ grammar: String) -> String {
        grammar.split(separator: "\n").first.map(String.init) ?? ""
    }

    func test_permissive_rootAdmitsNonEmptyProseAndAllToolBranches() {
        let grammar = try! XCTUnwrap(
            builder.buildGrammar(for: [tool("a"), tool("b")], mode: .permissive)
        )
        // Root keeps every tool branch AND gains a prose alternative so the
        // first sampled token is never forced to EOS (#1961).
        XCTAssertEqual(rootLine(grammar), "root ::= toolcall-0 | toolcall-1 | prose")
        // prose is non-empty (mandatory head) and its first byte is never `{`,
        // keeping the alternation unambiguous at the first byte.
        XCTAssertTrue(grammar.contains("prose ::= prose-head prose-tail*"))
        XCTAssertTrue(grammar.contains("prose-head ::= [^{]"))
        XCTAssertTrue(grammar.contains(#"prose-tail ::= [^\x00]"#))
    }

    func test_strict_rootIsToolCallOnly_noProse() {
        let grammar = try! XCTUnwrap(
            builder.buildGrammar(for: [tool("a"), tool("b")], mode: .strict(only: nil))
        )
        XCTAssertEqual(rootLine(grammar), "root ::= toolcall-0 | toolcall-1")
        XCTAssertFalse(grammar.contains("prose"), "strict mode must not admit prose")
    }

    func test_strictOnly_namedTool_isSingleBranch() {
        let grammar = try! XCTUnwrap(
            builder.buildGrammar(
                for: [tool("a"), tool("b"), tool("c")],
                mode: .strict(only: "b")
            )
        )
        XCTAssertEqual(rootLine(grammar), "root ::= toolcall-0", "named tool → exactly one branch")
        XCTAssertTrue(grammar.contains(#""\"b\"""#), "the branch must be the named tool")
        XCTAssertFalse(grammar.contains(#""\"a\"""#))
        XCTAssertFalse(grammar.contains(#""\"c\"""#))
    }

    func test_strictOnly_absentTool_fallsBackToFullUnion() {
        let grammar = try! XCTUnwrap(
            builder.buildGrammar(
                for: [tool("a"), tool("b")],
                mode: .strict(only: "missing")
            )
        )
        // An absent name must not produce an empty (match-nothing) grammar.
        XCTAssertEqual(rootLine(grammar), "root ::= toolcall-0 | toolcall-1")
    }

    func test_defaultMode_isStrict() {
        // Source-compat: the parameterless default preserves forced-call shape.
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("a")]))
        XCTAssertFalse(grammar.contains("prose"))
    }

    // MARK: - Escaping

    func test_escaping_quoteInName() {
        let escaped = ToolGrammarBuilder.escapeForGBNFLiteral("a\"b")
        XCTAssertEqual(escaped, "a\\\\\\\"b")
    }

    func test_escaping_backslashInName() {
        let escaped = ToolGrammarBuilder.escapeForGBNFLiteral("a\\b")
        XCTAssertEqual(escaped, "a\\\\\\\\b")
    }

    func test_escaping_controlCharsAndTab() {
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\tb"), "a\\\\tb")
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\nb"), "a\\\\nb")
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\u{07}b"), "a\\\\u0007b")
    }

    func test_escaping_plainNameUnchanged() {
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("get_weather-2"), "get_weather-2")
    }

    // MARK: - Escaping: broadened control-char / multi-byte coverage

    /// Carriage return is escaped to a GBNF-escaped JSON `\r`, like `\n`/`\t`.
    func test_escaping_carriageReturn() {
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\rb"), "a\\\\rb")
    }

    /// A low control char without a named escape (here U+0001) becomes a
    /// GBNF-escaped JSON `` (lowercase 4-hex). U+001F is the top of the
    /// `< 0x20` control range and must also take the `\uXXXX` path.
    func test_escaping_lowControlChars_useUnicodeEscape() {
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\u{01}b"), "a\\\\u0001b")
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a\u{1F}b"), "a\\\\u001fb")
    }

    /// A multi-byte / emoji scalar (>= 0x20) passes through verbatim — GBNF
    /// double-quoted literals are byte-transparent for non-control, non-quote,
    /// non-backslash bytes, so no escaping is required.
    func test_escaping_emojiPassesThroughVerbatim() {
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("a🚀b"), "a🚀b")
        // An accented multi-byte BMP scalar likewise passes through.
        XCTAssertEqual(ToolGrammarBuilder.escapeForGBNFLiteral("café"), "café")
    }

    /// A name mixing quote, backslash, several control chars, and a multi-byte
    /// scalar exercises every branch of the escaper in one shot.
    func test_escaping_mixedSpecials() {
        XCTAssertEqual(
            ToolGrammarBuilder.escapeForGBNFLiteral("\"\\\n\t\r\u{02}🚀"),
            "\\\\\\\"" + "\\\\\\\\" + "\\\\n" + "\\\\t" + "\\\\r" + "\\\\u0002" + "🚀"
        )
    }

    /// Byte-exact: control chars + an emoji inside a *tool name* survive into the
    /// emitted `toolcall-0` branch literal. No live GBNF compiler in CI, so pin
    /// the exact bytes.
    func test_nameWithControlCharsAndEmoji_emitsExactBranch() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("a\n\t🚀b")]))
        let branchLine = grammar
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("toolcall-0 ::=") }
            .map(String.init) ?? ""
        XCTAssertEqual(
            branchLine,
            #"toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"a\\n\\t🚀b\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}""#
        )
    }

    /// Byte-exact: control chars + an emoji inside a *string-enum value* are
    /// escaped exactly like names (same escaper) and pinned in the `args-0-0`
    /// alternation.
    func test_enumValueWithControlCharsAndEmoji_emitsExactRule() {
        let t = tool("e", parameters: objectSchema([
            ("k", .object([
                "type": .string("string"),
                "enum": .array([.string("x\ny"), .string("🚀\tz")])
            ]))
        ], required: ["k"]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [t]))
        let enumLine = grammar
            .split(separator: "\n")
            .first { $0.hasPrefix("args-0-0 ::=") }
            .map(String.init) ?? ""
        XCTAssertEqual(enumLine, #"args-0-0 ::= ("\"x\\ny\"" | "\"🚀\\tz\"")"#)
    }

    // MARK: - Pre-flight lowering advisory (loweringReport)

    func test_loweringReport_fullVsDegraded() {
        let full = tool("ok", parameters: objectSchema([
            ("city", .object(["type": .string("string")]))
        ], required: ["city"]))
        let degraded = tool("weird", parameters: .object([
            "anyOf": .array([.object(["type": .string("string")])])
        ]))
        let reports = builder.loweringReport(for: [full, degraded])
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].toolName, "ok")
        XCTAssertTrue(reports[0].lowersFully)
        XCTAssertNil(reports[0].firstDegradation)
        XCTAssertEqual(reports[1].toolName, "weird")
        XCTAssertFalse(reports[1].lowersFully, "anyOf degrades to a generic value")
        XCTAssertEqual(reports[1].firstDegradation?.path, ["anyOf"])
    }

    /// A name containing a double quote must yield a *balanced* GBNF literal in
    /// the branch's `toolcall-0` rule. There is no live llama.cpp grammar
    /// compiler in this package's CI, so this pins the exact emitted bytes.
    func test_nameWithQuote_emitsExactBalancedGBNFLiteral() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("a\"b")]))
        let branchLine = grammar
            .split(separator: "\n")
            .first { $0.hasPrefix("toolcall-0 ::=") }
            .map(String.init) ?? ""
        // The name literal decodes to JSON `"a\"b"`.
        XCTAssertEqual(
            branchLine,
            #"toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"a\\\"b\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}""#
        )
    }

    func test_nameWithBackslash_emitsExactBalancedGBNFLiteral() {
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("a\\b")]))
        let branchLine = grammar
            .split(separator: "\n")
            .first { $0.hasPrefix("toolcall-0 ::=") }
            .map(String.init) ?? ""
        XCTAssertEqual(
            branchLine,
            #"toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"a\\\\b\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}""#
        )
    }

    // MARK: - Per-param lowering (byte-exact goldens)

    private func objectSchema(_ props: [(String, JSONSchemaValue)], required: [String]) -> JSONSchemaValue {
        var properties: [String: JSONSchemaValue] = [:]
        for (k, v) in props { properties[k] = v }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) })
        ])
    }

    func test_golden_stringEnumParam() {
        let t = tool("set_direction", parameters: objectSchema([
            ("direction", .object([
                "type": .string("string"),
                "enum": .array([.string("north"), .string("south")])
            ]))
        ], required: ["direction"]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [t]))
        let expected = #"""
        root ::= toolcall-0
        args-0-0 ::= ("\"north\"" | "\"south\"")
        args-0 ::= "{" ws "\"direction\"" ws ":" ws args-0-0 ws "}"
        toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"set_direction\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
    }

    func test_golden_typedObjectTwoFields() {
        let t = tool("get_weather", parameters: objectSchema([
            ("city", .object(["type": .string("string")])),
            ("days", .object(["type": .string("integer")]))
        ], required: ["city", "days"]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [t]))
        let expected = #"""
        root ::= toolcall-0
        args-0-0 ::= string
        args-0-1 ::= integer
        args-0 ::= "{" ws "\"city\"" ws ":" ws args-0-0 ws "," ws "\"days\"" ws ":" ws args-0-1 ws "}"
        toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"get_weather\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
    }

    func test_golden_arrayParam() {
        let t = tool("tag", parameters: objectSchema([
            ("tags", .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ]))
        ], required: ["tags"]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [t]))
        let expected = #"""
        root ::= toolcall-0
        args-0-1 ::= string
        args-0-0 ::= "[" ws ( args-0-1 ( ws "," ws args-0-1 )* )? ws "]"
        args-0 ::= "{" ws "\"tags\"" ws ":" ws args-0-0 ws "}"
        toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"tag\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
    }

    func test_golden_genericFallbackForUnsupportedShape() {
        // A schema using `anyOf` is not lowerable → args degrades to `value`,
        // but the tool is NOT dropped from the union (graceful degradation).
        let t = tool("weird", parameters: .object([
            "anyOf": .array([.object(["type": .string("string")])])
        ]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [t]))
        let expected = #"""
        root ::= toolcall-0
        args-0 ::= value
        toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"weird\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
    }

    func test_golden_optionalKeys() {
        // No `required` → both keys optional. Models the closed object as an
        // optional leading member followed by comma-prefixed optionals.
        let t = tool("opt", parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "a": .object(["type": .string("string")]),
                "b": .object(["type": .string("boolean")])
            ])
        ]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [t]))
        let expected = #"""
        root ::= toolcall-0
        args-0-0 ::= string
        args-0-1 ::= ("true" | "false")
        args-0 ::= "{" ws ( "\"a\"" ws ":" ws args-0-0 ( ws "," ws "\"b\"" ws ":" ws args-0-1 )? )? ws "}"
        toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"opt\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
    }

    func test_golden_nullableUnionParam() {
        // `["string","null"]` lowers to `( <string> | "null" )` — the
        // pre-validator no longer rejects this shape.
        let t = tool("nul", parameters: objectSchema([
            ("x", .object(["type": .array([.string("string"), .string("null")])]))
        ], required: ["x"]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [t]))
        let expected = #"""
        root ::= toolcall-0
        args-0-1 ::= string
        args-0-0 ::= (args-0-1 | "null")
        args-0 ::= "{" ws "\"x\"" ws ":" ws args-0-0 ws "}"
        toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"nul\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
    }

    func test_golden_enumValueWithQuoteAndBackslash_escaped() {
        // An enum value containing `"` and `\` must be doubly escaped in the
        // emitted literal, exactly like tool names.
        let t = tool("e", parameters: objectSchema([
            ("k", .object([
                "type": .string("string"),
                "enum": .array([.string("a\"b"), .string("c\\d")])
            ]))
        ], required: ["k"]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [t]))
        let enumLine = grammar
            .split(separator: "\n")
            .first { $0.hasPrefix("args-0-0 ::=") }
            .map(String.init) ?? ""
        XCTAssertEqual(enumLine, #"args-0-0 ::= ("\"a\\\"b\"" | "\"c\\\\d\"")"#)
    }

    // MARK: - Multi-tool discriminated union (byte-exact golden)

    func test_golden_multiToolUnion() {
        let enumTool = tool("set_direction", parameters: objectSchema([
            ("direction", .object([
                "type": .string("string"),
                "enum": .array([.string("north"), .string("south")])
            ]))
        ], required: ["direction"]))
        let objTool = tool("get_weather", parameters: objectSchema([
            ("city", .object(["type": .string("string")])),
            ("days", .object(["type": .string("integer")]))
        ], required: ["city", "days"]))
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [enumTool, objTool]))
        let expected = #"""
        root ::= toolcall-0 | toolcall-1
        args-0-0 ::= ("\"north\"" | "\"south\"")
        args-0 ::= "{" ws "\"direction\"" ws ":" ws args-0-0 ws "}"
        toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"set_direction\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}"
        args-1-0 ::= string
        args-1-1 ::= integer
        args-1 ::= "{" ws "\"city\"" ws ":" ws args-1-0 ws "," ws "\"days\"" ws ":" ws args-1-1 ws "}"
        toolcall-1 ::= "{" ws "\"name\"" ws ":" ws "\"get_weather\"" ws "," ws "\"arguments\"" ws ":" ws args-1 ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
    }

    // MARK: - Bare-object grammar (#1992)

    /// Asserts the grammar is well-formed structurally: every nonterminal it
    /// references is defined by some `name ::=` rule, and there is exactly one
    /// `root`. No live GBNF compiler in CI, so this catches dangling refs.
    private func assertNoDanglingRules(_ grammar: String, file: StaticString = #filePath, line: UInt = #line) {
        var defined = Set<String>()
        var referenced = Set<String>()
        var rootCount = 0
        for rawLine in grammar.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let sep = line.range(of: " ::= ") else { continue }
            let name = String(line[line.startIndex..<sep.lowerBound])
            defined.insert(name)
            if name == "root" { rootCount += 1 }
            // Collect bareword tokens on the RHS that look like rule names
            // (lowercase/hyphen/digit identifiers, not inside a quoted literal
            // and not a char-class). Tokenize on whitespace and structural punct.
            let rhs = String(line[sep.upperBound...])
            var inLiteral = false
            var inClass = false
            var token = ""
            func flush() {
                if !token.isEmpty,
                   token.first!.isLetter,
                   token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                    referenced.insert(token)
                }
                token = ""
            }
            for ch in rhs {
                if inLiteral {
                    if ch == "\"" { inLiteral = false }
                    continue
                }
                if inClass {
                    if ch == "]" { inClass = false }
                    continue
                }
                switch ch {
                case "\"": flush(); inLiteral = true
                case "[": flush(); inClass = true
                case "a"..."z", "A"..."Z", "0"..."9", "-": token.append(ch)
                default: flush()
                }
            }
            flush()
        }
        XCTAssertEqual(rootCount, 1, "grammar must define exactly one root", file: file, line: line)
        let dangling = referenced.subtracting(defined)
        XCTAssertTrue(
            dangling.isEmpty,
            "every referenced nonterminal must be defined; dangling: \(dangling.sorted())",
            file: file, line: line
        )
    }

    func test_objectGrammar_simpleObject_isExactPayloadGrammar() {
        let schema = objectSchema([
            ("city", .object(["type": .string("string")])),
            ("count", .object(["type": .string("integer")]))
        ], required: ["city"])
        let grammar = try! XCTUnwrap(builder.buildObjectGrammar(for: schema))
        let expected = #"""
        root ::= payload-0
        args-0-0 ::= string
        args-0-1 ::= integer
        payload-0 ::= "{" ws "\"city\"" ws ":" ws args-0-0 ( ws "," ws "\"count\"" ws ":" ws args-0-1 )? ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
        // Bare payload: root is payload-first and there is NO tool-call envelope.
        XCTAssertEqual(rootLine(grammar), "root ::= payload-0")
        XCTAssertFalse(grammar.contains("toolcall-"), "no tool-call envelope branches")
        XCTAssertFalse(grammar.contains(#""\"name\"""#), "no envelope \"name\" key")
        XCTAssertFalse(grammar.contains(#""\"arguments\"""#), "no envelope \"arguments\" key")
        assertNoDanglingRules(grammar)
    }

    func test_objectGrammar_stringEnumProperty_lowersToAlternation() {
        let schema = objectSchema([
            ("direction", .object([
                "type": .string("string"),
                "enum": .array([.string("north"), .string("south")])
            ]))
        ], required: ["direction"])
        let grammar = try! XCTUnwrap(builder.buildObjectGrammar(for: schema))
        let enumLine = grammar
            .split(separator: "\n")
            .first { $0.hasPrefix("args-0-0 ::=") }
            .map(String.init) ?? ""
        XCTAssertEqual(enumLine, #"args-0-0 ::= ("\"north\"" | "\"south\"")"#)
        XCTAssertEqual(rootLine(grammar), "root ::= payload-0")
        assertNoDanglingRules(grammar)
    }

    func test_objectGrammar_nestedObjectAndArray_recurse() {
        let schema = objectSchema([
            ("tags", .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")])
            ])),
            ("meta", .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("integer")])
                ]),
                "required": .array([.string("id")])
            ]))
        ], required: ["meta", "tags"])
        let grammar = try! XCTUnwrap(builder.buildObjectGrammar(for: schema))
        XCTAssertEqual(rootLine(grammar), "root ::= payload-0")
        // The nested object's `id` property and the array's item rule both recurse
        // into their own helper rules — assert their constrained primitives appear.
        XCTAssertTrue(grammar.contains(#""\"id\""#), "nested object key is constrained")
        XCTAssertTrue(grammar.contains(#""[" ws"#), "array item list is constrained")
        XCTAssertFalse(grammar.contains("toolcall-"))
        assertNoDanglingRules(grammar)
    }

    func test_objectGrammar_nonObjectSchema_returnsNil() {
        // A bare scalar schema string-value (no `type:"object"`) is not an object
        // schema → nil (nothing object-shaped to root a payload grammar on).
        XCTAssertNil(builder.buildObjectGrammar(for: .string("string")))
        // A dict whose `type` is a top-level scalar is likewise not an object.
        XCTAssertNil(builder.buildObjectGrammar(for: .object(["type": .string("string")])))
    }

    // MARK: - Golden snapshot (fixed 2-tool, empty-params input)

    func test_goldenSnapshot_twoTools() {
        // Empty-object params carry no `type` → args degrades to generic `value`.
        let grammar = try! XCTUnwrap(builder.buildGrammar(for: [tool("alpha"), tool("beta")]))
        let expected = #"""
        root ::= toolcall-0 | toolcall-1
        args-0 ::= value
        toolcall-0 ::= "{" ws "\"name\"" ws ":" ws "\"alpha\"" ws "," ws "\"arguments\"" ws ":" ws args-0 ws "}"
        args-1 ::= value
        toolcall-1 ::= "{" ws "\"name\"" ws ":" ws "\"beta\"" ws "," ws "\"arguments\"" ws ":" ws args-1 ws "}"
        """# + "\n" + genericTail
        XCTAssertEqual(grammar, expected)
    }
}
