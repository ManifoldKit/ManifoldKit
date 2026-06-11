import Foundation

/// Backend-specific mechanism used to request structured model output.
// `any Decodable.Type` is a metatype — safely shareable across concurrency
// boundaries since metatypes carry no mutable instance state.
public enum StructuredOutputStrategy: @unchecked Sendable, Equatable {
    /// GBNF grammar string for sampler-level constrained decoding.
    case gbnf(String)
    /// Foundation guided-generation target type.
    case guided(any Decodable.Type)
    /// JSON Schema document serialized as a string.
    case jsonSchema(String)
    /// Prompt-level JSON instruction fallback.
    case jsonPrompting

    public static func == (lhs: StructuredOutputStrategy, rhs: StructuredOutputStrategy) -> Bool {
        switch (lhs, rhs) {
        case (.gbnf(let lhsGrammar), .gbnf(let rhsGrammar)):
            lhsGrammar == rhsGrammar
        case (.guided(let lhsType), .guided(let rhsType)):
            ObjectIdentifier(lhsType) == ObjectIdentifier(rhsType)
        case (.jsonSchema(let lhsSchema), .jsonSchema(let rhsSchema)):
            lhsSchema == rhsSchema
        case (.jsonPrompting, .jsonPrompting):
            true
        default:
            false
        }
    }
}

/// Payload a caller wants a backend to produce in structured form.
public struct StructuredOutputTarget: @unchecked Sendable, Equatable {
    public var gbnfGrammar: String?
    public var guidedType: (any Decodable.Type)?
    public var jsonSchema: String?

    public init(
        gbnfGrammar: String? = nil,
        guidedType: (any Decodable.Type)? = nil,
        jsonSchema: String? = nil
    ) {
        self.gbnfGrammar = gbnfGrammar
        self.guidedType = guidedType
        self.jsonSchema = jsonSchema
    }

    public init(
        gbnfGrammar: String? = nil,
        guidedType: (any Decodable.Type)? = nil,
        jsonSchema: JSONSchemaValue,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        self.gbnfGrammar = gbnfGrammar
        self.guidedType = guidedType
        self.jsonSchema = try Self.encodeSchema(jsonSchema, encoder: encoder)
    }

    public static func guided<T: Decodable>(
        _ type: T.Type,
        jsonSchema: String? = nil,
        gbnfGrammar: String? = nil
    ) -> StructuredOutputTarget {
        StructuredOutputTarget(gbnfGrammar: gbnfGrammar, guidedType: type, jsonSchema: jsonSchema)
    }

    public static func jsonSchema(
        _ schema: JSONSchemaValue,
        gbnfGrammar: String? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> StructuredOutputTarget {
        try StructuredOutputTarget(gbnfGrammar: gbnfGrammar, jsonSchema: schema, encoder: encoder)
    }

    private static func encodeSchema(_ schema: JSONSchemaValue, encoder: JSONEncoder) throws -> String {
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        return String(decoding: data, as: UTF8.self)
    }

    public static func == (lhs: StructuredOutputTarget, rhs: StructuredOutputTarget) -> Bool {
        lhs.gbnfGrammar == rhs.gbnfGrammar
        && lhs.jsonSchema == rhs.jsonSchema
        && lhs.guidedType.map(ObjectIdentifier.init) == rhs.guidedType.map(ObjectIdentifier.init)
    }
}

/// Best structured-output mechanism a backend capability profile can advertise.
public enum StructuredOutputSupport: String, CaseIterable, Sendable, Codable, Equatable {
    case grammarConstrainedSampling
    case guidedGeneration
    case jsonSchema
    case jsonPrompting
}

/// Chooses the strongest structured-output strategy supported by a backend.
public enum StructuredOutputRouter {
    public static func selectStrategy(
        capabilities: BackendCapabilities,
        target: StructuredOutputTarget
    ) -> StructuredOutputStrategy {
        if capabilities.supportsGrammarConstrainedSampling,
           let grammar = target.gbnfGrammar,
           !grammar.isEmpty {
            return .gbnf(grammar)
        }

        if capabilities.supportsGuidedStructuredOutput,
           let type = target.guidedType {
            return .guided(type)
        }

        if capabilities.supportsStructuredOutput,
           let schema = target.jsonSchema,
           !schema.isEmpty {
            return .jsonSchema(schema)
        }

        return .jsonPrompting
    }

    public static func selectStrategy(
        capabilities: BackendCapabilities,
        gbnfGrammar: String? = nil,
        guidedType: (any Decodable.Type)? = nil,
        jsonSchema: String? = nil
    ) -> StructuredOutputStrategy {
        selectStrategy(
            capabilities: capabilities,
            target: StructuredOutputTarget(
                gbnfGrammar: gbnfGrammar,
                guidedType: guidedType,
                jsonSchema: jsonSchema
            )
        )
    }
}
