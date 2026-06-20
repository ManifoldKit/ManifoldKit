import Foundation

/// Derives a GBNF grammar that constrains a grammar-capable local backend to
/// emit a well-formed tool-call envelope as a *discriminated union over the
/// supplied tools*: each branch pins `"name"` to one tool's literal name and
/// pins `"arguments"` to a grammar lowered from *that tool's* JSON-Schema
/// parameters.
///
/// ## Why this exists (#1859)
///
/// Without grammar-constrained decoding, local models drift off the tool-call
/// format and hosts fall back to brittle text-scraping (with silent drops and
/// stray-markup leaks). `GenerationConfig.grammar` was previously a raw,
/// host-supplied string applied independently of `config.tools`; nothing
/// compiled the tool list into a grammar. This builder fills that gap so the
/// queue can force well-formed tool-call emission whenever the backend
/// advertises `supportsGrammarConstrainedSampling`.
///
/// ## Envelope shape (discriminated union)
///
/// ```
/// root        ::= toolcall-0 | toolcall-1 | ...
/// toolcall-N  ::= "{" ws "\"name\"" ws ":" ws "\"<name_N>\"" ws ","
///                     ws "\"arguments\"" ws ":" ws args-N ws "}"
/// args-N      ::= <lowered from tool N's `parameters` schema>
/// ```
///
/// Rule names use hyphens, never underscores: llama.cpp's GBNF parser
/// (`is_word_char`) accepts only `[a-zA-Z0-9-]` in a rule name and stops at
/// `_`, so `args_0` would be misparsed as `args` followed by a syntax error.
///
/// Pinning `"name"` *per branch* (rather than to a shared `name`-enum followed
/// by one shared `arguments`) is what lets each tool's `arguments` be
/// constrained to its own parameter schema. A single tool collapses to one
/// branch; `root` is still emitted as `root ::= toolcall-0` for uniformity.
///
/// ## Lowering: supported shapes vs graceful fallback
///
/// The lowerer (``lower(_:into:ruleName:)``) handles the common JSON-Schema
/// shapes used by real tool definitions:
///
/// - **object** with `properties` + `required`: required keys are emitted in
///   declared order (sorted for determinism); optional keys are emitted as
///   `( "," ws "\"key\"" ws ":" ws <val> )?` *after* the required block.
///   `additionalProperties` is **not** modeled — the object is closed to the
///   declared keys. (A tool that needs free-form extra keys should declare them
///   or accept the closed shape.)
/// - **string**: generic JSON string; **string enum** lowers to an alternation
///   of quoted literals (`"\"north\"" | "\"south\""`).
/// - **integer**: signed integer rule. **number**: signed decimal with optional
///   fraction/exponent.
/// - **boolean**: `"true" | "false"`.
/// - **array** with `items` (single sub-schema): homogeneous list of the lowered
///   item rule.
/// - **nullable union** `["string","null"]` (and any `["T","null"]`): lowers to
///   `( <T> | "null" )`. (The pre-validator no longer rejects this — see
///   ``GBNFSchemaPreValidator``.)
/// - nested objects / arrays recurse.
///
/// **Graceful degradation.** Any sub-schema shape the lowerer does not model
/// (combiners `anyOf`/`oneOf`/`allOf`/`not`, `$ref`, `pattern`, `format`,
/// `patternProperties`, tuple-form `items`, an unrecognised `type`, …) lowers
/// to the shared generic JSON `value` rule for *that sub-schema only*. The rest
/// of the tool is still constrained. A whole-tool schema that is itself
/// unloweliable degrades its `args-N` to `value`, never dropping the tool from
/// the union. This is strictly better than rejecting the tool: the envelope and
/// tool name stay constrained even when the arguments can't be.
///
/// The shared generic rules (`value`/`object`/`array`/`string`/`number` …) are
/// always emitted so the fallback has something to reference.
///
/// ## Pre-validator's role (reconciled)
///
/// ``GBNFSchemaPreValidator`` no longer *rejects* tools. Its `validate` method
/// is retained as a public **pre-flight advisory**: callers that want to know,
/// ahead of time, whether a schema will lower fully or fall back to generic JSON
/// can ask. This builder does not consult it on the build path — graceful
/// degradation subsumes rejection — but exposes it as a diagnostic via
/// ``loweringReport(for:)`` so the advisory has an in-repo consumer. See that
/// type's docs for the corrected premise (GBNF *can* express alternation; the
/// limitation is this lowerer's coverage, not the IR).
///
/// ## GBNF validity
///
/// CI cannot compile GBNF, so the emitted grammar is hand-verified against
/// llama.cpp's `grammars/README.md`: a single `root`; every nonterminal
/// defined; no undefined references; no left-recursion; no nullable members
/// that could form a zero-width loop; correctly escaped quoted literals; `ws`
/// between structural tokens. Byte-exact golden tests pin the output.
public struct ToolGrammarBuilder: Sendable {

