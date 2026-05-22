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

    /// Result of analysing an intent's `@Parameter` metadata.
    ///
    /// Bundles the JSON-Schema document and the list of parameters whose
    /// wrapped type is an `AppEntity`. The executor consults the entity map to
    /// pre-resolve identifier-only argument payloads before handing them to
    /// `JSONDecoder` — `AppEntity` isn't generically `Decodable` and the host
    /// intent's `init(from:)` reads the resolved value via the decoder's
    /// `userInfo` rather than trying to decode the entity itself.
    struct IntentAnalysis {
        let schema: JSONSchemaValue
        /// Parameter name → `AppEntity` metatype (only populated when the
        /// AppIntents framework is importable and `_typeByName` resolves).
        let entityParameters: [String: Any.Type]
    }

    /// Builds a JSON-Schema object describing `Intent`'s `@Parameter` properties.
    static func schema<Intent: Sendable>(for intentType: Intent.Type, makeInstance: () -> Intent) -> JSONSchemaValue {
        analyze(for: intentType, makeInstance: makeInstance).schema
    }

    /// Walks the intent's mirror and returns both the schema and the entity-
    /// parameter map. Existing call sites that only need the schema use the
    /// `schema(for:)` overload above; the executor uses this richer form.
    static func analyze<Intent: Sendable>(
        for intentType: Intent.Type,
        makeInstance: () -> Intent
    ) -> IntentAnalysis {
        let instance = makeInstance()
        let mirror = Mirror(reflecting: instance)

        var properties: [String: JSONSchemaValue] = [:]
        var required: [String] = []
        var entityParameters: [String: Any.Type] = [:]
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

            let (typeSchema, isOptional, entityType) = describe(child.value)
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
            if let entityType {
                entityParameters[name] = entityType
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
        return IntentAnalysis(schema: .object(object), entityParameters: entityParameters)
    }

    /// Returns the schema fragment for one mirror child plus whether the
    /// underlying parameter is optional (which controls the `required` list)
    /// and the resolved `AppEntity` metatype when the wrapped type is one.
    private static func describe(_ value: Any) -> (schema: JSONSchemaValue, isOptional: Bool, entityType: Any.Type?) {
        // The mirror child for an `@Parameter`-wrapped property is the
        // property-wrapper struct itself (`IntentParameter<T>`), not the
        // wrapped `T`. We dive one level into its mirror to find the storage.
        // Most wrapper implementations expose the wrapped value as their
        // single relevant child; if not, we still get a usable type-name
        // string from `type(of:)` and parse the generic parameter out.
        let typeName = String(reflecting: type(of: value))
        let inner = wrappedTypeName(from: typeName) ?? typeName
        // Best-effort: extract the wrapped metatype from the live wrapper so
        // we can identify `AppEntity` / `IntentEnumParameter` types without
        // round-tripping through `_typeByName` (which fails for test-module
        // and bundle-loaded types whose mangled symbols don't match the
        // demangled `Module.Name` form). The mangled-symbol fallback in
        // ``resolveTypeByName`` covers the remaining cases.
        let wrappedType = wrappedMetatype(from: value)
        return mapTypeName(inner, original: value, wrappedType: wrappedType)
    }

    /// Pulls the wrapped value's metatype out of an `IntentParameter<T>` via
    /// `Mirror`. The wrapper stores its current value as a child; reading its
    /// `subjectType` gives us `T` directly — no mangled-name lookup needed.
    /// Falls back to `nil` for shapes the wrapper doesn't expose; the caller
    /// then routes through name-based lookup.
    private static func wrappedMetatype(from wrapper: Any) -> Any.Type? {
        // Read the wrapper's `defaultValue` child — its declared type is
        // `Optional<T>` where `T` is the wrapped parameter type. The instance
        // is usually `.none` (parameters have no value yet at schema time), so
        // we extract `T` from the Optional's *static* generic argument via
        // `_typeByName(_:)` on the mangled inner. We pull that mangled name
        // from the runtime metadata of the Optional metatype.
        let mirror = Mirror(reflecting: wrapper)
        for child in mirror.children where child.label == "defaultValue" {
            // `type(of: child.value)` is `Optional<T>` regardless of whether
            // the value is `.some` or `.none` — read the static type, not the
            // instance. Then unwrap one level of Optional via its mangled
            // name and resolve the inner.
            let optionalType = type(of: child.value)
            if let wrappedType = optionalWrappedMetatype(optionalType) {
                return wrappedType
            }
        }
        return nil
    }

    /// Given an `Optional<T>` metatype, returns `T.self` or `nil` for non-
    /// Optional inputs. Uses `_mangledTypeName` to inspect the metadata, which
    /// avoids the brittle demangled-name path entirely.
    private static func optionalWrappedMetatype(_ metatype: Any.Type) -> Any.Type? {
        // Mangled symbol for `Swift.Optional<X>` is `<inner>Sg`; strip the
        // `Sg` suffix and ask the runtime to resolve the remainder. This
        // works regardless of `X`'s defining module because the runtime has
        // first-class metadata for it (we're holding it right here).
        guard let mangled = _mangledTypeName(metatype) else { return nil }
        guard mangled.hasSuffix("Sg") else { return nil }
        let inner = String(mangled.dropLast(2))
        return _typeByName(inner)
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
    /// `IntentEnumParameter` cases when the type is enum-shaped. The third
    /// tuple member is the resolved `AppEntity` metatype when the parameter is
    /// entity-shaped (the executor uses it to pre-resolve the id payload).
    private static func mapTypeName(_ typeName: String, original: Any, wrappedType: Any.Type? = nil) -> (JSONSchemaValue, isOptional: Bool, entityType: Any.Type?) {
        // Optional unwrap — strip `Swift.Optional<…>` and recurse on the inner
        // type. Anything wrapped in `Optional` becomes non-required in the
        // generated schema.
        if let inner = unwrapOptional(typeName) {
            let (schema, _, entityType) = mapTypeName(inner, original: original, wrappedType: wrappedType)
            return (schema, true, entityType)
        }

        // Collection unwrap — `[T]` / `Set<T>` become `array` schemas whose
        // `items` describe the element type. Recursion handles nested
        // collections and `Optional<[T]>` (the outer `unwrapOptional` strips
        // the optional first; we land here for the inner array shape).
        if let element = unwrapCollection(typeName) {
            let (itemsSchema, _, _) = mapTypeName(element, original: original)
            return (.object([
                "type": .string("array"),
                "items": itemsSchema,
            ]), false, nil)
        }

        switch typeName {
        case "Swift.String", "String":
            return (.object(["type": .string("string")]), false, nil)
        case "Swift.Int", "Int", "Swift.Int32", "Int32", "Swift.Int64", "Int64":
            return (.object(["type": .string("integer")]), false, nil)
        case "Swift.Double", "Double", "Swift.Float", "Float", "CoreGraphics.CGFloat", "CGFloat":
            return (.object(["type": .string("number")]), false, nil)
        case "Swift.Bool", "Bool":
            return (.object(["type": .string("boolean")]), false, nil)
        case "Foundation.Date", "Date":
            return (.object([
                "type": .string("string"),
                "format": .string("date-time"),
            ]), false, nil)
        case "Foundation.URL", "URL":
            return (.object([
                "type": .string("string"),
                "format": .string("uri"),
            ]), false, nil)
        default:
            // Enum support: enumerate cases via the IntentEnumParameter
            // protocol. Prefer the live wrapped metatype if reflection
            // exposed one — this avoids the brittle mangled-name lookup
            // entirely when the wrapper has a current value to inspect.
            if let cases = enumCases(wrappedType: wrappedType) ?? enumCases(forTypeName: typeName) {
                return (.object([
                    "type": .string("string"),
                    "enum": .array(cases.map { .string($0) }),
                ]), false, nil)
            }
            #if canImport(AppIntents)
            // AppEntity support: emit an id-only object schema and capture the
            // metatype so the executor can pre-resolve the identifier into a
            // real instance before decode. Live wrapped metatype is preferred
            // for the same reasons as the enum path above.
            if let (entityType, idKind) = appEntityMetadata(wrappedType: wrappedType)
                ?? appEntityMetadata(forTypeName: typeName) {
                let shortName = shortTypeName(typeName)
                let idSchema: JSONSchemaValue = .object([
                    "type": .string(idKind.schemaTypeName),
                    "description": .string("\(shortName) identifier"),
                ])
                return (.object([
                    "type": .string("object"),
                    "properties": .object(["id": idSchema]),
                    "required": .array([.string("id")]),
                ]), false, entityType)
            }
            #endif
            // Fall back to string for unknown types — the schema is still
            // valid, the model can attempt a string, and the executor will
            // surface a decode error if the conversion fails.
            return (.object(["type": .string("string")]), false, nil)
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
    /// JSON-Schema id kinds we know how to advertise for `AppEntity.Identifier`.
    enum EntityIDKind {
        case string
        case integer

        var schemaTypeName: String {
            switch self {
            case .string: "string"
            case .integer: "integer"
            }
        }
    }

    /// Strips the module prefix off `Module.Type` so the schema description
    /// reads "Book identifier" instead of "MyApp.Book identifier".
    private static func shortTypeName(_ typeName: String) -> String {
        if let dot = typeName.lastIndex(of: ".") {
            return String(typeName[typeName.index(after: dot)...])
        }
        return typeName
    }

    #if canImport(AppIntents)
    /// Looks up an `AppEntity` type by its fully-qualified name and returns
    /// the metatype plus the id-kind. Returns `nil` for non-entity types so
    /// the caller can fall through to the next strategy.
    ///
    /// `_typeByName` is the same stdlib lookup used for `IntentEnumParameter`;
    /// it resolves any type with metadata reachable in the running process.
    /// We then test conformance to `any AppEntity.Type` to confirm.
    @available(iOS 26, macOS 26, *)
    private static func resolveAppEntityType(_ typeName: String) -> (any AppEntity.Type)? {
        guard let any = resolveTypeByName(typeName) else { return nil }
        return any as? any AppEntity.Type
    }

    /// Probes the entity's `ID` associated type to choose between integer and
    /// string id schemas. Anything that isn't a known integer type degrades to
    /// `string`, matching the documented contract.
    @available(iOS 26, macOS 26, *)
    private static func idKind(for entityType: any AppEntity.Type) -> EntityIDKind {
        // Open the existential so we can inspect the concrete `ID` associated
        // type. `(any AppEntity.Type).ID` doesn't compile directly (Swift's
        // type-checker rejects member-access on a protocol metatype's
        // associated type), but a generic helper opens the existential.
        idKindGeneric(entityType)
    }

    @available(iOS 26, macOS 26, *)
    private static func idKindGeneric<E: AppEntity>(_ : E.Type) -> EntityIDKind {
        let name = String(reflecting: E.ID.self)
        // String identity covers Int, Int32, Int64, UInt, UInt32, UInt64 —
        // the integer family any reasonable AppEntity might use. Floats are
        // excluded by design: AppEntity identifiers must be hashable & stable.
        switch name {
        case "Swift.Int", "Swift.Int32", "Swift.Int64",
             "Swift.UInt", "Swift.UInt32", "Swift.UInt64":
            return .integer
        default:
            return .string
        }
    }

    /// Combined metadata lookup the schema builder consumes.
    private static func appEntityMetadata(forTypeName typeName: String) -> (Any.Type, EntityIDKind)? {
        if #available(iOS 26, macOS 26, *) {
            guard let entityType = resolveAppEntityType(typeName) else { return nil }
            return (entityType, idKind(for: entityType))
        }
        return nil
    }

    /// Live-metatype overload: when reflection on the wrapper produced a
    /// concrete `T` already, avoid the brittle name-based round-trip.
    private static func appEntityMetadata(wrappedType: Any.Type?) -> (Any.Type, EntityIDKind)? {
        guard let wrappedType else { return nil }
        if #available(iOS 26, macOS 26, *) {
            guard let entityType = wrappedType as? any AppEntity.Type else { return nil }
            return (entityType, idKind(for: entityType))
        }
        return nil
    }
    #endif

    /// Looks up an `IntentEnumParameter` type by its fully-qualified name and
    /// returns its raw-value cases, or `nil` if no matching type is registered.
    /// Live-metatype overload — same idea as ``appEntityMetadata(wrappedType:)``.
    private static func enumCases(wrappedType: Any.Type?) -> [String]? {
        guard let wrappedType else { return nil }
        guard let enumType = wrappedType as? any IntentEnumParameter.Type else { return nil }
        return enumType.allCaseRawValues
    }

    private static func enumCases(forTypeName typeName: String) -> [String]? {
        guard let any = resolveTypeByName(typeName) else { return nil }
        guard let enumType = any as? any IntentEnumParameter.Type else { return nil }
        return enumType.allCaseRawValues
    }

    /// Resolves a fully-qualified Swift type name into its metatype.
    ///
    /// `_typeByName` accepts a mangled symbol by default; the demangled form
    /// `"Module.Type"` works for some types but fails on others depending on
    /// the symbol's mangling. We try the raw name first, then synthesise the
    /// mangled equivalent for top-level types (`<count><module><count><type>`)
    /// so the lookup succeeds for test-module types regardless of how the
    /// callee captured the name.
    static func resolveTypeByName(_ typeName: String) -> Any.Type? {
        if let direct = _typeByName(typeName) {
            return direct
        }
        // Build a Swift mangled name for `Module.TypeName`. Swift's runtime
        // accepts the substitution-free mangled form for top-level nominal
        // types: `<moduleLen><module><typeLen><type>` + the nominal kind
        // suffix (`C` = class, `V` = struct, `O` = enum). We try each suffix.
        let components = typeName.split(separator: ".").map(String.init)
        guard components.count == 2 else { return nil }
        let module = components[0]
        let type = components[1]
        let prefix = "$s\(module.count)\(module)\(type.count)\(type)"
        for suffix in ["O", "V", "C"] {
            if let resolved = _typeByName(prefix + suffix) {
                return resolved
            }
        }
        return nil
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
