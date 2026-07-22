#if canImport(FoundationModels)
import Foundation
import FoundationModels
// P2a (#1719): Contract-leaf surface only — see FoundationBackend.swift.
import ManifoldContract

/// Builds an Apple `GenerationSchema` that constrains the model's output to
/// either a plain text reply or a tool invocation chosen from the registered
/// `ToolDefinition` list.
///
/// The on-device Foundation Model has no native function-calling surface in
/// the Xcode 26.4 SDK — its only structured-output channel is GuidedGeneration
/// against a `Generable` / `GenerationSchema`. We synthesize tool calling on
/// top of that channel: every round produces an envelope of the shape
///
/// ```text
/// { kind: "text", text: "..." }
///   or
/// { kind: "tool_call", name: "<one of the tool names>", arguments: <tool-specific schema> }
/// ```
///
/// Constraining `name` to `anyOf` the registered tool names and pinning the
/// arguments schema per-tool keeps the model honest: it cannot fabricate a
/// tool, and the arguments object is shape-checked at decode time. The
/// orchestrator then dispatches the call and feeds the result back as the
/// next round's prompt — same loop the cloud and MLX backends drive.
@available(iOS 26, macOS 26, *)
enum FoundationToolSchema {

    /// The set of tool arms an envelope should offer plus whether the plain
    /// text arm is permitted — the shape of the schema after applying a
    /// ``ToolChoice``.
    ///
    /// - `tools`: the tools the model may invoke this round. For a `.tool(name:)`
    ///   request this is exactly the named tool; for `.auto`/`.required` it is
    ///   the full request list.
    /// - `includeTextBranch`: whether the model may answer with plain text
    ///   instead of a tool. `false` for `.required` and `.tool(name:)` — that is
    ///   what makes the forcing bite: with no text arm in the schema, the
    ///   GuidedGeneration channel cannot emit a plain-text envelope, so the
    ///   model must select a tool.
    struct ToolSelection {
        let tools: [ToolDefinition]
        let includeTextBranch: Bool
    }

    /// Thrown when a ``ToolChoice`` cannot be honoured against the request's
    /// tool list. Currently only `.tool(name:)` naming a tool that is not in
    /// the request produces this — the caller fails the generation closed
    /// rather than silently downgrading to model-decides.
    enum ToolChoiceResolutionError: Error, CustomStringConvertible {
        case forcedToolNotRegistered(String)

        var description: String {
            switch self {
            case .forcedToolNotRegistered(let name):
                return "FoundationToolSchema: toolChoice forced tool '\(name)' is not present in the request's tool list."
            }
        }
    }

    /// Resolves a ``ToolChoice`` into the concrete envelope shape.
    ///
    /// Pure decision logic — no `GenerationSchema` construction — so it is unit
    /// testable without a live Apple Intelligence session.
    ///
    /// - `.auto`: every tool, plus the plain-text arm (model decides).
    /// - `.required`: every tool, no text arm (model must pick a tool).
    /// - `.tool(name:)`: only the named tool, no text arm (model must call it).
    ///   Throws ``ToolChoiceResolutionError/forcedToolNotRegistered(_:)`` if the
    ///   name is absent — an unsatisfiable request the caller fails closed on.
    /// - `.none`: never reaches here (the caller takes the untooled path first);
    ///   treated as `.auto` defensively.
    static func resolveToolSelection(
        tools: [ToolDefinition],
        toolChoice: ToolChoice
    ) throws -> ToolSelection {
        switch toolChoice {
        case .auto, .none:
            return ToolSelection(tools: tools, includeTextBranch: true)
        case .required:
            return ToolSelection(tools: tools, includeTextBranch: false)
        case .tool(let name):
            guard let match = tools.first(where: { $0.name == name }) else {
                throw ToolChoiceResolutionError.forcedToolNotRegistered(name)
            }
            return ToolSelection(tools: [match], includeTextBranch: false)
        }
    }