    public init(preValidator: GBNFSchemaPreValidator = GBNFSchemaPreValidator()) {
        // The pre-validator is no longer consulted on the build path (graceful
        // degradation replaced rejection). The parameter is retained for source
        // compatibility with existing call sites.
        _ = preValidator
    }

    /// Selects how strictly the emitted grammar constrains the first sampled
    /// token, mirroring `GenerationConfig.toolChoice` (#1961).
    ///
    /// The default tool-call-only union forces a structured call: every branch
    /// begins with a literal `{`, so under `toolChoice == .auto` the grammar
    /// masks every non-`{` first token, the decoder collapses onto EOS, and
    /// generation stops at zero tokens (manifold-llama#55: gemma-4 produced 0
    /// completion tokens on 88/88 turns). That forced-call behaviour is correct
    /// for `.required` / `.tool(name:)` but wrong for `.auto`, which must let the
    /// model emit prose *or* a tool call. This mode lets the queue pick the right
    /// shape per request rather than blanket-relaxing the single variant (which
    /// would silently regress the forced-call guarantee for `.required`).
    public enum Mode: Sendable, Equatable {
        /// Tool-call union plus a non-empty prose escape: the first token may be
        /// prose (never forced to EOS), and a leading `{` still enters the
        /// fully-constrained tool-call union. For `toolChoice == .auto`.
        case permissive

        /// Tool-call-only union (no prose escape). When `only` is a tool name,
        /// the union is limited to that single tool's branch (`.tool(name:)`);
        /// when `nil`, the full union over all tools is emitted (`.required`).
        /// A named tool absent from the supplied list falls back to the full
        /// union — never an empty grammar, which would match nothing.
        case strict(only: String?)
    }

    /// Builds a GBNF grammar string constraining output to a tool-call
    /// discriminated union over the supplied tools, or `nil` when `tools` is
    /// empty (no envelope to constrain — caller should fall back to
    /// unconstrained sampling).
    ///
    /// Overload preserving the original `buildGrammar(for:)` public symbol:
    /// builds the historical strict, forced-call union (`.strict(only: nil)`).
    /// Kept as a distinct method rather than a defaulted `mode:` parameter so the
    /// API digester does not see the pre-#1961 signature as renamed (a defaulted
    /// param is source-compatible but still trips `diagnose-api-breaking-changes`).
    public func buildGrammar(for tools: [ToolDefinition]) -> String? {
        buildGrammar(for: tools, mode: .strict(only: nil))
    }

