import Foundation

// MARK: - ToolArgumentError

/// Errors surfaced by ``ToolArgumentCoercer`` when the schema or argument tree
/// violates a structural invariant the coercer cannot recover from.
enum ToolArgumentError: Error, Equatable {
    /// The input schema or arguments exceed ``ToolArgumentCoercer/maxDepth``.
    /// Pathologically nested or self-referential schemas would otherwise blow
    /// the coercer's stack; failing fast forces the caller to surface a real
    /// diagnostic rather than crashing inside the dispatch hot path.
    case schemaTooDeep
}

// MARK: - ToolArgumentCoercer

/// Coerces string-typed arguments to the primitive type declared in a JSON
/// Schema's `properties` map.
///
/// Models — especially smaller open-weight ones — frequently emit
/// JSON-encoded tool arguments where every value is a string, even when the
/// schema declares `integer`, `number`, or `boolean`. Without coercion, the
/// schema validator rejects these calls before they reach the executor and
/// the user sees a hard failure for what is effectively a serialisation
/// quirk.
///
/// ## Recursion
///
/// As of I3, coercion descends into nested objects and arrays of objects up
/// to ``maxDepth``. Schemas that declare
///
/// ```json
/// { "properties": { "filter": { "type": "object",
///   "properties": { "limit": { "type": "integer" } } } } }
/// ```
///
/// now coerce `{"filter":{"limit":"10"}}` to `{"filter":{"limit":10}}`. Small
/// open-weight models — the explicit motivating case for this coercer —
/// mistype nested fields more often than top-level ones, so the original
/// "top-level only" scope shipped with a known false-rejection rate that
/// was not justified by any safety property.
///
/// ## Bounded depth
///
/// The recursion is hard-capped at ``maxDepth`` (8) levels. A schema deeper
/// than that throws ``ToolArgumentError/schemaTooDeep`` so callers surface a
/// precise failure rather than a stack overflow. Real tool schemas in
/// practice rarely exceed three or four levels — the cap exists to bound
/// adversarial inputs, not to limit legitimate use.
///
/// ## Behaviour
///
/// - Strings that fail to parse fall through unchanged so the validator
///   still produces its real error message.
/// - Already-correct types (an actual JSON number against a `number`
///   schema, etc.) pass through untouched.
/// - Schemas without a `properties` map (or non-object inputs) pass
///   through unchanged.
///
/// The coercer is intentionally a free namespace rather than a stored
/// dependency on ``ToolRegistry``: it has no state and no allocation cost
/// on the no-op path.
enum ToolArgumentCoercer {

    /// Maximum recursion depth before the coercer throws
    /// ``ToolArgumentError/schemaTooDeep``. Eight levels covers every
    /// real-world tool schema observed in practice; the cap exists to
    /// bound stack usage on adversarial / pathological inputs.
    static let maxDepth: Int = 8

    /// Returns `value` with string entries coerced to match the primitive
    /// types declared in `schema.properties`, recursing into nested objects
    /// and arrays of objects up to ``maxDepth``.
    ///
    /// Inputs that aren't objects, or schemas without a `properties` map,
    /// pass through unchanged. Throws ``ToolArgumentError/schemaTooDeep`` if
    /// the schema or argument tree exceeds the depth cap.
    static func coerce(
        _ value: JSONSchemaValue,
        against schema: JSONSchemaValue
    ) throws -> JSONSchemaValue {
        try coerceObject(value, against: schema, depth: 0)
    }

    /// Convenience wrapper that swallows ``ToolArgumentError/schemaTooDeep``
    /// and returns the original `value`. Use when the call site wants the
    /// coercion to be fully best-effort — the validator will then surface
    /// whatever real error the un-coerced arguments produce.
    static func coerceBestEffort(
        _ value: JSONSchemaValue,
        against schema: JSONSchemaValue
    ) -> JSONSchemaValue {
        do {
            return try coerce(value, against: schema)
        } catch {
            return value
        }
    }

    // MARK: - Recursion core

    private static func coerceObject(
        _ value: JSONSchemaValue,
        against schema: JSONSchemaValue,
        depth: Int
    ) throws -> JSONSchemaValue {
        guard depth <= maxDepth else { throw ToolArgumentError.schemaTooDeep }
        guard case .object(let args) = value else { return value }
        guard case .object(let schemaObject) = schema,
              case .object(let properties) = schemaObject["properties"] ?? .null
        else {
            return value
        }

        var coerced: [String: JSONSchemaValue] = [:]
        coerced.reserveCapacity(args.count)
        for (key, argValue) in args {
            guard let propertySchema = properties[key] else {
                coerced[key] = argValue
                continue
            }
            coerced[key] = try coerceValue(argValue, against: propertySchema, depth: depth + 1)
        }
        return .object(coerced)
    }

