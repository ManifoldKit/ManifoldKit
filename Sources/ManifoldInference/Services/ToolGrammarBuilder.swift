import Foundation

/// Derives a GBNF grammar that constrains a grammar-capable local backend to
/// emit a well-formed tool-call envelope: a JSON object whose `"name"` field is
/// pinned to the *enum of the provided tool names* and whose `"arguments"`
/// field is a generic well-formed JSON object.
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
/// ## Scope: implemented vs deferred
///
/// **Implemented:** the `"name"` field is constrained to the exact set of
/// supplied tool names (alternation of string literals), and the overall shape
/// is forced to `{ "name": <enum>, "arguments": <json-object> }`. Tool names
/// are escaped for safe embedding as GBNF string literals.
///
/// **Deferred:** per-tool *parameter-schema* lowering — i.e. making
/// `"arguments"` match each tool's exact JSON Schema (typed fields, required
/// keys, enums on values). That is the hard, correctness-sensitive part and is
/// intentionally out of scope for this PR. `"arguments"` is constrained to a
/// generic well-formed JSON object instead. The name-enum constraint alone is
/// the core value of #1859 (guaranteed-parseable envelope + correct tool name).
///
/// ## Pre-validator gate
///
/// Each tool's `parameters` schema is run through ``GBNFSchemaPreValidator``
/// before the tool is included. A tool whose schema the pre-validator rejects
/// is dropped from the name enum (it cannot be safely grammar-constrained under
/// the current conservative policy).
///
/// NOTE: the pre-validator's rejection set is *conservative* and its premise is
/// partly inaccurate — it claims `anyOf`/`oneOf`/`allOf` and nullable unions are
/// inexpressible in GBNF, but GBNF supports alternation (`|`) and llama.cpp's
/// own `json_schema_to_grammar` lowers these. Because this builder only emits a
/// generic JSON object for `"arguments"` (it does not lower the param schema at
/// all), the pre-validator is used here purely as a defensive safety gate: it
/// keeps known-crashy schema shapes out of any future per-tool lowering and
/// documents intent. Fixing the pre-validator's premise is a separate concern
/// (tracks the "dead validator" note in #1859's review) and is NOT done here.
public struct ToolGrammarBuilder: Sendable {

    private let preValidator: GBNFSchemaPreValidator

    public init(preValidator: GBNFSchemaPreValidator = GBNFSchemaPreValidator()) {
        self.preValidator = preValidator
    }

    /// Builds a GBNF grammar string constraining output to a tool-call envelope
    /// over the supplied tools, or `nil` when no grammar can be derived.
    ///
    /// Returns `nil` when `tools` is empty or when every tool's parameter schema
    /// is rejected by the pre-validator — in both cases there is no usable name
    /// enum, so the caller should fall back to unconstrained sampling.
    ///
    /// - Parameter tools: the tool definitions for this request.
    public func buildGrammar(for tools: [ToolDefinition]) -> String? {
        guard !tools.isEmpty else { return nil }

        // Drop tools whose parameter schema the (conservative) pre-validator
        // rejects. De-duplicate names so the enum has no redundant alternatives
        // and preserve first-seen order for deterministic output.
        var seen = Set<String>()
        var acceptedNames: [String] = []
        for tool in tools {
            if preValidator.validate(tool.parameters) != nil { continue }
            if seen.insert(tool.name).inserted {
                acceptedNames.append(tool.name)
            }
        }

        guard !acceptedNames.isEmpty else { return nil }

        let nameAlternation = acceptedNames
            .map { "\"\\\"\(Self.escapeForGBNFLiteral($0))\\\"\"" }
            .joined(separator: " | ")

        // The grammar forces:
        //   root      ::= { "name": <one of the tool names>, "arguments": <object> }
        //   value/object/array/string/number/etc. — a self-contained JSON subset.
        //
        // Whitespace ("ws") is permitted between tokens so the model isn't forced
        // into a single canonical spacing. The JSON value rules are a standard,
        // self-contained GBNF JSON grammar (no external rule references).
        return """
        root      ::= "{" ws "\\"name\\"" ws ":" ws toolname ws "," ws "\\"arguments\\"" ws ":" ws object ws "}"
        toolname  ::= \(nameAlternation)
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
    }

    // MARK: - Escaping

    /// Escapes a tool name for embedding inside a GBNF double-quoted string
    /// literal that itself represents a JSON string literal.
    ///
    /// The emitted token in the grammar is `"\"<name>\""` — a GBNF literal whose
    /// *content* is `"<name>"` (the JSON-quoted name). Two layers therefore need
    /// escaping:
    ///
    /// 1. Characters that are special inside the JSON string the model emits
    ///    (`"` and `\`) must be backslash-escaped so the model is constrained to
    ///    emit them in escaped form (a literal `"` inside the name would close
    ///    the JSON string).
    /// 2. The resulting bytes must survive being written into a GBNF
    ///    double-quoted literal. GBNF literals use backslash escapes too, so a
    ///    backslash and a double-quote each need one more backslash.
    ///
    /// Concretely each `"` in the name becomes `\\\"` (escaped JSON quote, then
    /// GBNF-escaped) and each `\` becomes `\\\\`. Control characters (newline,
    /// tab, etc.) are emitted as JSON `\uXXXX` escapes, themselves GBNF-escaped.
    /// Tool names are normally `[a-zA-Z0-9_-]`, so this defends the edge cases.
    static func escapeForGBNFLiteral(_ name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\"":
                // JSON-escape (\") then GBNF-escape both chars: \\\"
                out += "\\\\\\\""
            case "\\":
                // JSON-escape (\\) then GBNF-escape both: \\\\\\\\
                out += "\\\\\\\\"
            case "\n":
                out += "\\\\n"
            case "\r":
                out += "\\\\r"
            case "\t":
                out += "\\\\t"
            default:
                if scalar.value < 0x20 {
                    // Other control chars → JSON \u escape, GBNF-escaped backslash.
                    out += String(format: "\\\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