    /// Builds the grammar in an explicit ``Mode``: callers select `.permissive`
    /// (for `toolChoice == .auto`) or `.strict(only:)` (for `.tool(name:)`) /
    /// `.strict(only: nil)` (for `.required`). See ``Mode`` for the rationale
    /// (#1961).
    ///
    /// - Parameters:
    ///   - tools: the tool definitions for this request.
    ///   - mode: how strictly to constrain the first token (see ``Mode``).
    public func buildGrammar(
        for tools: [ToolDefinition],
        mode: Mode
    ) -> String? {
        guard !tools.isEmpty else { return nil }

        // De-duplicate names, preserving first-seen order, so the union has no
        // redundant branches and output is deterministic.
        var seen = Set<String>()
        var uniqueTools: [ToolDefinition] = []
        for tool in tools where seen.insert(tool.name).inserted {
            uniqueTools.append(tool)
        }

        // `.strict(only:)` limits the union to the named tool's branch — but
        // only when that name is actually present. An absent name falls back to
        // the full union rather than an empty (match-nothing) grammar.
        if case let .strict(only?) = mode,
           uniqueTools.contains(where: { $0.name == only }) {
            uniqueTools = uniqueTools.filter { $0.name == only }
        }

        // Accumulates the per-tool lowered rules in deterministic emission order.
        var emittedOrder: [String] = []
        var rules: [String: String] = [:]
        func emit(_ name: String, _ rhs: String) {
            if rules[name] == nil { emittedOrder.append(name) }
            rules[name] = rhs
        }

        var branchNames: [String] = []
        for (index, tool) in uniqueTools.enumerated() {
            let argsRule = "args-\(index)"
            var ctx = LoweringContext(toolIndex: index, suffix: 0)
            lower(tool.parameters, into: &ctx, ruleName: argsRule, emit: emit)

            let literalName = "\"\\\"\(Self.escapeForGBNFLiteral(tool.name))\\\"\""
            let branch = "toolcall-\(index)"
            branchNames.append(branch)
            emit(
                branch,
                "\"{\" ws \"\\\"name\\\"\" ws \":\" ws \(literalName) ws \",\" ws "
                    + "\"\\\"arguments\\\"\" ws \":\" ws \(argsRule) ws \"}\""
            )
        }

        // root is the alternation of all tool branches (one branch for a single
        // tool). Emitting `root` first keeps it as the grammar's entry point.
        //
        // In `.permissive` mode (toolChoice == .auto) the root gains a non-empty
        // `prose` alternative so the first sampled token can be free prose. The
        // alternation stays unambiguous at the first byte: every tool branch
        // begins with a literal `{`, and `prose-head` is `[^{]`, so a leading `{`
        // enters the constrained tool-call union while anything else is prose.
        // `prose` is non-empty (it has a mandatory head byte), so the root never
        // matches empty — the first token can never collapse onto EOS (#1961).
        var branchRHS = branchNames
        var proseLines: [String] = []
        if case .permissive = mode {
            branchRHS.append("prose")
            proseLines = [
                "prose ::= prose-head prose-tail*",
                "prose-head ::= [^{]",
                #"prose-tail ::= [^\x00]"#,
            ]
        }
        let rootRHS = branchRHS.joined(separator: " | ")

        var lines: [String] = ["root ::= \(rootRHS)"]
        for name in emittedOrder {
            lines.append("\(name) ::= \(rules[name]!)")
        }
        lines.append(contentsOf: proseLines)
        // Shared generic JSON value rule set — the fallback target plus the
        // primitives every lowered rule references (string, number, …).
        lines.append(contentsOf: Self.genericRuleLines)

        return lines.joined(separator: "\n")
    }

    /// Builds a GBNF grammar string whose `root` constrains output to a single
    /// JSON value matching `schema` (no tool-call envelope), or `nil` when the
    /// schema carries no structural information to constrain (a bare scalar /
    /// unmodeled node lowers to the generic JSON `value`, which is no
    /// constraint at all — the caller should fall back rather than ship a
    /// grammar that accepts anything).
    ///
    /// Reuses the same recursive lowerer as ``buildGrammar(for:)`` so a typed
    /// structured-output request gets exactly the constraint surface a tool's
    /// `arguments` would. The first production caller is
    /// `InferenceService.respond(_:to:)` (#1915).
    public func buildSchemaGrammar(for schema: JSONSchemaValue) -> String? {
        var emittedOrder: [String] = []
        var rules: [String: String] = [:]
        func emit(_ name: String, _ rhs: String) {
            if rules[name] == nil { emittedOrder.append(name) }
            rules[name] = rhs
        }

        // toolIndex 0 keeps helper rule names stable/deterministic.
        var ctx = LoweringContext(toolIndex: 0, suffix: 0)
        lower(schema, into: &ctx, ruleName: "root", emit: emit)

        // If `root` lowered straight to the generic `value` rule the schema
        // constrained nothing — signal "no grammar" so the caller can pick a
        // weaker-but-honest strategy instead of a vacuous grammar.
        if rules["root"] == "value" { return nil }

        var lines: [String] = []
        for name in emittedOrder {
            lines.append("\(name) ::= \(rules[name]!)")
        }
        lines.append(contentsOf: Self.genericRuleLines)
        return lines.joined(separator: "\n")
    }

