import Foundation
import ManifoldInference

// MARK: - Normalized domain models

/// A single ground-truth alternative for a BFCL case: the expected function and,
/// per parameter, the list of accepted argument values.
///
/// BFCL's `possible_answer` encodes each acceptable call as
/// `{ functionName: { param: [accepted, values…] } }`. Pinning a *list* of values
/// per parameter is how the AST check tolerates legitimate variation (a unit can
/// be `"units"` or omitted; a rounding can be `5` or `5.0`).
public struct BFCLExpectedCall: Equatable, Sendable {

    /// The function the model is expected to call.
    public let functionName: String

    /// For each parameter, the set of accepted values (any one is correct).
    public let acceptedValues: [String: [JSONSchemaValue]]

    /// Parameters that must be supplied — those whose accepted-value list does
    /// **not** include the empty string `""`, BFCL's "optional / may be omitted"
    /// marker. Derived once at construction so the matcher needn't recompute it.
    public let requiredParams: Set<String>

    /// Builds an expected call from a ground-truth function name and its
    /// per-parameter accepted-value lists, deriving the required-parameter set.
    public init(functionName: String, acceptedValues: [String: [JSONSchemaValue]]) {
        self.functionName = functionName
        self.acceptedValues = acceptedValues
        // A parameter is optional iff its accepted list contains the empty-string
        // marker; everything else is required.
        self.requiredParams = Set(
            acceptedValues.compactMap { param, values in
                values.contains(.string("")) ? nil : param
            }
        )
    }
}

/// A BFCL case normalized for use by ``ScenarioRunner`` + ``ASTMatcher``: the
/// flattened user prompt, the advertised tools, and the ground-truth alternatives.
public struct BFCLLoadedCase: Equatable, Sendable {
    /// BFCL case id (e.g. `"simple_0"`).
    public let id: String
    /// The user prompt, flattened from BFCL's nested `question` turns.
    public let prompt: String
    /// Tools advertised to the model, mapped from BFCL's `function` schemas.
    public let tools: [ToolDefinition]
    /// Acceptable calls — a model output is correct if it matches any of these.
    public let groundTruth: [BFCLExpectedCall]

    public init(id: String, prompt: String, tools: [ToolDefinition], groundTruth: [BFCLExpectedCall]) {
        self.id = id
        self.prompt = prompt
        self.tools = tools
        self.groundTruth = groundTruth
    }
}

// MARK: - Wire models (BFCL on-disk JSONL shape)

/// One line of a BFCL question file (`BFCL_v3_simple.json`).
struct BFCLQuestionRecord: Codable {
    let id: String
    /// Nested conversation turns: `[[{role, content}]]` (one inner list per
    /// conversation; `simple` has a single user turn).
    let question: [[BFCLTurn]]
    /// Function schemas advertised for this case (OpenAI-style, but BFCL spells
    /// the object type `"dict"` — normalized to `"object"` when mapped).
    let function: [BFCLFunctionSchema]
}

struct BFCLTurn: Codable {
    let role: String
    let content: String
}

struct BFCLFunctionSchema: Codable {
    let name: String
    let description: String
    /// JSON-Schema-shaped parameter spec (with BFCL's `"type":"dict"` quirk).
    let parameters: JSONSchemaValue
}

/// One line of a BFCL `possible_answer` file.
struct BFCLAnswerRecord: Codable {
    let id: String
    /// A list of acceptable calls. Each element maps exactly one function name to
    /// its per-parameter accepted-value lists:
    /// `{ "calc": { "base": [10], "height": [5] } }`.
    let groundTruth: [[String: [String: [JSONSchemaValue]]]]

    enum CodingKeys: String, CodingKey {
        case id
        case groundTruth = "ground_truth"
    }
}

// MARK: - Wire → domain mapping

extension BFCLAnswerRecord {
    /// Flattens the ground-truth list into expected-call alternatives.
    func expectedCalls() -> [BFCLExpectedCall] {
        groundTruth.compactMap { entry in
            // Each entry carries exactly one function name → accepted values.
            guard let (functionName, acceptedValues) = entry.first else { return nil }
            return BFCLExpectedCall(functionName: functionName, acceptedValues: acceptedValues)
        }
    }
}

extension BFCLFunctionSchema {
    /// Maps to a ``ToolDefinition`` advertised to the backend, normalizing BFCL's
    /// `"type":"dict"` to the JSON-Schema `"object"` that backends expect.
    func toToolDefinition() -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: Self.normalizeDictType(parameters)
        )
    }

    /// Recursively rewrites `{"type":"dict"}` → `{"type":"object"}`. BFCL uses
    /// Python's `dict`/`float` vocabulary; backends (Ollama/OpenAI) expect
    /// standard JSON-Schema `object`, and serializing `"dict"` confuses their
    /// schema parsers. Only the `object`/`dict` discriminator is normalized — the
    /// rest of the schema is forwarded verbatim.
    static func normalizeDictType(_ value: JSONSchemaValue) -> JSONSchemaValue {
        switch value {
        case .object(let dict):
            var rewritten: [String: JSONSchemaValue] = [:]
            for (key, child) in dict {
                if key == "type", case .string("dict") = child {
                    rewritten[key] = .string("object")
                } else {
                    rewritten[key] = normalizeDictType(child)
                }
            }
            return .object(rewritten)
        case .array(let items):
            return .array(items.map(normalizeDictType))
        default:
            return value
        }
    }
}

extension BFCLQuestionRecord {
    /// Flattens BFCL's nested `question` turns into a single user prompt. For the
    /// `simple` category this is the lone user turn; if multiple turns are
    /// present their contents are joined in order so no instruction is dropped.
    func flattenedPrompt() -> String {
        let turns = question.flatMap { $0 }
        let userContent = turns.filter { $0.role == "user" }.map(\.content)
        let chosen = userContent.isEmpty ? turns.map(\.content) : userContent
        return chosen.joined(separator: "\n")
    }
}
