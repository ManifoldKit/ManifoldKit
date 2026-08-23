#if Macros
import Foundation
import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - ToolSchemaMacro

/// Implementation of `@ToolSchema` — a `MemberMacro` that synthesises a
/// `static var jsonSchema: JSONSchemaValue` property on a `Decodable` struct
/// by reflecting the syntax of its stored properties.
///
/// The user-facing attribute declaration lives in `ManifoldInference` so it
/// is available wherever `JSONSchemaValue` is in scope. This file contains
/// only the compiler-plugin implementation.
///
/// Because macros see **syntax only** (not semantic type info), field-type
/// mapping is done by matching the textual `TypeSyntax`:
///
/// - `String`            -> `{"type": "string"}`
/// - `Int` / `Int32` / `Int64` -> `{"type": "integer"}`
/// - `Double` / `Float`  -> `{"type": "number"}`
/// - `Bool`              -> `{"type": "boolean"}`
/// - `[T]` / `Array<T>`  -> `{"type": "array", "items": <T schema>}`
/// - `T?` / `Optional<T>` -> same as `T` but the field is **not** in `required`
/// - Anything else -> referenced as `<T>.jsonSchema`. At callsite this resolves
///   either to a nested `@ToolSchema` struct's synthesised property or to a
///   manual `static var jsonSchema: JSONSchemaValue` conformance (e.g. a
///   `String`-raw-type enum whose owner wrote `static var jsonSchema` by hand).
///
/// Default values become `"default": <literal>` (literal passed through as a
/// string/number/bool; more complex exprs are best-effort).
///
/// Doc comments (`///` lines immediately above a field) become `"description"`.
///
/// ## Limits (compile-time diagnostics)
/// - No `anyOf` / union types
/// - No constrained strings (no regex patterns)
/// - No nullable unions
/// - Tuples, closures, and `Any`-typed fields emit an error diagnostic.
public struct ToolSchemaMacro: MemberMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // `@ToolSchema` only synthesises members. Protocol conformances are
        // deliberately owned by the declaration the host app writes.
        _ = protocols

        // Support applying to an enum (to synthesise `{type: string, enum: [...]}`
        // from a String-raw-type CaseIterable enum).
        if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            return try expansionForEnum(enumDecl, attribute: node, context: context)
        }

        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            let diag = Diagnostic(
                node: Syntax(node),
                message: ToolSchemaDiagnostic.notAStructOrEnum
            )
            context.diagnose(diag)
            return []
        }

        // Collect stored properties as (name, type, default, description, isOptional).
        let fields: [FieldInfo] = structDecl.memberBlock.members.compactMap { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { return nil }
            // Skip computed properties (those with accessor blocks other than getters are
            // not stored; a single binding with no accessor is stored).
            guard variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else {
                return nil
            }
            // A binding with accessors other than `didSet`/`willSet` is computed — skip.
            if let accessor = binding.accessorBlock {
                switch accessor.accessors {
                case .getter:
                    return nil
                case .accessors(let list):
                    let hasGetter = list.contains { $0.accessorSpecifier.tokenKind == .keyword(.get) }
                    if hasGetter { return nil }
                }
            }
            // Skip `static` / `class` properties.
            let modifiers = variable.modifiers
            if modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }) {
                return nil
            }

            guard let typeAnnotation = binding.typeAnnotation?.type else {
                // No explicit type — macros can't infer. Skip; real compile error will follow.
                return nil
            }

            let name = pattern.identifier.text
            let defaultValue = binding.initializer?.value
            let description = Self.extractDocComment(from: variable.leadingTrivia)
            let (isOptional, innerType) = Self.unwrapOptional(typeAnnotation)

            return FieldInfo(
                name: name,
                type: innerType,
                isOptional: isOptional,
                defaultValue: defaultValue,
                description: description,
                sourceNode: Syntax(variable)
            )
        }

        // Build "properties" object: each key = field name, value = field schema.
        var propertyEntries: [String] = []
        var requiredNames: [String] = []
        for field in fields {
            let schemaExpr = Self.schemaExpression(
                for: field.type,
                description: field.description,
                defaultValue: field.defaultValue,
                fieldNode: field.sourceNode,
                context: context
            )
            propertyEntries.append("\"\(field.name)\": \(schemaExpr)")
            if !field.isOptional && field.defaultValue == nil {
                requiredNames.append(field.name)
            }
        }

        // Emit everything on a single logical line inside the `{ ... }` body.
        // Swift's macro framework reflows embedded newlines based on parent
        // indentation, which makes multi-line output unstable across call
        // sites (struct vs. extension, nested vs. top-level). A single line
        // yields a predictable source diff and identical output across
        // attachment sites.
        let propertiesBody = propertyEntries.isEmpty ? "[:]" : "[" + propertyEntries.joined(separator: ", ") + "]"
        let requiredArray: String
        if requiredNames.isEmpty {
            // JSON Schema treats a missing `required` as "no required fields",
            // which is what we want when every property is optional/has a
            // default — no need to emit an empty array.
            requiredArray = ""
        } else {
            let elems = requiredNames.map { "ManifoldInference.JSONSchemaValue.string(\"\($0)\")" }.joined(separator: ", ")
            requiredArray = ", \"required\": ManifoldInference.JSONSchemaValue.array([\(elems)])"
        }

        let body = "public static var jsonSchema: ManifoldInference.JSONSchemaValue { ManifoldInference.JSONSchemaValue.object([\"type\": ManifoldInference.JSONSchemaValue.string(\"object\"), \"properties\": ManifoldInference.JSONSchemaValue.object(\(propertiesBody))\(requiredArray)]) }"

        return [DeclSyntax(stringLiteral: body)]
    }

    // MARK: - Enum expansion

    static func expansionForEnum(
        _ enumDecl: EnumDeclSyntax,
        attribute: AttributeSyntax,
        context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Validate the enum inherits from String. We inspect the inheritance
        // clause textually — macros don't see semantic type resolution, but
        // `String` as the first-listed raw type is the conventional placement.
        var hasStringRawType = false
        if let inheritance = enumDecl.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                if let ident = inherited.type.as(IdentifierTypeSyntax.self), ident.name.text == "String" {
                    hasStringRawType = true
                    break
                }
            }
        }

        guard hasStringRawType else {
            context.diagnose(Diagnostic(
                node: Syntax(enumDecl),
                message: ToolSchemaDiagnostic.enumNotStringRawType
            ))
            return []
        }

        // Collect case names. For `case foo, bar` we emit `"foo"`, `"bar"` —
        // matching the raw value when no explicit raw value is given.
        // When an explicit `= "custom"` literal is set, we use that string.
        var cases: [String] = []
        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                if let rawValue = element.rawValue?.value.as(StringLiteralExprSyntax.self),
                   rawValue.segments.count == 1,
                   let seg = rawValue.segments.first?.as(StringSegmentSyntax.self) {
                    cases.append(seg.content.text)
                } else {
                    cases.append(element.name.text)
                }
            }
        }

        let enumArray = cases.map { "ManifoldInference.JSONSchemaValue.string(\"\($0)\")" }.joined(separator: ", ")
        // Single-line emission — see the struct path for rationale.
        let body = "public static var jsonSchema: ManifoldInference.JSONSchemaValue { ManifoldInference.JSONSchemaValue.object([\"type\": ManifoldInference.JSONSchemaValue.string(\"string\"), \"enum\": ManifoldInference.JSONSchemaValue.array([\(enumArray)])]) }"
        return [DeclSyntax(stringLiteral: body)]
    }

    // MARK: Helpers

    /// Unwraps one level of `Optional<T>` / `T?`.
    ///
    /// Returns `(isOptional, inner)`. We deliberately only peel a single layer —
    /// double-optional (`T??`) is pathological for JSON schemas and we leave the
    /// inner `T?` as-is so downstream schema building surfaces a diagnostic.
    static func unwrapOptional(_ type: TypeSyntax) -> (Bool, TypeSyntax) {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return (true, optional.wrappedType)
        }
        // swift-syntax 601+: `GenericArgumentSyntax.argument` is a
        // `GenericArgumentSyntax.Argument` enum (added for parameter packs), not a
        // bare `TypeSyntax` — extract the type case, falling through to the
        // "leave as-is" path when it isn't a plain type argument.
        if let identifier = type.as(IdentifierTypeSyntax.self),
           identifier.name.text == "Optional",
           let generic = identifier.genericArgumentClause,
           let first = generic.arguments.first,
           let innerType = first.argument.as(TypeSyntax.self) {
            return (true, innerType)
        }
        return (false, type)
    }

    /// Builds a Swift expression (as a string) that constructs a
    /// `JSONSchemaValue` for the given type. The expression is spliced into
    /// the `jsonSchema` property body.
    static func schemaExpression(
        for type: TypeSyntax,
        description: String?,
        defaultValue: ExprSyntax?,
        fieldNode: Syntax,
        context: some MacroExpansionContext
    ) -> String {

        // Reject tuples, closures, `Any`.
        if type.is(TupleTypeSyntax.self) {
            context.diagnose(Diagnostic(node: fieldNode, message: ToolSchemaDiagnostic.unsupportedType("tuple")))
            return "ManifoldInference.JSONSchemaValue.object([:])"
        }
        if type.is(FunctionTypeSyntax.self) {
            context.diagnose(Diagnostic(node: fieldNode, message: ToolSchemaDiagnostic.unsupportedType("closure")))
            return "ManifoldInference.JSONSchemaValue.object([:])"
        }
        if let ident = type.as(IdentifierTypeSyntax.self), ident.name.text == "Any" {
            context.diagnose(Diagnostic(node: fieldNode, message: ToolSchemaDiagnostic.unsupportedType("Any")))
            return "ManifoldInference.JSONSchemaValue.object([:])"
        }

        // Array: `[T]` or `Array<T>`.
        if let array = type.as(ArrayTypeSyntax.self) {
            let inner = schemaExpression(
                for: array.element,
                description: nil,
                defaultValue: nil,
                fieldNode: fieldNode,
                context: context
            )
            return buildObjectExpr(
                base: [
                    "\"type\": ManifoldInference.JSONSchemaValue.string(\"array\")",
                    "\"items\": \(inner)"
                ],
                description: description,
                defaultValue: defaultValue
            )
        }
        if let ident = type.as(IdentifierTypeSyntax.self),
           ident.name.text == "Array",
           let generic = ident.genericArgumentClause,
           let first = generic.arguments.first,
           let elementType = first.argument.as(TypeSyntax.self) {
            let inner = schemaExpression(
                for: elementType,
                description: nil,
                defaultValue: nil,
                fieldNode: fieldNode,
                context: context
            )
            return buildObjectExpr(
                base: [
                    "\"type\": ManifoldInference.JSONSchemaValue.string(\"array\")",
                    "\"items\": \(inner)"
                ],
                description: description,
                defaultValue: defaultValue
            )
        }

        // Named type.
        if let ident = type.as(IdentifierTypeSyntax.self) {
            let name = ident.name.text
            if let primitive = primitiveSchemaParts(for: name) {
                return buildObjectExpr(
                    base: primitive,
                    description: description,
                    defaultValue: defaultValue
                )
            }
            // Otherwise: treat as nested schema-providing type. Reference its
            // static `jsonSchema` directly. If the user wants a description /
            // default they get them for free from the nested type's own
            // synthesis (description/default don't propagate up — they'd
            // conflict with the nested schema's own keys).
            //
            // We do still attach the field-level description/default here by
            // wrapping the nested schema in a merged object at runtime would
            // be complex; simpler to skip and document the limit.
            return "\(name).jsonSchema"
        }

        context.diagnose(Diagnostic(node: fieldNode, message: ToolSchemaDiagnostic.unsupportedType(type.description.trimmingCharacters(in: .whitespacesAndNewlines))))
        return "ManifoldInference.JSONSchemaValue.object([:])"
    }

    /// Primitive type name -> schema fragments. Nil for non-primitives.
    static func primitiveSchemaParts(for name: String) -> [String]? {
        switch name {
        case "String":
            return ["\"type\": ManifoldInference.JSONSchemaValue.string(\"string\")"]
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return ["\"type\": ManifoldInference.JSONSchemaValue.string(\"integer\")"]
        case "Double", "Float", "Float32", "Float64", "CGFloat":
            return ["\"type\": ManifoldInference.JSONSchemaValue.string(\"number\")"]
        case "Bool":
            return ["\"type\": ManifoldInference.JSONSchemaValue.string(\"boolean\")"]
        default:
            return nil
        }
    }

    /// Wraps a list of `"key": expr` fragments (already stringified Swift) into
    /// a `.object([...])` literal, optionally appending `description` / `default`.
    static func buildObjectExpr(
        base: [String],
        description: String?,
        defaultValue: ExprSyntax?
    ) -> String {
        var parts = base
        if let description, !description.isEmpty {
            let escaped = description
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("\"description\": ManifoldInference.JSONSchemaValue.string(\"\(escaped)\")")
        }
        if let defaultValue, let literal = literalSchemaValue(from: defaultValue) {
            parts.append("\"default\": \(literal)")
        }
        return "ManifoldInference.JSONSchemaValue.object([\(parts.joined(separator: ", "))])"
    }

    /// Best-effort conversion of a Swift literal expression to a
    /// `JSONSchemaValue` construction expression. Returns `nil` for exprs we
    /// can't represent (function calls, member accesses we don't recognise).
    static func literalSchemaValue(from expr: ExprSyntax) -> String? {
        if let s = expr.as(StringLiteralExprSyntax.self),
           s.segments.count == 1,
           let seg = s.segments.first?.as(StringSegmentSyntax.self) {
            let raw = seg.content.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "ManifoldInference.JSONSchemaValue.string(\"\(raw)\")"
        }
        if let b = expr.as(BooleanLiteralExprSyntax.self) {
            return "ManifoldInference.JSONSchemaValue.bool(\(b.literal.text))"
        }
        if let i = expr.as(IntegerLiteralExprSyntax.self) {
            return "ManifoldInference.JSONSchemaValue.number(\(i.literal.text))"
        }
        if let f = expr.as(FloatLiteralExprSyntax.self) {
            return "ManifoldInference.JSONSchemaValue.number(\(f.literal.text))"
        }
        // Negative number (-1) shows up as PrefixOperatorExpr(operator: "-", expression: IntegerLiteral).
        if let prefix = expr.as(PrefixOperatorExprSyntax.self),
           prefix.operator.text == "-" {
            if let inner = prefix.expression.as(IntegerLiteralExprSyntax.self) {
                return "ManifoldInference.JSONSchemaValue.number(-\(inner.literal.text))"
            }
            if let inner = prefix.expression.as(FloatLiteralExprSyntax.self) {
                return "ManifoldInference.JSONSchemaValue.number(-\(inner.literal.text))"
            }
        }
        return nil
    }

    /// Extracts a `///` doc comment from leading trivia. Joins multiple
    /// consecutive `///` lines with a single space.
    static func extractDocComment(from trivia: Trivia) -> String? {
        var lines: [String] = []
        for piece in trivia {
            switch piece {
            case .docLineComment(let text):
                // "/// foo" -> "foo"
                var body = text
                if body.hasPrefix("///") { body.removeFirst(3) }
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                }
            case .docBlockComment(let text):
                // "/** foo */" — strip markers and collapse.
                var body = text
                if body.hasPrefix("/**") { body.removeFirst(3) }
                if body.hasSuffix("*/") { body.removeLast(2) }
                let trimmed = body
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*")) }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                lines.append(contentsOf: trimmed)
            default:
                continue
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

// MARK: - FieldInfo

private struct FieldInfo {
    let name: String
    let type: TypeSyntax
    let isOptional: Bool
    let defaultValue: ExprSyntax?
    let description: String?
    let sourceNode: Syntax
}

// MARK: - Diagnostics

enum ToolSchemaDiagnostic: DiagnosticMessage {
    case notAStructOrEnum
    case unsupportedType(String)
    case enumNotStringRawType

    var message: String {
        switch self {
        case .notAStructOrEnum:
            return "@ToolSchema can only be applied to a struct or a String-raw-type enum."
        case .unsupportedType(let name):
            return "@ToolSchema does not support field type '\(name)'. Supported: primitives (String, Int, Double, Bool), arrays of supported types, optionals, nested @ToolSchema structs, and @ToolSchema-annotated enums."
        case .enumNotStringRawType:
            return "@ToolSchema on an enum requires a String raw type (e.g. `enum Foo: String { ... }`)."
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .notAStructOrEnum:
            return MessageID(domain: "ToolSchemaMacro", id: "notAStructOrEnum")
        case .unsupportedType:
            return MessageID(domain: "ToolSchemaMacro", id: "unsupportedType")
        case .enumNotStringRawType:
            return MessageID(domain: "ToolSchemaMacro", id: "enumNotStringRawType")
        }
    }

    var severity: DiagnosticSeverity { .error }
}
#endif