    private static func coerceValue(
        _ value: JSONSchemaValue,
        against schema: JSONSchemaValue,
        depth: Int
    ) throws -> JSONSchemaValue {
        guard depth <= maxDepth else { throw ToolArgumentError.schemaTooDeep }
        switch value {
        case .string(let s):
            return coerceScalar(s, against: schema)
        case .object:
            // Recurse into a nested object only when the schema also declares
            // an object shape. Otherwise the original value passes through —
            // the validator will surface the type mismatch with its native
            // message.
            if isObjectSchema(schema) {
                return try coerceObject(value, against: schema, depth: depth)
            }
            return value
        case .array(let elements):
            // Recurse into each element when the schema's `items` shape is an
            // object. JSON Schema allows `items` to be either a sub-schema
            // object (homogeneous list) or an array of sub-schemas (tuple
            // form, draft-04 / 2019-09); we handle both.
            return try coerceArray(elements, against: schema, depth: depth)
        case .number, .bool, .null:
            return value
        }
    }

    private static func coerceArray(
        _ elements: [JSONSchemaValue],
        against schema: JSONSchemaValue,
        depth: Int
    ) throws -> JSONSchemaValue {
        guard case .object(let schemaObject) = schema,
              let itemsValue = schemaObject["items"]
        else {
            return .array(elements)
        }
        switch itemsValue {
        case .object:
            // Single sub-schema — apply to every element.
            var coerced: [JSONSchemaValue] = []
            coerced.reserveCapacity(elements.count)
            for element in elements {
                coerced.append(try coerceValue(element, against: itemsValue, depth: depth + 1))
            }
            return .array(coerced)
        case .array(let perIndexSchemas):
            // Tuple form: pair each element with the schema at its index.
            // Elements past the schema array fall through unchanged — that's
            // what JSON Schema's `additionalItems: true` (the default) means.
            var coerced: [JSONSchemaValue] = []
            coerced.reserveCapacity(elements.count)
            for (index, element) in elements.enumerated() {
                if index < perIndexSchemas.count {
                    coerced.append(try coerceValue(element, against: perIndexSchemas[index], depth: depth + 1))
                } else {
                    coerced.append(element)
                }
            }
            return .array(coerced)
        default:
            return .array(elements)
        }
    }

    /// Returns `true` when `schema` declares `type: object` — gates whether
    /// nested-object recursion fires. Without this check we'd happily descend
    /// into a property whose schema is just `{ "type": "string" }` and an
    /// argument that surprised us with an object value, which would silently
    /// rewrite the keys and mask a real validator failure.
    private static func isObjectSchema(_ schema: JSONSchemaValue) -> Bool {
        guard case .object(let dict) = schema else { return false }
        guard case .string(let typeName) = dict["type"] ?? .null else {
            // No declared `type` — be permissive: if the schema has a
            // `properties` map, treat it as an object. This matches the
            // behaviour many JSON-schema validators take for under-specified
            // sub-schemas.
            return dict["properties"] != nil
        }
        return typeName == "object"
    }

    // MARK: - Scalar coercion

    /// Coerces a single string against a property's declared `type`.
    ///
    /// Returns the original `.string(s)` when the schema doesn't ask for a
    /// primitive type or when parsing fails — the registry's validator then
    /// surfaces a precise type-mismatch error if the call really is
    /// malformed.
    private static func coerceScalar(_ s: String, against schema: JSONSchemaValue) -> JSONSchemaValue {
        guard case .object(let schemaObject) = schema,
              case .string(let typeName) = schemaObject["type"] ?? .null
        else {
            return .string(s)
        }
        switch typeName {
        case "integer":
            return tryCoerceInteger(s)
        case "number":
            return tryCoerceNumber(s)
        case "boolean":
            return tryCoerceBoolean(s)
        default:
            return .string(s)
        }
    }

    /// Parses `s` as a JSON number. `JSONSchemaValue` represents all numbers
    /// as `Double`; the validator's `integer` check accepts a `.number(n)`
    /// when `n.rounded() == n`, so whole-valued floats round-trip correctly.
    /// Non-finite values fall through unchanged.
    private static func tryCoerceNumber(_ s: String) -> JSONSchemaValue {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let n = Double(trimmed), n.isFinite else { return .string(s) }
        return .number(n)
    }

    /// Parses `s` as an integer-valued JSON number. Strings like `"3.14"`
    /// fall through unchanged so the validator surfaces a precise
    /// "expected integer got string" error rather than a confusing
    /// "expected integer got number" one — and so executors that skip
    /// validation never receive a fractional value for an `integer` field.
    private static func tryCoerceInteger(_ s: String) -> JSONSchemaValue {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let n = Double(trimmed), n.isFinite, n.rounded() == n else {
            return .string(s)
        }
        return .number(n)
    }

    private static func tryCoerceBoolean(_ s: String) -> JSONSchemaValue {
        switch s.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return .string(s)
        }
    }
}
