import Foundation

/// Rewrites a caller-supplied JSON Schema into the *strict* shape each cloud
/// provider requires when it guarantees the model's output will validate
/// against the schema.
///
/// Both OpenAI (`strict: true` function tools, `response_format:
/// {type: "json_schema", strict: true}`) and Anthropic
/// (`structured-outputs-2025-11-13`: `strict: true` tools / `output_format`)
/// impose two non-negotiable structural rules on every object level:
///
/// 1. `additionalProperties: false` — the model may not emit keys outside the
///    declared `properties`.
/// 2. Every declared property must appear in `required`.
///
/// That shared core lives in ``strictCore(_:)``. The two providers then diverge:
///
/// - **OpenAI** does not support *optional* fields the way ordinary JSON Schema
///   does — under `strict` every property is required, so an optional `T?` must
///   be expressed as a `{"type": ["T", "null"]}` *union* (the field is still in
///   `required`, but may be `null`). OpenAI also rejects (`400 Bad Request`) a
///   number of validation keywords inside a strict schema — `minLength`,
///   `maxLength`, `pattern`, `format`, `minimum`, `maximum`, `minItems`,
///   `maxItems`, etc. — so ``openAIStrict(_:)`` strips them.
/// - **Anthropic**'s strict mode keeps the full JSON Schema validation
///   vocabulary (it does not reject `format`/`minLength`/etc.) and does not
///   require the OpenAI null-union rewrite for previously-optional fields.
///   ``anthropicStrict(_:)`` therefore applies only the shared core.
///
/// Both entry points are kept distinct even though Anthropic's transform is the
/// shared core today: the call sites differ (OpenAI threads through
/// `OpenAIToolEncoding` + `response_format`; Anthropic through the Claude
/// `input_schema`), and OpenAI's extra rules are likely to keep diverging.
///
/// The transform is capability-gated at the call site — it is only invoked when
/// the backend advertises ``BackendCapabilities/supportsStrictSchema`` — so
/// providers that reject `additionalProperties: false` never see a strict
/// schema and keep emitting their legacy shape.
public enum StrictSchemaTransform: Sendable {

    /// JSON Schema validation keywords OpenAI's strict mode rejects with a
    /// `400`. We strip these from every object/property level before sending.
    private static let openAIUnsupportedKeywords: Set<String> = [
        "minLength", "maxLength", "pattern", "format",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "multipleOf",
        "minItems", "maxItems", "uniqueItems",
        "minProperties", "maxProperties",
        "minContains", "maxContains",
        "contentEncoding", "contentMediaType",
        "default",
    ]

    /// Returns the JSON Schema string carried by a
    /// ``StructuredOutputStrategy/jsonSchema(_:)`` strategy, or `nil` for any
    /// other (or `nil`) strategy. The strict emission path only fires for the
    /// json-schema case, so backends use this to decide whether a strict
    /// request was made.
    public static func jsonSchemaString(from strategy: StructuredOutputStrategy?) -> String? {
        if case .jsonSchema(let schema) = strategy, !schema.isEmpty {
            return schema
        }
        return nil
    }

    /// Produces the OpenAI strict shape: shared core + null-union rewrite for
    /// the fields that were previously optional + unsupported-keyword stripping.
    public static func openAIStrict(_ schema: JSONSchemaValue) -> JSONSchemaValue {
        transform(schema, provider: .openAI)
    }

    /// Produces the Anthropic strict shape (`structured-outputs-2025-11-13`):
    /// shared core only. Anthropic keeps the full validation vocabulary and does
    /// not require the OpenAI null-union rewrite.
    public static func anthropicStrict(_ schema: JSONSchemaValue) -> JSONSchemaValue {
        transform(schema, provider: .anthropic)
    }

    // MARK: - Implementation

    private enum Provider {
        case openAI
        case anthropic
    }

    private static func transform(_ value: JSONSchemaValue, provider: Provider) -> JSONSchemaValue {
        switch value {
        case .object(let dict):
            return transformObject(dict, provider: provider)
        case .array(let items):
            // A bare array node (e.g. an `anyOf`/`prefixItems` list). Recurse
            // element-wise; objects inside still get the strict core applied.
            return .array(items.map { transform($0, provider: provider) })
        default:
            return value
        }
    }

