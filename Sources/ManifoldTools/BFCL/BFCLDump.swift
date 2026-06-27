import Foundation
import ManifoldInference

/// A per-case record of one BFCL evaluation run, serialisable to JSONL so a live
/// run can be captured and cross-checked against canonical `bfcl-eval` offline.
///
/// The model's output is nondeterministic run-to-run (llama.cpp grammar sampling
/// and parser failures vary), so the canonical scorer cannot re-derive "the same"
/// outputs after the fact — the capture must happen *during* the scoring run. This
/// record holds the **decoded** calls we actually scored (not the raw model text),
/// which is exactly the granularity the matcher-strictness cross-check needs:
/// feeding identical decoded calls into both scorers isolates "is our matcher
/// stricter than canonical?" from "did our parser decode the same thing?".
public struct BFCLRunRecord: Encodable, Equatable {

    /// One emitted tool call, decoded.
    public struct DecodedCall: Encodable, Equatable {
        /// The tool name the model invoked.
        public let name: String
        /// The decoded argument object, or — when the payload was not a JSON
        /// object — the raw string, so the cross-check sees what we scored.
        public let args: JSONSchemaValue

        public init(name: String, args: JSONSchemaValue) {
            self.name = name
            self.args = args
        }
    }

    /// BFCL case id (e.g. `"multiple_0"`).
    public let id: String
    /// The model that produced this output (`ollama/<name>`).
    public let model: String
    /// The decoded calls the model emitted on its first turn.
    public let decoded: [DecodedCall]
    /// Whether our ``ASTMatcher`` scored this case as an argument-level match.
    public let astMatched: Bool
    /// Whether the name-only check (what `ConformanceScorer` credits) matched.
    public let nameMatched: Bool

    enum CodingKeys: String, CodingKey {
        case id, model, decoded
        case astMatched = "ast_matched"
        case nameMatched = "name_matched"
    }

    public init(id: String, model: String, decoded: [DecodedCall], astMatched: Bool, nameMatched: Bool) {
        self.id = id
        self.model = model
        self.decoded = decoded
        self.astMatched = astMatched
        self.nameMatched = nameMatched
    }

    /// Builds a dump record from one case's emitted calls and its computed scores.
    public static func make(
        id: String,
        model: String,
        emittedCalls: [ToolCall],
        astMatched: Bool,
        nameMatched: Bool
    ) -> BFCLRunRecord {
        let decoded = emittedCalls.map { DecodedCall(name: $0.toolName, args: parseArgs($0.arguments)) }
        return BFCLRunRecord(id: id, model: model, decoded: decoded, astMatched: astMatched, nameMatched: nameMatched)
    }

    /// Decodes a tool call's JSON argument string into a structured value, falling
    /// back to the raw string when it is not a JSON object. This is a deliberate
    /// trust-boundary fallback (preserve, don't swallow): an unparseable payload is
    /// captured verbatim so the cross-check can see precisely what we scored.
    static func parseArgs(_ raw: String) -> JSONSchemaValue {
        guard let data = raw.data(using: .utf8) else { return .string(raw) }
        do {
            return .object(try JSONDecoder().decode([String: JSONSchemaValue].self, from: data))
        } catch {
            return .string(raw)
        }
    }

    /// Encodes this record as a single compact JSONL line. Keys are sorted so two
    /// runs of the same data diff cleanly.
    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
