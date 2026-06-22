import Foundation

/// Parses a ``TranscriptLogger`` JSONL file and reduces it to normalized,
/// scorable result rows — one per (backend, model, quant, scenario).
///
/// The transcript interleaves every (scenario × model) run the CLI executed, so
/// scoring per-model previously meant parsing free-form stdout. With per-record
/// attribution (`backend` / `model` / `quant` on each row), this scorer groups
/// the events back into self-contained result rows that downstream tooling — a
/// CI matrix, a `(model × quant × backend)` comparison across the Ollama / MLX /
/// llama backends — can consume directly.
///
/// Designed to be promotable to a shared `.library` product later so the
/// companion MLX/llama repos can reuse it; for now it lives inside
/// `ManifoldTools` (no new product, no file moves — that promotion is follow-up).
public enum ConformanceScorer {

    /// Derived per-run verdict.
    public enum Verdict: String, Codable, Sendable {
        /// Every assertion passed, at least one assertion ran, and no error.
        case pass
        /// Some assertions passed and some failed (no error).
        case partial
        /// No assertion passed, or zero assertions ran (and no error).
        case fail
        /// The run recorded a harness/tool error.
        case errored
    }

    /// One normalized result row per (backend, model, quant, scenario).
    public struct ResultRow: Codable, Sendable, Equatable {
        public let backend: String?
        public let model: String?
        public let quant: String?
        public let scenario: String
        public let assertionsPassed: Int
        public let assertionsFailed: Int
        public let errored: Bool
        public let toolCallCount: Int
        public let verdict: Verdict

        public init(
            backend: String?,
            model: String?,
            quant: String?,
            scenario: String,
            assertionsPassed: Int,
            assertionsFailed: Int,
            errored: Bool,
            toolCallCount: Int,
            verdict: Verdict
        ) {
            self.backend = backend
            self.model = model
            self.quant = quant
            self.scenario = scenario
            self.assertionsPassed = assertionsPassed
            self.assertionsFailed = assertionsFailed
            self.errored = errored
            self.toolCallCount = toolCallCount
            self.verdict = verdict
        }
    }

    public enum ScoringError: Error, CustomStringConvertible {
        case fileUnreadable(URL, underlying: Error)

        public var description: String {
            switch self {
            case .fileUnreadable(let url, let underlying):
                return "ConformanceScorer: cannot read \(url.path): \(underlying)"
            }
        }
    }

    /// Scores a transcript file on disk.
    public static func score(fileAt url: URL) throws -> [ResultRow] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ScoringError.fileUnreadable(url, underlying: error)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            // A transcript that isn't UTF-8 is a corrupt file; treat as empty
            // rather than crash. There is nothing to score.
            return []
        }
        return score(jsonl: text)
    }

    /// Scores a transcript supplied as a JSONL string. Rows are returned in a
    /// stable order (first-seen grouping key) so output diffs are deterministic.
    public static func score(jsonl text: String) -> [ResultRow] {
        // Accumulator keyed by the attribution tuple + scenario.
        struct Accumulator {
            var backend: String?
            var model: String?
            var quant: String?
            var scenario: String
            var assertionsPassed = 0
            var assertionsFailed = 0
            var errored = false
            var toolCallCount = 0
        }

        var order: [String] = []
        var groups: [String: Accumulator] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }

            let object: [String: Any]
            do {
                let parsed = try JSONSerialization.jsonObject(with: lineData)
                guard let dict = parsed as? [String: Any] else { continue }
                object = dict
            } catch {
                // A malformed line is skipped, not fatal — a transcript is an
                // append-only log and a torn final line shouldn't sink scoring.
                continue
            }

            guard let kind = object["kind"] as? String,
                  let scenario = object["scenario"] as? String else { continue }

            let backend = object["backend"] as? String
            let model = object["model"] as? String
            let quant = object["quant"] as? String

            let key = [backend ?? "", model ?? "", quant ?? "", scenario].joined(separator: "\u{1F}")
            if groups[key] == nil {
                order.append(key)
                groups[key] = Accumulator(backend: backend, model: model, quant: quant, scenario: scenario)
            }

            switch kind {
            case "assertion":
                if (object["passed"] as? Bool) == true {
                    groups[key]?.assertionsPassed += 1
                } else {
                    groups[key]?.assertionsFailed += 1
                }
            case "tool_call":
                groups[key]?.toolCallCount += 1
            case "error":
                // Not emitted by the current logger, but tolerated so a future
                // explicit error record is honoured by the scorer.
                groups[key]?.errored = true
            default:
                break
            }
        }

        return order.compactMap { key -> ResultRow? in
            guard let acc = groups[key] else { return nil }
            return ResultRow(
                backend: acc.backend,
                model: acc.model,
                quant: acc.quant,
                scenario: acc.scenario,
                assertionsPassed: acc.assertionsPassed,
                assertionsFailed: acc.assertionsFailed,
                errored: acc.errored,
                toolCallCount: acc.toolCallCount,
                verdict: verdict(
                    passed: acc.assertionsPassed,
                    failed: acc.assertionsFailed,
                    errored: acc.errored
                )
            )
        }
    }

    /// Derives the verdict from the assertion tallies and error flag.
    public static func verdict(passed: Int, failed: Int, errored: Bool) -> Verdict {
        if errored { return .errored }
        if failed == 0 && passed > 0 { return .pass }
        if passed > 0 && failed > 0 { return .partial }
        return .fail
    }

    /// Serializes rows to pretty-printed JSON. Keys are sorted for stable diffs.
    public static func encodeJSON(_ rows: [ResultRow]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }

    /// CSV helper (nice-to-have): one header row + one row per result.
    public static func encodeCSV(_ rows: [ResultRow]) -> String {
        let header = "backend,model,quant,scenario,assertionsPassed,assertionsFailed,errored,toolCallCount,verdict"
        let body = rows.map { row in
            [
                csvField(row.backend),
                csvField(row.model),
                csvField(row.quant),
                csvField(row.scenario),
                String(row.assertionsPassed),
                String(row.assertionsFailed),
                String(row.errored),
                String(row.toolCallCount),
                row.verdict.rawValue
            ].joined(separator: ",")
        }
        return ([header] + body).joined(separator: "\n")
    }

    private static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
