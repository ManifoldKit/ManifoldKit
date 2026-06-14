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
///   is emitted. Ignoring a bound is strictly safer than rejecting the tool.
///
/// ## Provenance note: CVE-2026-2069 (see ``cveStatus``)
///
/// An earlier version of this file justified the validator's rules as a defence
/// against CVE-2026-2069 and asserted the bug was "fixed in the current pin"
/// (llama.cpp build `b8774`, vendored via `mattt/llama.swift` 2.9101.0 / build
/// `b9101`). Those claims do not hold up:
///
/// 1. **This package does not vendor llama.cpp at all.** Since v0.48 (PR C2) the
///    llama.cpp family lives in the companion `manifold-llama` repo — there is no
///    `mattt/llama.swift` / `llama.cpp` dependency in this `Package.swift` /
///    `Package.resolved`. So no build is "pinned" here to be past or before a fix.
/// 2. **The build tags were unverifiable.** `b8774` / `b9101` / `2.9101.0` do not
///    map to anything in this repo, and (as of 2026-06-14) the public fix PR for
///    CVE-2026-2069 (`ggml-org/llama.cpp#18993`) is **not merged** — so there is
///    no released llama.cpp build containing the fix. The CVE id and the
///    `llama_grammar_advance_stack` function name are real (a *stack* overflow via
///    nested GBNF repetition, e.g. `("a"* )*`), but the "fixed at b8774" framing
///    was fabricated precision.
///
/// The structured record below is **retained but corrected**: its specifics are
/// now honest (`isFixed: false`, no fabricated build tags). The real and durable
/// justification for this validator's rules is **lowerer coverage** — naming the
/// sub-schema shapes ``ToolGrammarBuilder`` cannot constrain — not the CVE. The
/// CVE link is kept only as a provenance breadcrumb for anyone wiring grammar
/// input to a companion llama.cpp build, which must guard the crash itself.
public struct GBNFSchemaPreValidator: Sendable {

    // MARK: - CVE provenance

    /// Honest provenance record for CVE-2026-2069 as it relates to this package.
    ///
    /// Kept deliberately small and *unverified* in its claims: this package does
    /// not vendor llama.cpp (the family moved to `manifold-llama` in v0.48), so it
    /// cannot assert a pin is past any fix. See the type-level docs for the full
    /// account of why the previous "fixed at b8774" record was dropped.
    public struct CVEAuditRecord: Sendable {
        /// CVE identifier (real; a stack overflow in `llama_grammar_advance_stack`
        /// via nested GBNF repetition).
        public let cveID: String
        /// Whether *this package* can confirm the fix is present. Always `false`:
        /// this package vendors no llama.cpp build, and as of the audit date the
        /// upstream fix PR was unmerged, so there is no fixed build to point at.
        public let isFixed: Bool
        /// Date this provenance was last confirmed against public records
        /// (ISO-8601). Re-confirm on any future llama.cpp wiring.
        public let auditedOn: String
        /// Human-readable audit note — honest about what could and could not be
        /// verified.
        public let note: String
    }

    /// Provenance record for CVE-2026-2069.
    ///
    /// This validator's rules are retained on **lowerer-coverage** grounds (which
    /// sub-schemas lower fully to GBNF vs degrade to a generic JSON value), not on
    /// CVE grounds. The CVE id is real but its build-tag specifics could not be
    /// verified against public llama.cpp records, and this package vendors no
    /// llama.cpp build to gate. Do not re-introduce fabricated `fixedAtBuild` /
    /// `vendoredBuild` fields — derive any such claim from a real, resolved pin.
    public static let cveStatus = CVEAuditRecord(
        cveID: "CVE-2026-2069",
        isFixed: false,
        auditedOn: "2026-06-14",
        note: """
            Real CVE: stack overflow in llama_grammar_advance_stack via nested \
            GBNF repetition (ggml-org/llama.cpp#18988; fix PR #18993 was unmerged \
            as of 2026-06-14, so no released build contains it). This package does \
            NOT vendor llama.cpp (the family moved to the companion manifold-llama \
            repo in v0.48), so it cannot assert a pin is past any fix — the earlier \
            record's specific fix-build / vendored-build tags were unverifiable and \
            have been removed (see the type-level docs for the dropped values). \
            GBNFSchemaPreValidator's rules are justified by lowerer coverage \
            (graceful-degradation advisory), not by this CVE.
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

    /// Predicts whether `schema` will lower **fully** to a GBNF grammar or
    /// **degrade** somewhere to a generic JSON value, returning `nil` for the
    /// former and the first un-lowerable node for the latter.
    ///
    /// ## This is advisory, NOT a build-path gate
    ///
    /// `ToolGrammarBuilder` degrades gracefully and **never drops a tool**, so a
    /// non-`nil` result does *not* mean "the tool is rejected" — it means "this
    /// node's arguments will not be grammar-constrained; the model may emit any
    /// JSON there." Nothing on the build path calls this method (verified: zero
    /// call sites in `Sources/`). It exists as a public pre-flight so a caller
    /// can answer *"will my tool actually be constrained, or only its
    /// envelope?"* before relying on grammar constraint — e.g. to log a warning,
    /// pick a stricter tool schema, or surface a UI hint.
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
