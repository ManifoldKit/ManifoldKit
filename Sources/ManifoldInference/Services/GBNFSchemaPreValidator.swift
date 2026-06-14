import Foundation

/// Inspects a ``JSONSchemaValue`` tool-parameter schema and reports which
/// sub-schema shapes ``ToolGrammarBuilder``'s lowerer cannot express, so the
/// builder (or a caller) knows those nodes will fall back to a generic JSON
/// value rather than being constrained.
///
/// ## Why this exists
///
/// `ToolGrammarBuilder` lowers a tool's parameter schema to GBNF so a
/// grammar-capable backend emits well-typed `"arguments"`. The lowerer covers
/// the common shapes (typed objects, string enums, arrays, scalars, nullable
/// unions) and **degrades gracefully** to a generic JSON value for anything it
/// does not model. This type names those un-modeled shapes — it is an advisory,
/// not a gate.
///
/// ## Premise correction (#1859 review)
///
/// An earlier version of this file claimed `anyOf`/`oneOf`/`allOf`/`not` and
/// nullable unions are "inexpressible in the GBNF IR." **That is wrong.** GBNF
/// supports alternation (`|`), and llama.cpp's own `json_schema_to_grammar`
/// lowers combiners and nullable unions to alternations. The real limitation is
/// narrower: *this builder's lowerer does not implement those combiners.* The
/// distinction matters because it sets the correct remedy — extend the lowerer,
/// not "give up because GBNF can't." Nullable unions, in fact, *are* now lowered
/// (`( <T> | "null" )`), so they are no longer flagged.
///
/// ## What is flagged vs handled now
///
/// **Flagged as un-lowerable (the lowerer emits generic `value` for the node):**
/// - `anyOf` / `oneOf` / `allOf` / `not` — combiners the lowerer does not yet
///   implement. (Lowering them is future work; generic JSON is the safe interim
///   behavior — the envelope and tool name stay constrained.)
/// - `$ref`, `patternProperties` — not modeled.
///
/// **No longer flagged (handled or harmlessly ignored):**
/// - **Nullable union** `["string","null"]` — lowered to `( <string> | "null" )`.
/// - **`exclusiveMinimum` / `exclusiveMaximum`** — GBNF cannot enforce arbitrary
///   numeric ranges regardless, so the bound is *ignored* and a generic number
///   is emitted. Ignoring a bound is strictly safer than rejecting the tool, and
///   the previous "type-confusion crash" rationale described a llama.cpp bug
///   that the current pin (see ``cveStatus``) is well past.
///
/// ## CVE-2026-2069 (fixed in the current pin)
///
/// A buffer overflow in `llama_grammar_advance_stack()` was disclosed in
/// CVE-2026-2069 and fixed in llama.cpp build b8774. The vendored xcframework
/// (`mattt/llama.swift` 2.9101.0) wraps build b9101, well past the fix. The
/// audit record below is retained for provenance; this validator's flags encode
/// *lowerer coverage*, not the CVE's crash shapes.
public struct GBNFSchemaPreValidator: Sendable {

    // MARK: - CVE status

    /// Structured audit record for CVE-2026-2069.
    public struct CVEAuditRecord: Sendable {
        /// CVE identifier.
        public let cveID: String
        /// Whether the current vendor pin is confirmed to include the fix.
        public let isFixed: Bool
        /// The first llama.cpp build that includes the fix.
        public let fixedAtBuild: String
        /// The currently vendored llama.cpp build tag.
        public let vendoredBuild: String
        /// Human-readable audit note.
        public let note: String
    }

    /// Pinned audit record for CVE-2026-2069 (buffer overflow in
    /// `llama_grammar_advance_stack()`).
    ///
    /// - `isFixed: true` — `mattt/llama.swift` 2.9101.0 wraps build b9101,
    ///   327 builds past the b8774 fix.
    ///
    /// ### Updating this record when bumping the `llama.swift` pin
    ///
    /// 1. Read the `url:` line from the resolved `mattt/llama.swift`
    ///    `Package.swift` (or the binary's framework metadata) and update
    ///    `vendoredBuild` to the new build tag.
    /// 2. If the new build crosses a future CVE-fix boundary, flip
    ///    `isFixed`/`fixedAtBuild` accordingly.
    public static let cveStatus = CVEAuditRecord(
        cveID: "CVE-2026-2069",
        isFixed: true,
        fixedAtBuild: "b8774",
        vendoredBuild: "b9101",
        note: """
            Buffer overflow in llama_grammar_advance_stack(), fixed in b8774. \
            mattt/llama.swift 2.9101.0 wraps b9101, so the production binary \
            contains the fix. GBNFSchemaPreValidator now reports lowerer \
            coverage gaps (graceful-degradation advisory) rather than gating \
            tools out of grammar use.
            """
    )