    /// Returns a `GenerationSchema` for the tool-aware envelope, honouring the
    /// caller's ``ToolChoice`` (defaults to `.auto`). Throws if any tool's
    /// parameters block fails to map onto a `DynamicGenerationSchema` — the
    /// caller decides whether that is recoverable (auto → text-only fallback)
    /// or fatal (a forcing request that cannot silently degrade).
    static func makeEnvelope(
        tools: [ToolDefinition],
        toolChoice: ToolChoice = .auto
    ) throws -> GenerationSchema {
        try makeEnvelope(selection: resolveToolSelection(tools: tools, toolChoice: toolChoice))
    }

    /// Builds the envelope schema for an already-resolved ``ToolSelection``.
    static func makeEnvelope(selection: ToolSelection) throws -> GenerationSchema {
        // Per-tool argument schemas live as named dependencies so the root
        // anyOf can reference them by name.
        var dependencies: [DynamicGenerationSchema] = []
        var toolCallChoices: [DynamicGenerationSchema] = []

        for tool in selection.tools {
            let argsSchemaName = "Args_\(tool.name)"
            let argsSchema = try mapJSONSchema(tool.parameters, name: argsSchemaName)
            dependencies.append(argsSchema)

            let toolCall = DynamicGenerationSchema(
                name: "ToolCall_\(tool.name)",
                description: tool.description,
                properties: [
                    .init(
                        name: "kind",
                        schema: DynamicGenerationSchema(
                            name: "ToolCallKind_\(tool.name)",
                            anyOf: ["tool_call"]
                        )
                    ),
                    .init(
                        name: "name",
                        schema: DynamicGenerationSchema(
                            name: "ToolName_\(tool.name)",
                            anyOf: [tool.name]
                        )
                    ),
                    .init(
                        name: "arguments",
                        schema: DynamicGenerationSchema(referenceTo: argsSchemaName)
                    ),
                ]
            )
            toolCallChoices.append(toolCall)
        }

        // The text arm is included only when the ToolChoice allows a plain-text
        // answer (`.auto`). Dropping it is exactly how `.required` / `.tool`
        // force a tool: GuidedGeneration can only emit shapes present in the
        // schema, so with no text arm the model must produce a tool_call.
        let branches: [DynamicGenerationSchema]
        if selection.includeTextBranch {
            let textBranch = DynamicGenerationSchema(
                name: "TextReply",
                description: "Plain text response to the user.",
                properties: [
                    .init(
                        name: "kind",
                        schema: DynamicGenerationSchema(name: "TextKind", anyOf: ["text"])
                    ),
                    .init(
                        name: "text",
                        schema: DynamicGenerationSchema(type: String.self)
                    ),
                ]
            )
            branches = [textBranch] + toolCallChoices
        } else {
            branches = toolCallChoices
        }

        let root = DynamicGenerationSchema(
            name: "Envelope",
            description: "Either a text reply or a tool invocation.",
            anyOf: branches
        )

        return try GenerationSchema(root: root, dependencies: dependencies)
    }

