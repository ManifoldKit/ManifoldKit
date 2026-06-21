import Foundation

/// Validates a JSON value against a JSON-Schema document.
///
/// This is a **deliberately small subset** of JSON Schema Draft 2020-12, tuned for
/// validating tool-call arguments emitted by LLMs. It is not a general-purpose
/// JSON Schema implementation.
///
/// ## Supported keywords
///
/// - `type`: `"object"`, `"string"`, `"number"`, `"integer"`, `"boolean"`, `"array"`, `"null"`.
///   A value can also be a union given as an array of type names (e.g. `["string", "null"]`).
/// - `required`: `["field1", …]` on objects.
/// - `properties`: `{"field1": <nested schema>}` on objects (recursive).
/// - `additionalProperties`: `false` rejects unknown keys; omitted or `true` allows them.
/// - `enum`: `[…]` — value must appear in the list (primitive values only).
/// - `items`: `<nested schema>` on arrays (recursive; applied to every element).
/// - `minimum` / `maximum` on numeric values.
/// - `minLength` / `maxLength` on strings.
/// - `minItems` / `maxItems` on arrays.
///
/// ## Unsupported (fail-closed) keywords
///
/// The following keywords cause validation to **fail closed** — the validator refuses
/// to evaluate the schema rather than silently claim validity. This protects callers
/// who ship a schema the validator cannot correctly enforce.
///
/// `anyOf`, `oneOf`, `allOf`, `not`, `$ref`, `$defs`, `definitions`,
/// `patternProperties`, `propertyNames`, `dependentRequired`, `format`, `pattern`.
///
/// If your tool needs one of these features, wait for a future validator version
/// that supports it — do not ship a schema that uses them in the meantime.
public struct JSONSchemaValidator: Sendable {

    public init() {}

    /// A validation failure, shaped so an 8B model can parse it and self-correct
    /// on the next turn.
    public struct ValidationFailure: Sendable, Equatable, Hashable, Error {

        /// A short, model-readable sentence describing the violation. Prefer:
        ///
        /// ✓ `"argument 'city' is required but was missing"`
        /// ✓ `"argument 'units' must be one of: metric, imperial. Got: 'celsius'"`
        /// ✓ `"argument 'count' must be a number. Got string: 'five'"`
        ///
        /// Avoid JSON-pointer jargon and library-internal error codes.
        public let modelReadableMessage: String

        /// Structural path to the violation, rooted at the top-level schema.
        /// Useful for logging and tests; not intended for model consumption.
        public let path: [String]

        public init(modelReadableMessage: String, path: [String]) {
            self.modelReadableMessage = modelReadableMessage
            self.path = path
        }
    }

    // MARK: - Public entry points

    /// Validate a JSON value against a JSON-Schema document.
    ///
    /// - Returns: `nil` if the value satisfies the schema; otherwise a
    ///   ``ValidationFailure`` describing the first violation encountered.
    public func validate(_ value: JSONSchemaValue, against schema: JSONSchemaValue) -> ValidationFailure? {
        validate(value: value, schema: schema, path: [])
    }

    /// Parse a raw JSON string and validate it against `schema`.
    ///
    /// Returns a failure with a clear, model-readable message if the string
    /// does not parse as JSON.
    public func validate(arguments: String, against schema: JSONSchemaValue) -> ValidationFailure? {
        guard let data = arguments.data(using: .utf8) else {
            return ValidationFailure(
                modelReadableMessage: "arguments were not valid UTF-8 JSON.",
                path: []
            )
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return ValidationFailure(
                modelReadableMessage: "arguments were not valid JSON. \(Self.concise(error))",
                path: []
            )
        }
        let value = Self.lift(parsed)
        return validate(value, against: schema)
    }

    // MARK: - Recursive validation