    // MARK: - Diagnostics (pre-flight advisory)

    /// A non-binding prediction of how fully a tool's parameter schema will be
    /// constrained by the grammar this builder emits.
    public struct LoweringReport: Sendable, Equatable {
        /// The tool this report describes.
        public let toolName: String
        /// `true` when every node of the parameter schema lowers to a constrained
        /// GBNF rule; `false` when at least one node degrades to a generic JSON
        /// `value` (the tool's envelope and name are still constrained either way).
        public let lowersFully: Bool
        /// When `lowersFully` is `false`, the first node that degrades — its
        /// developer-facing reason and JSON-pointer-style path. `nil` otherwise.
        public let firstDegradation: GBNFSchemaPreValidator.ValidationFailure?
    }

    /// Predicts, per tool, whether its arguments will be fully grammar-constrained
    /// or degrade somewhere to a generic JSON value, using ``GBNFSchemaPreValidator``.
    ///
    /// This is a pre-flight diagnostic — it does **not** affect ``buildGrammar(for:)``,
    /// which never drops a tool. Use it to warn when a tool you expect to be
    /// constrained will in fact only have its envelope constrained.
    public func loweringReport(for tools: [ToolDefinition]) -> [LoweringReport] {
        let validator = GBNFSchemaPreValidator()
        return tools.map { tool in
            let failure = validator.validate(tool.parameters)
            return LoweringReport(
                toolName: tool.name,
                lowersFully: failure == nil,
                firstDegradation: failure
            )
        }
    }

    // MARK: - Lowering

    /// Mutable state threaded through the recursive lowerer so generated helper
    /// rules get unique, deterministic names (`args-<tool>-<n>`).
    private struct LoweringContext {
        let toolIndex: Int
        var suffix: Int

        /// Returns a fresh unique rule name and advances the counter.
        mutating func freshRuleName() -> String {
            defer { suffix += 1 }
            // llama.cpp's GBNF parser (`is_word_char`) accepts only
            // `[a-zA-Z0-9-]` in rule names — NOT underscore. Use hyphens.
            return "args-\(toolIndex)-\(suffix)"
        }
    }

    /// Lowers `schema` into a GBNF rule named `ruleName`, emitting that rule and
    /// any helper rules it needs via `emit`. Unsupported shapes degrade to the
    /// shared generic `value` rule.
    private func lower(
        _ schema: JSONSchemaValue,
        into ctx: inout LoweringContext,
        ruleName: String,
        emit: (String, String) -> Void
    ) {
        guard case let .object(dict) = schema else {
            // A non-object schema node (bare scalar) carries no structural
            // information we can constrain — accept any JSON value.
            emit(ruleName, "value")
            return
        }

        // Combiners and other unmodeled keywords → generic value for this node.
        // (Detect them explicitly so a schema that *also* has a `type` doesn't
        // get partially — and wrongly — constrained.)
        for unmodeled in ["anyOf", "oneOf", "allOf", "not", "$ref", "patternProperties"] {
            if dict[unmodeled] != nil {
                emit(ruleName, "value")
                return
            }
        }

        let typeValue = dict["type"]

        // Nullable / multi-type union: `type` as an array.
        if case let .array(typeArr)? = typeValue {
            lowerUnion(typeArr, dict: dict, into: &ctx, ruleName: ruleName, emit: emit)
            return
        }

        guard case let .string(typeName)? = typeValue else {
            // No usable scalar `type` — accept any JSON value.
            emit(ruleName, "value")
            return
        }

        switch typeName {
        case "object":
            lowerObject(dict, into: &ctx, ruleName: ruleName, emit: emit)
        case "array":
            lowerArray(dict, into: &ctx, ruleName: ruleName, emit: emit)
        case "string":
            lowerString(dict, ruleName: ruleName, emit: emit)
        case "integer":
            emit(ruleName, "integer")
        case "number":
            emit(ruleName, "number")
        case "boolean":
            emit(ruleName, "(\"true\" | \"false\")")
        case "null":
            emit(ruleName, "\"null\"")
        default:
            emit(ruleName, "value")
        }
    }

