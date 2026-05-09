import Foundation
import ManifoldInference

// MARK: - IntentEnumParameter

/// Marker protocol enums adopt so the schema builder can enumerate their cases.
///
/// AppIntents' `@Parameter` works with any `AppEnum`, but Swift's runtime
/// reflection cannot enumerate enum cases generically — `Mirror` only sees the
/// case currently inhabited by an instance. Adopt this protocol on enums you
/// expose as parameters; the builder uses `allCases` to populate
/// `enum: [...]` in the generated JSON Schema.
///
/// ```swift
/// enum Priority: String, IntentEnumParameter {
///     case low, medium, high
/// }
/// ```
///
/// Conformance is intentionally cheap: most `AppEnum` types already conform to
/// `CaseIterable & RawRepresentable where RawValue == String`, which is all
/// this protocol requires.
public protocol IntentEnumParameter: CaseIterable, RawRepresentable, Sendable where RawValue == String {}

// MARK: - JSONSchemaBuilder

/// Synthesises a JSON-Schema document from an AppIntent type's `@Parameter`
/// metadata.
///
/// ## How it works
///
/// AppIntent property wrappers (`IntentParameter<T>`) are stored properties on
/// the intent struct. We instantiate the intent (every `AppIntent` requires
/// `init()`) and walk its `Mirror`. Each child whose value is an
/// `IntentParameter<T>` becomes one schema property — derived from the wrapped
/// type `T`.
///
/// The builder maps the following Swift types:
///
/// | Swift type            | JSON Schema           |
/// |-----------------------|-----------------------|
/// | `String`              | `"type": "string"`    |
/// | `Int`, `Int32`, `Int64` | `"type": "integer"` |
/// | `Double`, `Float`, `CGFloat` | `"type": "number"` |
/// | `Bool`                | `"type": "boolean"`   |
/// | `Date`                | `"type": "string", "format": "date-time"` |
/// | `URL`                 | `"type": "string", "format": "uri"`        |
/// | `T: IntentEnumParameter` | `"type": "string", "enum": [...]`       |
/// | `Optional<T>`         | (recurses into `T`; field becomes non-required) |
///
/// Unknown types fall back to `"type": "string"` so the schema is still valid.
///
/// The leading `_` underscore SwiftUI-style mirror property names get stripped
/// so the JSON parameter name matches the intent's declared property name.
enum JSONSchemaBuilder {

    /// Builds a JSON-Schema object describing `Intent`'s `@Parameter` properties.
    static func schema<Intent: Sendable>(for intentType: Intent.Type, makeInstance: () -> Intent) -> JSONSchemaValue {
        let instance = makeInstance()
        let mirror = Mirror(reflecting: instance)

        var properties: [String: JSONSchemaValue] = [:]
        var required: [String] = []
        // Preserve declaration order so generated schemas are stable across
        // builds — JSON-Schema doesn't mandate ordering, but stable output
        // keeps test fixtures and snapshots deterministic.
        var orderedNames: [String] = []

        for child in mirror.children {
            guard let label = child.label else { continue }
            // Only publish properties that are actually `@Parameter`-wrapped.
            // Plain stored properties (caches, computed-but-stored helpers,
            // future AppIntents framework storage) would otherwise leak into
            // the schema as phantom tool arguments. We gate on the
            // `IntentParameter<...>` type-name shape — which is exactly what
            // `wrappedTypeName(from:)` is built to detect.
            let typeName = String(reflecting: type(of: child.value))
            guard wrappedTypeName(from: typeName) != nil else { continue }

            // SwiftUI/AppIntents property wrappers expose the underlying
            // storage with a leading underscore in the mirror — strip it so
            // the schema property matches the intent's declared name.
            let name = label.hasPrefix("_") ? String(label.dropFirst()) : label

            let (typeSchema, isOptional) = describe(child.value)
            properties[name] = typeSchema
            orderedNames.append(name)
            if !isOptional {
                required.append(name)
            }
        }

        var object: [String: JSONSchemaValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            // Reorder required to match declaration order — this is purely
            // cosmetic but keeps generated schemas readable.
            let orderedRequired = orderedNames.filter { required.contains($0) }
            object["required"] = .array(orderedRequired.map { .string($0) })
        }
        return .object(object)
    }

    /// Returns the schema fragment for one mirror child plus whether the
    /// underlying parameter is optional (which controls the `required` list).
    private static func describe(_ value: Any) -> (schema: JSONSchemaValue, isOptional: Bool) {
        // The mirror child for an `@Parameter`-wrapped property is the
        // property-wrapper struct itself (`IntentParameter<T>`), not the
        // wrapped `T`. We dive one level into its mirror to find the storage.
        // Most wrapper implementations expose the wrapped value as their
        // single relevant child; if not, we still get a usable type-name
        // string from `type(of:)` and parse the generic parameter out.
        let typeName = String(reflecting: type(of: value))
        let inner = wrappedTypeName(from: typeName) ?? typeName
        let (schema, isOptional) = mapTypeName(inner, original: value)
        return (schema, isOptional)
    }