    private func validate(
        value: JSONSchemaValue,
        schema: JSONSchemaValue,
        path: [String]
    ) -> ValidationFailure? {
        // A schema document must itself be a JSON object. Anything else is
        // malformed — callers get a clear error rather than a silent pass.
        guard case let .object(schemaObject) = schema else {
            return ValidationFailure(
                modelReadableMessage: "schema is not a JSON object (found \(Self.typeName(of: schema))).",
                path: path
            )
        }

        // Fail-closed on unsupported keywords before doing any other work.
        if let failure = rejectUnsupportedKeywords(schemaObject, path: path) {
            return failure
        }

        // `enum` short-circuits on both primitives and composite values and
        // produces the clearest model-facing message, so it runs first.
        if let failure = checkEnum(value: value, schemaObject: schemaObject, path: path) {
            return failure
        }

        // `type` — may be a single string or an array of strings (union).
        if let typeValue = schemaObject["type"],
           let failure = checkType(value: value, typeValue: typeValue, path: path) {
            return failure
        }

        return validatePerKindKeywords(value: value, schemaObject: schemaObject, path: path)
    }

    private func checkEnum(
        value: JSONSchemaValue,
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        guard let enumValues = schemaObject["enum"],
              case let .array(allowed) = enumValues else {
            return nil
        }
        if allowed.contains(value) { return nil }
        return ValidationFailure(
            modelReadableMessage: "argument \(Self.describePath(path)) must be one of: "
                + Self.describeEnum(allowed)
                + ". Got: " + Self.describeValue(value) + ".",
            path: path
        )
    }

    private func validatePerKindKeywords(
        value: JSONSchemaValue,
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        switch value {
        case .object(let properties):
            return validateObject(properties: properties, schemaObject: schemaObject, path: path)
        case .array(let items):
            return validateArray(items: items, schemaObject: schemaObject, path: path)
        case .string(let s):
            return validateString(value: s, schemaObject: schemaObject, path: path)
        case .number(let n):
            return validateNumber(value: n, schemaObject: schemaObject, path: path)
        case .integer(let i):
            return validateNumber(value: Double(i), schemaObject: schemaObject, path: path)
        case .bool, .null:
            return nil
        }
    }

    // MARK: - Keyword handlers

    private func checkType(
        value: JSONSchemaValue,
        typeValue: JSONSchemaValue,
        path: [String]
    ) -> ValidationFailure? {
        let expected: [String]
        switch typeValue {
        case .string(let s):
            expected = [s]
        case .array(let arr):
            var names: [String] = []
            names.reserveCapacity(arr.count)
            for entry in arr {
                guard case let .string(name) = entry else {
                    return ValidationFailure(
                        modelReadableMessage: "schema 'type' must be a string or array of strings.",
                        path: path
                    )
                }
                names.append(name)
            }
            expected = names
        default:
            return ValidationFailure(
                modelReadableMessage: "schema 'type' must be a string or array of strings.",
                path: path
            )
        }

        if expected.contains(where: { valueMatchesType(value, typeName: $0) }) {
            return nil
        }

        let expectedDescription: String
        if expected.count == 1 {
            expectedDescription = "a \(expected[0])"
        } else {
            expectedDescription = "one of: " + expected.joined(separator: ", ")
        }
        return ValidationFailure(
            modelReadableMessage: "argument \(Self.describePath(path)) must be \(expectedDescription). Got \(Self.describeActualType(value)): \(Self.describeValue(value)).",
            path: path
        )
    }

    private func valueMatchesType(_ value: JSONSchemaValue, typeName: String) -> Bool {
        switch typeName {
        case "object":  return isObject(value)
        case "array":   return isArray(value)
        case "string":  return isString(value)
        case "boolean": return isBoolean(value)
        case "null":    return isNull(value)
        case "number":  return isNumber(value)
        case "integer": return isInteger(value)
        default:        return false
        }
    }

    private func isObject(_ value: JSONSchemaValue) -> Bool {
        if case .object = value { return true }
        return false
    }

    private func isArray(_ value: JSONSchemaValue) -> Bool {
        if case .array = value { return true }
        return false
    }

