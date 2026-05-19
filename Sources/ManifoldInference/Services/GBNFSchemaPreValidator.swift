import Foundation

/// Pre-validates a ``JSONSchemaValue`` tool-parameter schema before
/// handing it to the GBNF compiler in llama.cpp.
///
/// ## Why this exists
///
/// llama.cpp's GBNF compiler (`llama_sampler_init_grammar`) can SIGSEGV on
/// certain JSON Schema constructs:
///
/// - `anyOf` / `oneOf` / `allOf` / `not` — combiners the GBNF IR cannot
///   express as a regular grammar.
/// - Nullable union types — `"type": ["string", "null"]` — produce an
///   unbounded alternation that causes stack overflow in the GBNF compiler.
/// - `exclusiveMinimum` / `exclusiveMaximum` — numeric bounds expressed as
///   integers in Draft 2020-12 trigger a type-confusion path in the GBNF
///   numeric rule builder.
///
/// ## CVE-2026-2069 (fixed in the current pin)
///
/// A buffer overflow in `llama_grammar_advance_stack()` was disclosed in
/// CVE-2026-2069 and fixed in llama.cpp build b8774. The vendored
/// xcframework (`mattt/llama.swift` 2.9101.0) wraps build b9101, well past
/// the fix.
///
/// The validation rules below are retained because they reject schema
/// constructs that exceed GBNF's expressiveness independent of the CVE:
/// `anyOf`/`oneOf`/`allOf`/`not` have no representation in the GBNF IR,
/// and nullable union types produce unbounded alternation. Removing them
/// would surface a different class of llama.cpp crashes (parse failure
/// or runtime grammar-stack errors) rather than make grammar use safer.
/// See ``GBNFSchemaPreValidator/cveStatus`` for the pinned audit record.
public struct GBNFSchemaPreValidator: Sendable {

    // MARK: - CVE status

    /// Structured audit record for CVE-2026-2069.
    ///
    /// When `isFixed` is `true`, the vendored llama.cpp build has been
    /// confirmed post-patch and callers may reduce the strictness of schema
    /// rules if desired. Until then, treat `isFixed == false` as "always run
    /// the full rule set."
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
    /// 3. The validation rules in `validate(_:path:)` are kept regardless of
    ///    CVE status — they encode GBNF expressiveness limits, not just the
    ///    overflow's PoC shapes.
    public static let cveStatus = CVEAuditRecord(
        cveID: "CVE-2026-2069",
        isFixed: true,
        fixedAtBuild: "b8774",
        vendoredBuild: "b9101",
        note: """
            Buffer overflow in llama_grammar_advance_stack(), fixed in b8774. \
            mattt/llama.swift 2.9101.0 wraps b9101, so the production binary \
            contains the fix. GBNFSchemaPreValidator remains mandatory for \
            tool-schema grammars to keep llama.cpp inside its GBNF \
            expressiveness envelope.
            """
    )

    // MARK: - Validation failure

    /// Describes why a schema is unsafe to compile to GBNF.
    public struct ValidationFailure: Sendable, Equatable, Error {
        /// Short developer-facing description of the rejection reason.
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

    /// Returns `nil` when `schema` is safe to compile to GBNF, or a
    /// ``ValidationFailure`` naming the first unsafe construct when it is not.
    ///
    /// Always run this before calling `llama_sampler_init_grammar` with a
    /// grammar derived from `schema`. See the type-level documentation and
    /// ``cveStatus`` for the full rationale.
    ///
    /// - Parameters:
    ///   - schema: The JSON Schema to check (typically `ToolDefinition.parameters`).
    ///   - path:   Accumulated path prefix for nested calls — callers should
    ///             use the default empty array.
    public func validate(_ schema: JSONSchemaValue, path: [String] = []) -> ValidationFailure? {
        guard case let .object(dict) = schema else {
            // Non-object schemas (scalars, arrays-as-values) are safe; skip.
            return nil
        }

        // Reject schema combiners — the GBNF IR has no alternation / negation nodes.
        for combiner in ["anyOf", "oneOf", "allOf", "not"] {
            if dict[combiner] != nil {
                return ValidationFailure(
                    reason: "'\(combiner)' is not supported by the GBNF compiler and may cause a crash.",
                    path: path + [combiner]
                )
            }
        }

        // Reject Draft 2020-12 integer-form exclusive bounds — triggers a
        // type-confusion path in the GBNF numeric rule builder.
        for bound in ["exclusiveMinimum", "exclusiveMaximum"] {
            if dict[bound] != nil {
                return ValidationFailure(
                    reason: "'\(bound)' triggers a type-confusion path in the GBNF numeric rule builder.",
                    path: path + [bound]
                )
            }
        }

        // Reject nullable union: `"type": ["string", "null"]` — any array
        // `type` value containing `"null"` produces unbounded alternation.
        if let typeValue = dict["type"], case let .array(typeArr) = typeValue {
            let hasNull = typeArr.contains {
                if case .string(let s) = $0 { return s == "null" }
                return false
            }
            if hasNull {
                return ValidationFailure(
                    reason: "Nullable union type (array containing 'null') produces unbounded alternation in GBNF.",
                    path: path + ["type"]
                )
            }
        }

        // Recurse into `properties` sub-schemas.
        if let propsValue = dict["properties"], case let .object(properties) = propsValue {
            // Sort for deterministic failure reporting.
            for (key, subSchema) in properties.sorted(by: { $0.key < $1.key }) {
                if let failure = validate(subSchema, path: path + ["properties", key]) {
                    return failure
                }
            }
        }

        // Recurse into `items`. JSON Schema permits two shapes:
        //   - a single sub-schema object (list validation), or
        //   - an array of sub-schemas (tuple validation, draft-04 / 2019-09).
        // Without the array branch, unsafe constructs nested inside a tuple-form
        // `items` would bypass the pre-validator and reach the GBNF compiler.
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