    /// Lowers a `"type": [...]` union. The common case is `["T", "null"]`, which
    /// becomes `( <T> | "null" )`. Any unmodeled member degrades the whole union
    /// to generic `value`.
    private func lowerUnion(
        _ typeArr: [JSONSchemaValue],
        dict: [String: JSONSchemaValue],
        into ctx: inout LoweringContext,
        ruleName: String,
        emit: (String, String) -> Void
    ) {
        var alternatives: [String] = []
        for member in typeArr {
            guard case let .string(name) = member else {
                emit(ruleName, "value")
                return
            }
            if name == "null" {
                alternatives.append("\"null\"")
                continue
            }
            // Lower the non-null member by reusing the scalar lowerer with the
            // surrounding dict (so an enum/items alongside the union still
            // applies). Give it a helper rule name and reference it.
            let helper = ctx.freshRuleName()
            var memberDict = dict
            memberDict["type"] = .string(name)
            lower(.object(memberDict), into: &ctx, ruleName: helper, emit: emit)
            alternatives.append(helper)
        }
        guard !alternatives.isEmpty else {
            emit(ruleName, "value")
            return
        }
        emit(ruleName, "(\(alternatives.joined(separator: " | ")))")
    }

    /// Lowers an `object` schema with `properties` + `required`.
    ///
    /// Required keys (sorted for determinism) are emitted in order; optional
    /// keys follow, each wrapped in an optional group. An object with no
    /// declared `properties` accepts the generic JSON object.
    private func lowerObject(
        _ dict: [String: JSONSchemaValue],
        into ctx: inout LoweringContext,
        ruleName: String,
        emit: (String, String) -> Void
    ) {
        guard case let .object(properties)? = dict["properties"], !properties.isEmpty else {
            // No property constraints — any JSON object.
            emit(ruleName, "object")
            return
        }

        var requiredKeys = Set<String>()
        if case let .array(req)? = dict["required"] {
            for item in req {
                if case let .string(key) = item { requiredKeys.insert(key) }
            }
        }

        // Deterministic order: sort all keys, required ones first.
        let sortedKeys = properties.keys.sorted()
        let required = sortedKeys.filter { requiredKeys.contains($0) }
        let optional = sortedKeys.filter { !requiredKeys.contains($0) }

        // Lower each property's value to its own helper rule.
        func valueRule(forKey key: String) -> String {
            let helper = ctx.freshRuleName()
            lower(properties[key]!, into: &ctx, ruleName: helper, emit: emit)
            return helper
        }

        // Emit value helpers first (deterministic order) so member fragments can
        // reference them.
        var keyToRule: [String: String] = [:]
        for key in required + optional {
            keyToRule[key] = valueRule(forKey: key)
        }

        func member(_ key: String) -> String {
            let lit = "\"\\\"\(Self.escapeForGBNFLiteral(key))\\\"\""
            return "\(lit) ws \":\" ws \(keyToRule[key]!)"
        }

        var parts: [String] = ["\"{\" ws"]

        // Required members joined by commas.
        let requiredMembers = required.map(member)
        for (i, m) in requiredMembers.enumerated() {
            if i == 0 {
                parts.append(m)
            } else {
                parts.append("ws \",\" ws \(m)")
            }
        }

        // Optional members. If there are no required keys, the *first* optional
        // key carries no leading comma but must itself be optional, and
        // subsequent optionals each need the leading comma inside their own
        // optional group. To keep this regular (and avoid a nullable-with-
        // trailing-comma hazard), when there are no required keys we model the
        // object as: an optional leading member, then comma-prefixed optionals.
        if required.isEmpty {
            if let first = optional.first {
                parts.append("( \(member(first))")
                for key in optional.dropFirst() {
                    parts.append("( ws \",\" ws \(member(key)) )?")
                }
                parts.append(")?")
            }
        } else {
            for key in optional {
                parts.append("( ws \",\" ws \(member(key)) )?")
            }
        }

        parts.append("ws \"}\"")
        emit(ruleName, parts.joined(separator: " "))
    }