    private func isString(_ value: JSONSchemaValue) -> Bool {
        if case .string = value { return true }
        return false
    }

    private func isBoolean(_ value: JSONSchemaValue) -> Bool {
        if case .bool = value { return true }
        return false
    }

    private func isNull(_ value: JSONSchemaValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private func isNumber(_ value: JSONSchemaValue) -> Bool {
        // A whole-number `.integer` satisfies the JSON-Schema "number" type too.
        switch value {
        case .number, .integer: return true
        default: return false
        }
    }

    private func isInteger(_ value: JSONSchemaValue) -> Bool {
        switch value {
        case .integer:
            return true
        case let .number(n):
            return n.isFinite && n.rounded() == n
        default:
            return false
        }
    }

    private func validateObject(
        properties: [String: JSONSchemaValue],
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        // `required` — validated first so the model sees missing-field errors
        // before any type-mismatch errors on the fields that *are* present.
        if let failure = validateRequired(properties: properties, schemaObject: schemaObject, path: path) {
            return failure
        }

        let propertySchemas: [String: JSONSchemaValue]
        switch resolvePropertySchemas(schemaObject: schemaObject, path: path) {
        case .failure(let failure):
            return failure
        case .success(let dict):
            propertySchemas = dict
        }

        if let failure = validateAdditionalProperties(
            properties: properties,
            propertySchemas: propertySchemas,
            schemaObject: schemaObject,
            path: path
        ) {
            return failure
        }

        return validateProperties(
            properties: properties,
            propertySchemas: propertySchemas,
            path: path
        )
    }

    private func validateRequired(
        properties: [String: JSONSchemaValue],
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        guard let requiredValue = schemaObject["required"] else { return nil }
        guard case let .array(requiredArray) = requiredValue else {
            return ValidationFailure(
                modelReadableMessage: "schema 'required' must be an array of strings.",
                path: path
            )
        }
        // Deterministic scan: take fields in the order the schema lists them so
        // tests can assert which missing field is reported first.
        for entry in requiredArray {
            guard case let .string(field) = entry else {
                return ValidationFailure(
                    modelReadableMessage: "schema 'required' entries must be strings.",
                    path: path
                )
            }
            if properties[field] == nil {
                return ValidationFailure(
                    modelReadableMessage: "argument '\(field)' is required but was missing.",
                    path: path + [field]
                )
            }
        }
        return nil
    }

    private enum PropertySchemaResolution {
        case success([String: JSONSchemaValue])
        case failure(ValidationFailure)
    }

    private func resolvePropertySchemas(
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> PropertySchemaResolution {
        guard let propsValue = schemaObject["properties"] else {
            return .success([:])
        }
        guard case let .object(dict) = propsValue else {
            return .failure(ValidationFailure(
                modelReadableMessage: "schema 'properties' must be an object.",
                path: path
            ))
        }
        return .success(dict)
    }

    private func validateAdditionalProperties(
        properties: [String: JSONSchemaValue],
        propertySchemas: [String: JSONSchemaValue],
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        guard let ap = schemaObject["additionalProperties"],
              case let .bool(allowed) = ap,
              allowed == false else {
            return nil
        }
        // Iterate in sorted order so the reported "extra" key is deterministic.
        for key in properties.keys.sorted() where propertySchemas[key] == nil {
            let allowedNames = propertySchemas.keys.sorted().joined(separator: ", ")
            let allowedDescription = allowedNames.isEmpty ? "(none)" : allowedNames
            return ValidationFailure(
                modelReadableMessage: "argument '\(key)' is not a recognised field. Allowed fields: "
                    + allowedDescription
                    + ".",
                path: path + [key]
            )
        }
        return nil
    }

    private func validateProperties(
        properties: [String: JSONSchemaValue],
        propertySchemas: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        // Iterate schema keys in sorted order for deterministic test output.
        for field in propertySchemas.keys.sorted() {
            guard let subSchema = propertySchemas[field] else { continue }
            guard let childValue = properties[field] else { continue }
            if let failure = validate(value: childValue, schema: subSchema, path: path + [field]) {
                return failure
            }
        }
        return nil
    }

    /// Extract a numeric constraint value from a `JSONSchemaValue`, handling
    /// both `.number` (produced by `lift()` from Foundation JSON) and `.integer`
    /// (produced by `JSONDecoder` when the literal is a whole number, since
    /// `JSONSchemaValue.init(from:)` tries `Int64` before `Double`).
    private func numericConstraint(_ v: JSONSchemaValue?) -> Double? {
        switch v {
        case .number(let n): return n
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    private func validateArray(
        items: [JSONSchemaValue],
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        if let n = numericConstraint(schemaObject["minItems"]) {
            let bound = Int(n)
            if items.count < bound {
                return ValidationFailure(
                    modelReadableMessage: "argument \(Self.describePath(path)) must contain at least \(bound) items. Got \(items.count).",
                    path: path
                )
            }
        }
        if let n = numericConstraint(schemaObject["maxItems"]) {
            let bound = Int(n)
            if items.count > bound {
                return ValidationFailure(
                    modelReadableMessage: "argument \(Self.describePath(path)) must contain at most \(bound) items. Got \(items.count).",
                    path: path
                )
            }
        }
        if let itemsSchema = schemaObject["items"] {
            for (index, element) in items.enumerated() {
                if let failure = validate(
                    value: element,
                    schema: itemsSchema,
                    path: path + ["[\(index)]"]
                ) {
                    return failure
                }
            }
        }
        return nil
    }

    private func validateString(
        value: String,
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        // Count Unicode scalars rather than UTF-16 code units so "é" counts as 1.
        let length = value.unicodeScalars.count
        if let n = numericConstraint(schemaObject["minLength"]) {
            let bound = Int(n)
            if length < bound {
                return ValidationFailure(
                    modelReadableMessage: "argument \(Self.describePath(path)) must be at least \(bound) characters. Got \(length).",
                    path: path
                )
            }
        }
        if let n = numericConstraint(schemaObject["maxLength"]) {
            let bound = Int(n)
            if length > bound {
                return ValidationFailure(
                    modelReadableMessage: "argument \(Self.describePath(path)) must be at most \(bound) characters. Got \(length).",
                    path: path
                )
            }
        }
        return nil
    }

    private func validateNumber(
        value: Double,
        schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        if let n = numericConstraint(schemaObject["minimum"]) {
            if value < n {
                return ValidationFailure(
                    modelReadableMessage: "argument \(Self.describePath(path)) must be >= \(Self.describeNumber(n)). Got \(Self.describeNumber(value)).",
                    path: path
                )
            }
        }
        if let n = numericConstraint(schemaObject["maximum"]) {
            if value > n {
                return ValidationFailure(
                    modelReadableMessage: "argument \(Self.describePath(path)) must be <= \(Self.describeNumber(n)). Got \(Self.describeNumber(value)).",
                    path: path
                )
            }
        }
        return nil
    }

    // MARK: - Fail-closed on unsupported keywords

    /// Keywords the validator refuses to evaluate. Present here means: bail out
    /// with a clear error rather than silently declaring the value valid.
    private static let unsupportedKeywords: [String] = [
        "anyOf", "oneOf", "allOf", "not",
        "$ref", "$defs", "definitions",
        "patternProperties", "propertyNames", "dependentRequired",
        "format", "pattern",
    ]

    private func rejectUnsupportedKeywords(
        _ schemaObject: [String: JSONSchemaValue],
        path: [String]
    ) -> ValidationFailure? {
        for key in Self.unsupportedKeywords where schemaObject[key] != nil {
            return ValidationFailure(
                modelReadableMessage: "unsupported schema feature '\(key)' — the tool-argument validator cannot evaluate this schema. See JSONSchemaValidator docs for the supported subset.",
                path: path
            )
        }
        return nil
    }

    // MARK: - Formatting helpers

    private static func describePath(_ path: [String]) -> String {
        if path.isEmpty { return "(root)" }
        // Join so it reads naturally in a message: "'location.city'".
        return "'" + path.joined(separator: ".") + "'"
    }

    private static func describeValue(_ value: JSONSchemaValue) -> String {
        switch value {
        case .string(let s):
            return "'\(s)'"
        case .number(let n):
            return describeNumber(n)
        case .integer(let i):
            return String(i)
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .array:
            return "an array"
        case .object:
            return "an object"
        }
    }

    private static func describeActualType(_ value: JSONSchemaValue) -> String {
        switch value {
        case .string:  return "string"
        case .number:  return "number"
        case .integer: return "integer"
        case .bool:    return "boolean"
        case .null:   return "null"
        case .array:  return "array"
        case .object: return "object"
        }
    }

    private static func describeEnum(_ allowed: [JSONSchemaValue]) -> String {
        allowed.map { Self.describeEnumMember($0) }.joined(separator: ", ")
    }

    private static func describeEnumMember(_ value: JSONSchemaValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return describeNumber(n)
        case .bool(let b):   return b ? "true" : "false"
        case .null:          return "null"
        default:             return describeValue(value)
        }
    }

    private static func describeNumber(_ n: Double) -> String {
        if n.rounded() == n && n.isFinite && abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    }

    private static func typeName(of value: JSONSchemaValue) -> String {
        describeActualType(value)
    }

    private static func concise(_ error: Error) -> String {
        let text = String(describing: error)
        // `JSONSerialization` errors tend to be verbose and unhelpful for a
        // language model. Keep only the first line.
        if let firstLine = text.split(separator: "\n").first {
            return String(firstLine)
        }
        return text
    }

    // MARK: - Protocol bridge

    // `JSONSchemaValidating` lives in `ToolRegistry.swift` to keep the
    // registry's dependency surface minimal. The concrete validator opts into
    // that protocol here by adapting its richer `ValidationFailure?` return
    // shape to the protocol's `String?` contract. Consumers of
    // `ToolRegistry.validator` only see the stringified message; call sites
    // that need the structured path can still use the concrete type directly.
    //
    // Kept adjacent to `lift`/the main type so the file reads top-to-bottom
    // without needing to jump to a separate bridge file.

    // MARK: - Foundation JSON -> JSONSchemaValue bridge

    /// Convert the `Any` graph returned by `JSONSerialization.jsonObject` into
    /// our `JSONSchemaValue` tree. Exposed as `internal` so the test suite can
    /// exercise it directly if needed — keep `private` to callers.
    static func lift(_ any: Any) -> JSONSchemaValue {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            // Distinguish Bool from numeric. `NSNumber` boxes Bool as a CFBoolean
            // whose objCType is "c" (char). Checking `CFGetTypeID` is the
            // canonical way to tell them apart across platforms.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map(lift)) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONSchemaValue] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = lift(v) }
            return .object(out)
        }
        // Unknown Foundation type — represent as null so the validator reports
        // a clean type mismatch rather than crashing on an unexpected kind.
        return .null
    }
}

// MARK: - JSONSchemaValidating conformance

/// Adapts `JSONSchemaValidator` to the protocol `ToolRegistry` depends on.
///
/// The protocol shape (`String?`) flattens a successful validation to `nil`
/// and flattens a failure to its model-readable message; the structural path
/// is discarded at this boundary because the registry feeds the message back
/// to the model verbatim and has no use for pointer-style paths.
extension JSONSchemaValidator: JSONSchemaValidating {

    public func validateAgainst(_ schema: JSONSchemaValue, value: JSONSchemaValue) -> String? {
        let failure: ValidationFailure? = validate(value, against: schema)
        return failure?.modelReadableMessage
    }
}