    // MARK: - Coverage report

    /// Describes a sub-schema shape the lowerer cannot express, which will
    /// therefore fall back to a generic JSON value.
    ///
    /// Renamed semantics (#1859): this is no longer a hard "validation failure"
    /// that drops a tool — it flags a node that degrades to generic JSON. The
    /// type name and shape are retained for source compatibility with existing
    /// callers and tests; `reason`/`path` keep their meaning.
    public struct ValidationFailure: Sendable, Equatable, Error {
        /// Short developer-facing description of why the node is un-lowerable.
        public let reason: String
        /// JSON-pointer-style path components to the offending key (e.g.
        /// `["properties", "address", "anyOf"]`). Empty when the issue is at
        /// the root of the schema.
        public let path: [String]

        public init(reason: String, path: [String] = []) {
            self.reason = reason
            self.path = path
        }
    }

    public init() {}

    // MARK: - Public entry point

    /// Returns `nil` when every node of `schema` is something the lowerer can
    /// express, or a ``ValidationFailure`` naming the first un-lowerable node
    /// (which will fall back to generic JSON) when one exists.
    ///
    /// This is advisory: `ToolGrammarBuilder` degrades gracefully and never
    /// drops a tool, so a non-`nil` result no longer means "reject." It is
    /// useful for diagnostics — e.g. logging that a tool's arguments could not
    /// be fully constrained.
    ///
    /// - Parameters:
    ///   - schema: The JSON Schema to inspect (typically `ToolDefinition.parameters`).
    ///   - path:   Accumulated path prefix for nested calls — callers should
    ///             use the default empty array.
    public func validate(_ schema: JSONSchemaValue, path: [String] = []) -> ValidationFailure? {
        guard case let .object(dict) = schema else {
            // Non-object schema nodes (bare scalars) carry no un-lowerable shape.
            return nil
        }

        // Combiners the lowerer does not implement → these nodes degrade to
        // generic JSON. (GBNF *can* express alternation; the lowerer just
        // doesn't lower these yet — see the type docs.)
        for combiner in ["anyOf", "oneOf", "allOf", "not"] {
            if dict[combiner] != nil {
                return ValidationFailure(
                    reason: "'\(combiner)' is not implemented by this builder's lowerer; the node falls back to generic JSON.",
                    path: path + [combiner]
                )
            }
        }

        // `$ref` / `patternProperties` are likewise un-modeled and fall back.
        for unmodeled in ["$ref", "patternProperties"] {
            if dict[unmodeled] != nil {
                return ValidationFailure(
                    reason: "'\(unmodeled)' is not implemented by this builder's lowerer; the node falls back to generic JSON.",
                    path: path + [unmodeled]
                )
            }
        }

        // NOTE (#1859): `exclusiveMinimum`/`exclusiveMaximum` are NO LONGER
        // flagged. GBNF cannot enforce arbitrary numeric ranges anyway, so the
        // lowerer emits a generic number and ignores the bound — safer than
        // dropping the tool, and the old "type-confusion crash" rationale
        // described a llama.cpp bug the current pin is past.
        //
        // NOTE (#1859): nullable union `["T","null"]` is NO LONGER flagged —
        // the lowerer expresses it as `( <T> | "null" )`.

        // Recurse into `properties` sub-schemas (sorted for deterministic
        // reporting).
        if let propsValue = dict["properties"], case let .object(properties) = propsValue {
            for (key, subSchema) in properties.sorted(by: { $0.key < $1.key }) {
                if let failure = validate(subSchema, path: path + ["properties", key]) {
                    return failure
                }
            }
        }

        // Recurse into `items` (single sub-schema or tuple-form array).
        if let itemsValue = dict["items"] {
            switch itemsValue {
            case .object:
                if let failure = validate(itemsValue, path: path + ["items"]) {
                    return failure
                }
            case .array(let itemSchemas):
                for (index, itemSchema) in itemSchemas.enumerated() {
                    if let failure = validate(itemSchema, path: path + ["items", String(index)]) {
                        return failure
                    }
                }
            default:
                break
            }
        }

        // Recurse into `additionalProperties` when it is a schema object.
        if let apValue = dict["additionalProperties"], case .object = apValue {
            if let failure = validate(apValue, path: path + ["additionalProperties"]) {
                return failure
            }
        }

        return nil
    }
}