    private static func transformObject(
        _ dict: [String: JSONSchemaValue],
        provider: Provider
    ) -> JSONSchemaValue {
        var out = dict

        // Strip keywords OpenAI's strict mode rejects. Anthropic keeps them.
        if provider == .openAI {
            for keyword in openAIUnsupportedKeywords {
                out.removeValue(forKey: keyword)
            }
        }

        let typeIsObject = isObjectType(out["type"])
        let hasProperties = out["properties"] != nil

        // Recurse into nested schema-bearing keywords regardless of `type` so
        // composed schemas (anyOf/oneOf/allOf, array `items`, `$defs`) are
        // transformed too.
        for key in ["items", "additionalItems", "contains", "not", "if", "then", "else"] {
            if let nested = out[key] {
                out[key] = transform(nested, provider: provider)
            }
        }
        for key in ["anyOf", "oneOf", "allOf", "prefixItems"] {
            if case .array(let arr)? = out[key] {
                out[key] = .array(arr.map { transform($0, provider: provider) })
            }
        }
        for key in ["$defs", "definitions"] {
            if case .object(let defs)? = out[key] {
                out[key] = .object(defs.mapValues { transform($0, provider: provider) })
            }
        }

        // Apply the strict-object core only to object-typed nodes (or nodes
        // that declare `properties`), since the all-required +
        // additionalProperties:false rules are object-level.
        guard typeIsObject || hasProperties else {
            return .object(out)
        }

        // Capture the originally-required set BEFORE we force everything
        // required: OpenAI must express a previously-*optional* field as a
        // `{"type": ["T", "null"]}` union (it stays in `required` but may be
        // null). Anthropic keeps the field's type untouched.
        let originallyRequired = requiredNameSet(out["required"])

        var transformedProperties: [String: JSONSchemaValue] = [:]
        var propertyNames: [String] = []
        if case .object(let props)? = out["properties"] {
            for (name, propSchema) in props {
                propertyNames.append(name)
                let wasOptional = !originallyRequired.contains(name)
                transformedProperties[name] = strictProperty(
                    propSchema,
                    provider: provider,
                    wasOptional: wasOptional
                )
            }
            out["properties"] = .object(transformedProperties)
        }

        // Rule 1: additionalProperties: false on every object level.
        out["additionalProperties"] = .bool(false)

        // Rule 2: every declared property is required. Preserve any caller
        // ordering already present, then append the rest deterministically.
        out["required"] = .array(requiredList(existing: out["required"], allNames: propertyNames))

        return .object(out)
    }

    /// Transforms a single property's schema, applying the OpenAI null-union
    /// rewrite when that field was previously optional.
    ///
    /// For OpenAI a previously-optional `T` becomes a union `["T", "null"]` so
    /// the field can still be marked `required` (OpenAI strict forbids absent
    /// keys) while permitting `null`. Anthropic leaves the type unchanged.
    private static func strictProperty(
        _ schema: JSONSchemaValue,
        provider: Provider,
        wasOptional: Bool
    ) -> JSONSchemaValue {
        let transformed = transform(schema, provider: provider)
        guard provider == .openAI, wasOptional else {
            return transformed
        }
        return addNullToType(transformed)
    }

    /// Rewrites a schema node's `type` to include `"null"` (OpenAI optional
    /// rewrite). Handles both the string form (`"type": "string"` →
    /// `["string", "null"]`) and the array form (appending `"null"` if absent).
    /// A node without a concrete `type` (e.g. a pure `anyOf`) is returned
    /// unchanged — there is no scalar type to widen.
    private static func addNullToType(_ value: JSONSchemaValue) -> JSONSchemaValue {
        guard case .object(var dict) = value else { return value }
        switch dict["type"] {
        case .string(let s) where s != "null":
            dict["type"] = .array([.string(s), .string("null")])
        case .array(let arr):
            let hasNull = arr.contains { if case .string(let s) = $0 { return s == "null" }; return false }
            dict["type"] = hasNull ? .array(arr) : .array(arr + [.string("null")])
        default:
            break
        }
        return .object(dict)
    }

    /// Extracts the set of property names listed in a `required` array.
    private static func requiredNameSet(_ value: JSONSchemaValue?) -> Set<String> {
        guard case .array(let arr)? = value else { return [] }
        var names = Set<String>()
        for entry in arr {
            if case .string(let name) = entry { names.insert(name) }
        }
        return names
    }

    /// Whether a `type` node denotes (or includes) `"object"`.
    private static func isObjectType(_ value: JSONSchemaValue?) -> Bool {
        switch value {
        case .string(let s):
            return s == "object"
        case .array(let arr):
            return arr.contains { if case .string(let s) = $0 { return s == "object" }; return false }
        default:
            return false
        }
    }

    /// Builds the `required` array: every declared property, with any
    /// already-present entries kept in their original order first.
    private static func requiredList(
        existing: JSONSchemaValue?,
        allNames: [String]
    ) -> [JSONSchemaValue] {
        var ordered: [String] = []
        var seen = Set<String>()
        if case .array(let arr)? = existing {
            for entry in arr {
                if case .string(let name) = entry, !seen.contains(name) {
                    ordered.append(name)
                    seen.insert(name)
                }
            }
        }
        for name in allNames.sorted() where !seen.contains(name) {
            ordered.append(name)
            seen.insert(name)
        }
        return ordered.map { .string($0) }
    }
}
