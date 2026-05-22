import Foundation
import ManifoldInference

#if canImport(AppIntents)
import AppIntents
#endif

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
            // Decorate the property schema with title- and default-derived
            // hints sourced from the wrapper's mirror. Done after `describe`
            // so the inner type-mapping path stays focused on the shape and
            // optionality of the wrapped value.
            let decorated = decorate(typeSchema, wrapper: child.value)
            properties[name] = decorated
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

        // Collection unwrap — `[T]` / `Set<T>` become `array` schemas whose
        // `items` describe the element type. Recursion handles nested
        // collections and `Optional<[T]>` (the outer `unwrapOptional` strips
        // the optional first; we land here for the inner array shape).
        if let element = unwrapCollection(typeName) {
            let (itemsSchema, _) = mapTypeName(element, original: original)
            return (.object([
                "type": .string("array"),
                "items": itemsSchema,
            ]), false)
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

    /// `Swift.Array<X>` / `Array<X>` / `Swift.Set<X>` / `Set<X>` → `X`,
    /// otherwise `nil`. Matches the optional-unwrap pattern intentionally so
    /// both shapes peel one layer at a time and the caller can recurse.
    private static func unwrapCollection(_ typeName: String) -> String? {
        let prefixes = [
            "Swift.Array<", "Array<",
            "Swift.Set<", "Set<",
        ]
        for prefix in prefixes where typeName.hasPrefix(prefix) && typeName.last == ">" {
            return String(typeName.dropFirst(prefix.count).dropLast())
        }
        return nil
    }

    /// Merges title/default hints from the `IntentParameter<T>` wrapper into
    /// the per-property schema fragment produced by `mapTypeName`.
    ///
    /// `title` is emitted as the JSON-Schema `description` because that's the
    /// field model contexts reliably read. The `@Parameter(description:)`
    /// argument is intentionally not used: the AppIntents framework does not
    /// surface it through reflection on the wrapper (only `title` is exposed
    /// as a `LocalizedStringResource` child). If a host needs richer copy,
    /// pass it via `@Parameter(title:)` instead.
    ///
    /// `defaultValue` is emitted as JSON-Schema `default` when the wrapper
    /// carries one. Encoding uses the same ISO-8601 date strategy as
    /// `AppIntentToolExecutor.execute(arguments:)` so a `Date` default
    /// round-trips through the same shape the executor decodes.
    ///
    /// If reflection can't surface a usable hint, the corresponding field is
    /// omitted rather than synthesised — an empty `description` or a guessed
    /// `default` is worse signal than no field at all.
    private static func decorate(_ schema: JSONSchemaValue, wrapper: Any) -> JSONSchemaValue {
        guard case .object(var fields) = schema else { return schema }

        let mirror = Mirror(reflecting: wrapper)
        for child in mirror.children {
            switch child.label {
            case "title":
                if let description = renderTitle(child.value), !description.isEmpty {
                    fields["description"] = .string(description)
                }
            case "defaultValue":
                if let json = encodeDefault(child.value) {
                    fields["default"] = json
                }
            default:
                continue
            }
        }
        return .object(fields)
    }

    /// Renders an AppIntents `LocalizedStringResource` to a plain `String`
    /// for inclusion in the schema. Returns `nil` if the wrapper hasn't been
    /// initialised with a title (which would only happen if the property
    /// wrapper is reconstructed via a path that bypasses `@Parameter(title:)`
    /// — defensive in case future AppIntents changes alter the layout).
    private static func renderTitle(_ value: Any) -> String? {
        #if canImport(AppIntents)
        if #available(iOS 26, macOS 26, *), let lsr = value as? LocalizedStringResource {
            return String(localized: lsr)
        }
        #endif
        return nil
    }

    /// Encodes a wrapper's `defaultValue` storage as a `JSONSchemaValue` so
    /// it can be embedded in the schema as a `default` field. `defaultValue`
    /// is always `Optional<T>` in the wrapper's storage — we unwrap, encode
    /// with the executor's ISO-8601 date strategy, and re-decode into the
    /// schema value type. Returns `nil` when the wrapper has no default or
    /// when the value isn't `Encodable` (in which case guessing would
    /// produce a wrong signal).
    private static func encodeDefault(_ value: Any) -> JSONSchemaValue? {
        // The `defaultValue` child is always `Optional<T>`. Mirror it once to
        // distinguish "no default set" (`.none`) from "default is nil"
        // (`.some(nil)` — not legal for AppIntents but cheap to handle).
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let unwrapped = mirror.children.first?.value else { return nil }
            return encodeConcreteDefault(unwrapped)
        }
        return encodeConcreteDefault(value)
    }

    private static func encodeConcreteDefault(_ value: Any) -> JSONSchemaValue? {
        guard let encodable = value as? any Encodable else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(_EncodableBox(encodable))
            let decoder = JSONDecoder()
            return try decoder.decode(JSONSchemaValue.self, from: data)
        } catch {
            // A default that doesn't round-trip through JSON has no useful
            // representation in the schema. Drop it rather than guessing.
            return nil
        }
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

/// Local type-erased `Encodable` box used by `encodeConcreteDefault` so we
/// can call `JSONEncoder().encode(...)` on a value whose concrete type is
/// only known dynamically. Mirrors `AppIntentToolExecutor.EncodableBox` —
/// duplicated rather than shared to keep the schema builder free of
/// executor-internal symbols.
private struct _EncodableBox: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

// `_typeByName(_:)` is the stdlib's underscored mangled-name → metatype
// lookup. It's been part of the standard library since Swift 5.3 and is
// callable directly without a shim — we use it inside `enumCases` to resolve
// `IntentEnumParameter`-conforming types found by reflecting on parameter
// wrappers. No declaration is needed here; the call site relies on the
// implicit `Swift._typeByName` symbol.
