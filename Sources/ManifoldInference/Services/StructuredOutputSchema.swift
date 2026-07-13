import Foundation

/// A public, self-contained facade over MK's JSON-Schema → constrained-output
/// machinery, intended to replace the hand-rolled schema layers that downstream
/// apps built when MK's tool-calling path was unreliable (Idlewick's
/// `DeclarativeTool`, Fireside's `ExtractionSchema` — see #1992).
///
/// One schema in, three capabilities out:
///
/// 1. **Lower to a grammar** (``gbnfGrammar()``): turn the schema into a GBNF
///    grammar string a grammar-capable local backend can use to *constrain*
///    decoding, so the model can only emit JSON matching the schema. Pass the
///    result through ``GenerationConfig/grammar``.
/// 2. **Validate a value** (``validate(_:)`` / ``validate(json:)``): check a
///    model's output against the schema, getting back a model-readable failure
///    message you can feed straight back into the conversation for self-repair.
/// 3. **Parse + validate** (``parse(_:)``): decode a raw JSON string *and*
///    validate it in one step, returning the typed ``JSONSchemaValue`` tree on
///    success or a ``SchemaViolation`` on failure.
///
/// ## Why a facade
///
/// The underlying pieces — ``ToolGrammarBuilder`` (lowering) and
/// ``JSONSchemaValidator`` (validation) — already existed but were discovered
/// piecemeal and documented for the internal tool-call path. This type is the
/// single, documented package entry point so a consumer can write:
///
/// ```swift
/// let schema = StructuredOutputSchema(
///     .object([
///         "type": .string("object"),
///         "properties": .object([
///             "city": .object(["type": .string("string")]),
///             "units": .object([
///                 "type": .string("string"),
///                 "enum": .array([.string("metric"), .string("imperial")]),
///             ]),
///         ]),
///         "required": .array([.string("city")]),
///     ])
/// )
///
/// // 1. Constrain decoding.
/// var config = GenerationConfig()
/// config.grammar = schema.gbnfGrammar()   // nil → schema carries no constraint
///
/// // 2 + 3. Validate / parse the model's reply.
/// switch schema.parse(modelOutput) {
/// case .success(let value):  use(value)
/// case .failure(let violation): retry(with: violation.modelReadableMessage)
/// }
/// ```
///
/// ## Supported subset
///
/// Grammar lowering and validation each cover a deliberate JSON-Schema subset
/// tuned for LLM structured output — see ``ToolGrammarBuilder`` and
/// ``JSONSchemaValidator`` for the exact keyword coverage. The two surfaces
/// differ slightly: lowering *degrades gracefully* (an unmodeled node lowers to
/// a generic JSON value, never failing the build), while validation *fails
/// closed* on unsupported keywords (it refuses to claim validity it cannot
/// enforce) — a ``SchemaViolation`` naming the unsupported keyword is returned
/// from ``validate(_:)`` / ``parse(_:)`` in that case.
package struct StructuredOutputSchema: Sendable, Equatable, Hashable {

    /// The JSON-Schema document this facade wraps.
    package let schema: JSONSchemaValue

    /// Wraps a JSON-Schema document for constrained output.
    ///
    /// - Parameter schema: the schema, typically an object schema with
    ///   `properties`/`required`. A bare scalar schema carries no structure to
    ///   constrain — ``gbnfGrammar()`` returns `nil` for it.
    package init(_ schema: JSONSchemaValue) {
        self.schema = schema
    }

    // MARK: - Grammar lowering

    /// Lowers the schema to a GBNF grammar string suitable for
    /// ``GenerationConfig/grammar``, constraining a grammar-capable backend to
    /// emit only JSON matching the schema.
    ///
    /// Returns `nil` when the schema carries no structural information to
    /// constrain (a bare scalar, or a node the lowerer models only as the
    /// generic JSON value). A `nil` result means "do not set a grammar" — a
    /// vacuous grammar that accepts anything is worse than none, so callers
    /// should fall back to unconstrained sampling.
    ///
    /// Object schemas always produce a grammar: unmodeled sub-nodes degrade to
    /// the generic JSON value rule rather than failing the build, so the
    /// envelope and known keys stay constrained even when one field cannot be.
    ///
    /// - Returns: a GBNF grammar string, or `nil` if the schema constrains
    ///   nothing.
    package func gbnfGrammar() -> String? {
        // Prefer the object-payload lowering: it accepts type-omitted object
        // schemas (common in extraction payloads) and always returns a grammar
        // for object-shaped input. For non-object schemas it returns nil, in
        // which case the generic schema lowerer is the right path (it constrains
        // arrays / typed scalars and returns nil only for the truly vacuous).
        if let objectGrammar = ToolGrammarBuilder().buildObjectGrammar(for: schema) {
            return objectGrammar
        }
        return ToolGrammarBuilder().buildSchemaGrammar(for: schema)
    }

    // MARK: - Validation

    /// A structured-output validation failure, carrying both a model-readable
    /// message (feed it back to the model for self-repair) and the structural
    /// path to the offending node (for logging / tests).
    ///
    /// This re-exports ``JSONSchemaValidator/ValidationFailure`` under the
    /// facade's vocabulary so consumers need not reach into the validator type.
    package typealias SchemaViolation = JSONSchemaValidator.ValidationFailure

    /// Validates an already-parsed JSON value against the schema.
    ///
    /// - Parameter value: the value to check, as a ``JSONSchemaValue`` tree.
    /// - Returns: `nil` when the value satisfies the schema; otherwise the first
    ///   ``SchemaViolation`` encountered.
    package func validate(_ value: JSONSchemaValue) -> SchemaViolation? {
        JSONSchemaValidator().validate(value, against: schema)
    }

    /// Parses a raw JSON string and validates it against the schema *without*
    /// returning the parsed value — use when you only need a pass/fail verdict.
    ///
    /// - Parameter json: the raw JSON text emitted by the model.
    /// - Returns: `nil` when the text parses and satisfies the schema; otherwise
    ///   a ``SchemaViolation`` describing the parse error or first violation.
    package func validate(json: String) -> SchemaViolation? {
        JSONSchemaValidator().validate(arguments: json, against: schema)
    }

    /// Parses a raw JSON string *and* validates it against the schema in one
    /// step, returning the typed value on success.
    ///
    /// This is the primary entry point for the "constrain → parse → use" loop:
    /// the model's output is decoded into a typed ``JSONSchemaValue`` tree only
    /// when it both parses as JSON and satisfies the schema. On failure the
    /// ``SchemaViolation`` carries a model-readable message you can append to the
    /// conversation to drive a self-correction turn.
    ///
    /// - Parameter json: the raw JSON text emitted by the model.
    /// - Returns: `.success(value)` with the validated tree, or
    ///   `.failure(violation)` describing the parse error or first violation.
    package func parse(_ json: String) -> Result<JSONSchemaValue, SchemaViolation> {
        guard let data = json.data(using: .utf8) else {
            return .failure(SchemaViolation(
                modelReadableMessage: "output was not valid UTF-8 JSON.",
                path: []
            ))
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            return .failure(SchemaViolation(
                modelReadableMessage: "output was not valid JSON.",
                path: []
            ))
        }
        let value = JSONSchemaValidator.lift(parsed)
        if let violation = validate(value) {
            return .failure(violation)
        }
        return .success(value)
    }
}