    /// Pulls the inner type out of an `IntentParameter<T>` type name so we can
    /// reason about `T` even when reflection on the wrapper itself doesn't
    /// expose the wrapped value.
    ///
    /// Falls back to `nil` for non-`IntentParameter` cases so the caller uses
    /// the original type name directly.
    private static func wrappedTypeName(from typeName: String) -> String? {
        // Examples we want to handle:
        //   AppIntents.IntentParameter<Swift.String>
        //   AppIntents.IntentParameter<Swift.Optional<Swift.Int>>
        //   AppIntents.IntentParameter<MyApp.Priority>
        guard let openIdx = typeName.firstIndex(of: "<"),
              typeName.last == ">",
              typeName.contains("IntentParameter")
        else {
            return nil
        }
        let after = typeName.index(after: openIdx)
        let beforeClose = typeName.index(before: typeName.endIndex)
        return String(typeName[after..<beforeClose])
    }

    /// Maps a fully-qualified Swift type name (e.g. `Swift.Optional<Swift.Int>`)
    /// onto a JSON-Schema fragment. The `original` value is used to look up
    /// `IntentEnumParameter` cases when the type is enum-shaped.
    private static func mapTypeName(_ typeName: String, original: Any) -> (JSONSchemaValue, isOptional: Bool) {
        // Optional unwrap — strip `Swift.Optional<…>` and recurse on the inner
        // type. Anything wrapped in `Optional` becomes non-required in the
        // generated schema.
        if let inner = unwrapOptional(typeName) {
            let (schema, _) = mapTypeName(inner, original: original)
            return (schema, true)
        }

        switch typeName {
        case "Swift.String", "String":
            return (.object(["type": .string("string")]), false)
        case "Swift.Int", "Int", "Swift.Int32", "Int32", "Swift.Int64", "Int64":
            return (.object(["type": .string("integer")]), false)
        case "Swift.Double", "Double", "Swift.Float", "Float", "CoreGraphics.CGFloat", "CGFloat":
            return (.object(["type": .string("number")]), false)
        case "Swift.Bool", "Bool":
            return (.object(["type": .string("boolean")]), false)
        case "Foundation.Date", "Date":
            return (.object([
                "type": .string("string"),
                "format": .string("date-time"),
            ]), false)
        case "Foundation.URL", "URL":
            return (.object([
                "type": .string("string"),
                "format": .string("uri"),
            ]), false)
        default:
            // Enum support: enumerate cases via the IntentEnumParameter
            // protocol. We have to look the type up at runtime because the
            // mirror only sees the wrapper, not the underlying enum value
            // (which may not even be initialised yet).
            if let cases = enumCases(forTypeName: typeName) {
                return (.object([
                    "type": .string("string"),
                    "enum": .array(cases.map { .string($0) }),
                ]), false)
            }
            // Fall back to string for unknown types — the schema is still
            // valid, the model can attempt a string, and the executor will
            // surface a decode error if the conversion fails.
            return (.object(["type": .string("string")]), false)
        }
    }

    /// `Swift.Optional<X>` → `X`, otherwise `nil`.
    private static func unwrapOptional(_ typeName: String) -> String? {
        let prefixes = ["Swift.Optional<", "Optional<"]
        for prefix in prefixes where typeName.hasPrefix(prefix) && typeName.last == ">" {
            return String(typeName.dropFirst(prefix.count).dropLast())
        }
        return nil
    }

    /// Looks up an `IntentEnumParameter` type by its fully-qualified name and
    /// returns its raw-value cases, or `nil` if no matching type is registered.
    private static func enumCases(forTypeName typeName: String) -> [String]? {
        // `_typeByName(_:)` is the stdlib's mangled-name → metatype lookup.
        // It resolves first-class types reachable in the running process, which
        // covers app-module enums adopting `IntentEnumParameter`. If lookup
        // fails, the caller falls back to a plain `string` schema.
        guard let any = _typeByName(typeName) else { return nil }
        guard let enumType = any as? any IntentEnumParameter.Type else { return nil }
        return enumType.allCaseRawValues
    }
}

// MARK: - IntentEnumParameter helpers

extension IntentEnumParameter {
    /// Returns every case's raw string value in declaration order.
    static var allCaseRawValues: [String] {
        Self.allCases.map { $0.rawValue }
    }
}

// `_typeByName(_:)` is the stdlib's underscored mangled-name → metatype
// lookup. It's been part of the standard library since Swift 5.3 and is
// callable directly without a shim — we use it inside `enumCases` to resolve
// `IntentEnumParameter`-conforming types found by reflecting on parameter
// wrappers. No declaration is needed here; the call site relies on the
// implicit `Swift._typeByName` symbol.