    /// Builds a `GenerationSchema` for a plain guided structured-output target
    /// (#2354) — no `(text|tool_call)` envelope union, since a guided request
    /// has exactly one shape to fill. Reuses the same JSON-Schema →
    /// `DynamicGenerationSchema` mapper the tool-calling envelope builds tool
    /// argument schemas with (`mapJSONSchema` below); throws
    /// ``FoundationToolSchemaError`` for the same unsupported-construct reasons
    /// a tool's parameter schema would (`anyOf`/`oneOf`/`allOf`/`$ref`/nullable
    /// unions/etc.) — the caller fails the round closed rather than silently
    /// falling back, since (unlike tool calling's `.auto`) there is no
    /// acceptable "just answer with text" degrade for a typed structured-output
    /// request.
    ///
    /// Nested object properties are mapped inline (not via named references),
    /// so the returned schema is self-contained — `dependencies: []`.
    static func makeGuidedSchema(from schema: JSONSchemaValue, typeName: String) throws -> GenerationSchema {
        let root = try mapJSONSchema(schema, name: typeName)
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// A short instructions paragraph appended to the system prompt explaining
    /// the envelope contract. The structured-output channel guarantees the
    /// shape; this prose teaches the model when to choose each branch.
    static func instructions(tools: [ToolDefinition]) -> String {
        var lines: [String] = []
        lines.append(
            "You can answer the user directly with a text reply, or invoke one of the available tools to fetch information or perform an action. "
            + "Choose a tool only when its description clearly matches the user's intent; otherwise reply with text."
        )
        lines.append("Available tools:")
        for tool in tools {
            lines.append("- \(tool.name): \(tool.description)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSONSchema → DynamicGenerationSchema

    /// Maps a ``JSONSchemaValue`` (JSON-Schema-shaped tool parameter spec) to
    /// Apple's `DynamicGenerationSchema`. Supports the subset of JSON-Schema
    /// the in-tree tools actually use: object/properties/required, primitive
    /// types, arrays, enums (string), and nested objects. Anything outside
    /// that subset throws — callers fall back to untooled generation rather
    /// than send the model a half-broken schema.
    ///
    /// Strict-by-design: structural JSON-Schema constructs the on-device
    /// `DynamicGenerationSchema` cannot honour (`anyOf`, `oneOf`, `allOf`,
    /// `$ref`, type unions like `["string", "null"]`, `const`, `format`,
    /// `pattern`) throw `unsupportedKeyword(_:)`. Validator-level constraints
    /// the SDK has no way to enforce on a primitive type (`minLength`,
    /// `maxLength`, `minimum`, `maximum`, `additionalProperties`) are
    /// silently ignored — they don't change the *shape* of the generated
    /// envelope, only the validation surface, and the model already produces
    /// shape-correct output through GuidedGeneration.
    static func mapJSONSchema(
        _ value: JSONSchemaValue,
        name: String
    ) throws -> DynamicGenerationSchema {
        guard case .object(let dict) = value else {
            // `ToolDefinition.parameters` is documented as a JSON-Schema object
            // describing named arguments. Failing closed here lets the caller
            // drop tool calling for this round rather than ship a schema that
            // decodes as `{}` while the executor expects some other root shape
            // (the half-broken schema this PR is specifically trying to avoid).
            throw FoundationToolSchemaError.unsupportedType("non-object root")
        }

        try rejectUnsupportedKeywords(dict)

        // A nullable union (e.g. `type: ["string", "null"]`) cannot be honoured
        // by `DynamicGenerationSchema(type:)` — caller must drop tool calling
        // for this round rather than ship a schema that lets the model emit
        // values the host's tool executor will then reject.
        if case .array? = dict["type"] {
            throw FoundationToolSchemaError.unsupportedKeyword("type (array union)")
        }

        let typeString = dict["type"].flatMap { v -> String? in
            if case .string(let s) = v { return s }
            return nil
        }

        switch typeString {
        case "object", nil:
            let propertiesDict: [String: JSONSchemaValue]
            if case .object(let p)? = dict["properties"] {
                propertiesDict = p
            } else {
                propertiesDict = [:]
            }

            let requiredSet: Set<String>
            if case .array(let req)? = dict["required"] {
                requiredSet = Set(req.compactMap { v -> String? in
                    if case .string(let s) = v { return s }
                    return nil
                })
            } else {
                requiredSet = []
            }

            var properties: [DynamicGenerationSchema.Property] = []
            for (key, sub) in propertiesDict {
                let subSchema = try mapJSONSchema(sub, name: "\(name)_\(key)")
                let description: String? = {
                    if case .object(let d) = sub, case .string(let desc)? = d["description"] {
                        return desc
                    }
                    return nil
                }()
                properties.append(
                    .init(
                        name: key,
                        description: description,
                        schema: subSchema,
                        isOptional: !requiredSet.contains(key)
                    )
                )
            }
            return DynamicGenerationSchema(name: name, properties: properties)

        case "string":
            // Honour `enum` as anyOf when present.
            if case .array(let choices)? = dict["enum"] {
                let strings = choices.compactMap { v -> String? in
                    if case .string(let s) = v { return s }
                    return nil
                }
                if !strings.isEmpty {
                    return DynamicGenerationSchema(name: name, anyOf: strings)
                }
            }
            return DynamicGenerationSchema(type: String.self)

        case "integer":
            return DynamicGenerationSchema(type: Int.self)

        case "number":
            return DynamicGenerationSchema(type: Double.self)

        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)

        case "array":
            let itemSchema: DynamicGenerationSchema
            if case .object? = dict["items"] {
                itemSchema = try mapJSONSchema(dict["items"]!, name: "\(name)_item")
            } else {
                itemSchema = DynamicGenerationSchema(type: String.self)
            }
            return DynamicGenerationSchema(arrayOf: itemSchema)

        default:
            throw FoundationToolSchemaError.unsupportedType(typeString ?? "<missing>")
        }
    }
}

@available(iOS 26, macOS 26, *)
enum FoundationToolSchemaError: Error, CustomStringConvertible {
    case unsupportedType(String)
    /// A JSON-Schema construct (`anyOf`, `oneOf`, `allOf`, `$ref`, etc.) that
    /// `DynamicGenerationSchema` cannot honour. Surfaces the keyword name so
    /// the warning log explains why tool calling fell back.
    case unsupportedKeyword(String)

    var description: String {
        switch self {
        case .unsupportedType(let t):
            return "FoundationToolSchema: unsupported JSON-Schema type '\(t)' — falling back to untooled generation."
        case .unsupportedKeyword(let k):
            return "FoundationToolSchema: unsupported JSON-Schema keyword '\(k)' — falling back to untooled generation. " +
                   "DynamicGenerationSchema does not support structural alternatives or references; rewrite the tool's parameter schema to a closed shape."
        }
    }
}

/// Keywords this mapper rejects up-front. Any tool spec containing one of
/// these — at any nesting depth — falls back to untooled generation. Listed
/// here so the rejection logic stays auditable in one place.
@available(iOS 26, macOS 26, *)
private let unsupportedJSONSchemaKeywords: Set<String> = [
    "anyOf", "oneOf", "allOf", "not",  // structural alternatives
    "$ref", "$defs", "definitions",     // schema references
    "const",                            // fixed-value constraint
    "format", "pattern",                // string-validator constraints
    "if", "then", "else",               // conditional schemas
    "dependentRequired", "dependentSchemas", "dependencies",
    "patternProperties", "propertyNames", "unevaluatedProperties",
    "prefixItems", "contains", "unevaluatedItems",
]

@available(iOS 26, macOS 26, *)
private func rejectUnsupportedKeywords(_ dict: [String: JSONSchemaValue]) throws {
    for keyword in unsupportedJSONSchemaKeywords where dict[keyword] != nil {
        throw FoundationToolSchemaError.unsupportedKeyword(keyword)
    }
}

// MARK: - Decoding the envelope

@available(iOS 26, macOS 26, *)
enum FoundationEnvelope {
    case text(String)
    case toolCall(name: String, argumentsJSON: String)

    /// Inspects a `GeneratedContent` value produced against `makeEnvelope(tools:)`
    /// and returns the parsed branch. Returns `nil` if the structure does not
    /// match either branch — caller treats that as a parse failure and falls
    /// back to text-only output.
    static func decode(_ content: GeneratedContent) -> FoundationEnvelope? {
        guard case .structure(let props, _) = content.kind else { return nil }
        guard case .string(let kind)? = props["kind"]?.kind else { return nil }
        switch kind {
        case "text":
            if case .string(let text)? = props["text"]?.kind {
                return .text(text)
            }
            return nil
        case "tool_call":
            guard case .string(let name)? = props["name"]?.kind else { return nil }
            guard let arguments = props["arguments"] else { return nil }
            return .toolCall(name: name, argumentsJSON: arguments.jsonString)
        default:
            return nil
        }
    }
}
#endif