    /// Lowers an `array` schema with a single-sub-schema `items`.
    private func lowerArray(
        _ dict: [String: JSONSchemaValue],
        into ctx: inout LoweringContext,
        ruleName: String,
        emit: (String, String) -> Void
    ) {
        // Only single-sub-schema `items` is modeled; tuple-form (array of
        // schemas) or missing `items` degrades to the generic array.
        guard case .object(let items)? = dict["items"] else {
            emit(ruleName, "array")
            return
        }
        let itemRule = ctx.freshRuleName()
        lower(.object(items), into: &ctx, ruleName: itemRule, emit: emit)
        emit(
            ruleName,
            "\"[\" ws ( \(itemRule) ( ws \",\" ws \(itemRule) )* )? ws \"]\""
        )
    }

    /// Lowers a `string` schema. A `string` with an `enum` of string literals
    /// lowers to an alternation of quoted literals; otherwise the generic JSON
    /// `string` rule.
    private func lowerString(
        _ dict: [String: JSONSchemaValue],
        ruleName: String,
        emit: (String, String) -> Void
    ) {
        if case let .array(cases)? = dict["enum"] {
            var literals: [String] = []
            for c in cases {
                guard case let .string(s) = c else {
                    // Non-string enum member — not a clean string enum; fall back.
                    literals = []
                    break
                }
                literals.append("\"\\\"\(Self.escapeForGBNFLiteral(s))\\\"\"")
            }
            if !literals.isEmpty {
                emit(ruleName, "(\(literals.joined(separator: " | ")))")
                return
            }
        }
        emit(ruleName, "string")
    }

    // MARK: - Shared generic rules

    /// The shared, self-contained JSON value rule set. Always appended so the
    /// fallback `value` reference and the primitive rules (`string`, `number`,
    /// `integer`, `object`, `array`) every lowered rule may reference are
    /// defined exactly once.
    static let genericRuleLines: [String] = [
        #"object ::= "{" ws ( member ( ws "," ws member )* )? ws "}""#,
        #"member ::= string ws ":" ws value"#,
        #"array ::= "[" ws ( value ( ws "," ws value )* )? ws "]""#,
        #"value ::= object | array | string | number | "true" | "false" | "null""#,
        #"string ::= "\"" char* "\"""#,
        #"char ::= [^"\\] | "\\" escape"#,
        #"escape ::= ["\\/bfnrt] | "u" hex hex hex hex"#,
        "hex ::= [0-9a-fA-F]",
        #"number ::= "-"? int frac? exp?"#,
        "integer ::= \"-\"? int",
        "int ::= \"0\" | [1-9] [0-9]*",
        #"frac ::= "." [0-9]+"#,
        "exp ::= [eE] [+-]? [0-9]+",
        #"ws ::= [ \t\n]*"#,
    ]

    // MARK: - Escaping

    /// Escapes a name for embedding inside a GBNF double-quoted string literal
    /// that itself represents a JSON string literal.
    ///
    /// The emitted token is `"\"<name>\""` — a GBNF literal whose *content* is
    /// `"<name>"` (the JSON-quoted name). Two layers need escaping:
    ///
    /// 1. Characters special inside the JSON string the model emits (`"` and
    ///    `\`) are backslash-escaped so the model emits them in escaped form.
    /// 2. The resulting bytes must survive being written into a GBNF
    ///    double-quoted literal (which also uses backslash escapes).
    ///
    /// Each `"` becomes `\\\"` and each `\` becomes `\\\\`. Control characters
    /// are emitted as JSON `\uXXXX`, GBNF-escaped. Used for both tool names and
    /// enum/property-key literals.
    static func escapeForGBNFLiteral(_ name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\\\\\""
            case "\\":
                out += "\\\\\\\\"
            case "\n":
                out += "\\\\n"
            case "\r":
                out += "\\\\r"
            case "\t":
                out += "\\\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
