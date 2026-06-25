import Foundation
import ManifoldInference

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
    ///
    /// Two complementary scores are carried:
    /// - The assertion-derived ``verdict`` (`.pass/.partial/.fail/.errored`) — a
    ///   scenario-level rollup of every assertion the harness checked.
    /// - The tool-selection ``ConfusionCounts`` (`tp/fp/fn` of *tools the model
    ///   called* vs *tools the scenario required*) — the same metric the MLX and
    ///   llama soak CLIs report, so a `(model × quant × backend)` matrix is
    ///   directly comparable across all three backends. `precision/recall/f1`
    ///   come free from `ConfusionCounts`.
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
        /// Tools the scenario expected to be called (the prompt record's
        /// `requiredTools`). Empty for a no-tool scenario.
        public let expectedTools: [String]
        /// Distinct tools the model actually called, sorted for stable output.
        public let calledTools: [String]
        /// Tool-selection true positives (called ∩ expected).
        public let toolTP: Int
        /// Tool-selection false positives (called − expected; includes decoys).
        public let toolFP: Int
        /// Tool-selection false negatives (expected − called).
        public let toolFN: Int

        public init(
            backend: String?,
            model: String?,
            quant: String?,
            scenario: String,
            assertionsPassed: Int,
            assertionsFailed: Int,
            errored: Bool,
            toolCallCount: Int,
            verdict: Verdict,
            expectedTools: [String],
            calledTools: [String],
            toolTP: Int,
            toolFP: Int,
            toolFN: Int
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
            self.expectedTools = expectedTools
            self.calledTools = calledTools
            self.toolTP = toolTP
            self.toolFP = toolFP
            self.toolFN = toolFN
        }

        /// The tool-selection counts as the shared core ``ConfusionCounts`` type
        /// (carries `precision`/`recall`/`f1`). Computed — not encoded twice.
        public var confusion: ConfusionCounts {
            ConfusionCounts(tp: toolTP, fp: toolFP, fn: toolFN)
        }

        /// Whether this scenario exercises tools (has a non-empty expected set).
        /// No-tool scenarios are excluded from macro-averaged tool metrics.
        public var isToolBearing: Bool { !expectedTools.isEmpty }
    }

    /// Macro-averaged tool-selection metrics over the tool-bearing rows — the
    /// unweighted mean of each scenario's precision/recall/F1, matching the
    /// `MacroAveragedMetrics` the MLX/llama CLIs emit. No-tool scenarios are
    /// excluded (an empty expected set is not a tool-selection class).
    public static func aggregate(_ rows: [ResultRow]) -> MacroAveragedMetrics {
        MacroAveragedMetrics(perClass: rows.filter { $0.isToolBearing }.map { $0.confusion })
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
            var expectedTools: [String] = []
            /// Whether a `prompt` record actually carried a `requiredTools` field.
            /// Distinguishes "no-tool scenario" (`requiredTools: []`) from "this
            /// transcript shape never emits the field" — only the latter triggers
            /// the assertion-derived expected-set recovery below.
            var requiredToolsPresent = false
            /// Expected tools recovered from the harness's dispatch-requirement
            /// assertions (`Scenario requires `X` … — dispatched/never dispatched`).
            /// Used only as a fallback when `requiredToolsPresent == false`.
            var recoveredExpectedTools: Set<String> = []
            var calledTools: Set<String> = []
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
            case "prompt":
                // The prompt record carries the scenario's expected tool set.
                // Tolerate its absence (older / companion transcript shapes) — the
                // assertion-derived recovery below fills the gap so a correctly
                // dispatched tool isn't mis-scored as a false positive.
                if let required = object["requiredTools"] as? [String] {
                    groups[key]?.expectedTools = required
                    groups[key]?.requiredToolsPresent = true
                }
            case "assertion":
                if (object["passed"] as? Bool) == true {
                    groups[key]?.assertionsPassed += 1
                } else {
                    groups[key]?.assertionsFailed += 1
                }
                // Recover the scenario's required tool(s) from the harness's
                // dispatch-requirement assertions when the prompt record didn't
                // carry `requiredTools`. The manifold-llama soak emitter predates
                // that field, so without this every correct llama tool call lands
                // in FP against an empty expected set (#2005). We extract only the
                // tool token from the structural `Scenario requires X …` template —
                // whether the emitter wrote it backtick-quoted or bare (the bare
                // `… to actually be dispatched` form), never free prose — so recovery
                // cannot invent a tool the scenario didn't require, and a wrong tool
                // still scores FP.
                if let message = object["message"] as? String {
                    for tool in expectedToolsFromAssertion(message) {
                        groups[key]?.recoveredExpectedTools.insert(tool)
                    }
                }
            case "tool_call":
                groups[key]?.toolCallCount += 1
                if let name = object["name"] as? String {
                    groups[key]?.calledTools.insert(name)
                }
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
            // Expected set: the prompt's `requiredTools` when present, otherwise the
            // set recovered from dispatch-requirement assertions (older / companion
            // transcript shapes that omit the field — #2005). When `requiredTools`
            // *is* present we never consult the recovered set, so the Ollama path is
            // untouched and an authoritative `requiredTools: []` stays a no-tool row.
            let expectedTools: [String] = acc.requiredToolsPresent
                ? acc.expectedTools
                : acc.recoveredExpectedTools.sorted()
            // Tool-selection confusion: tools called vs tools required. Reuses the
            // shared core metric so the row is comparable with the MLX/llama soak.
            let confusion = ConfusionCounts.compute(
                actual: acc.calledTools,
                expected: Set(expectedTools)
            )
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
                ),
                expectedTools: expectedTools,
                calledTools: acc.calledTools.sorted(),
                toolTP: confusion.tp,
                toolFP: confusion.fp,
                toolFN: confusion.fn
            )
        }
    }

    /// Recovers the required tool name(s) named in a dispatch-requirement
    /// assertion message, used only when a transcript omits the `requiredTools`
    /// prompt field (#2005 — the manifold-llama soak emitter predates it).
    ///
    /// Deliberately conservative: it matches the tool token in the structural
    /// `Scenario requires X …` template the harness emits — both when the token is
    /// backtick-quoted (`Scenario requires `now` …`) and when the manifold-llama
    /// soak emitter renders it bare (`Scenario requires list_dir to actually be
    /// dispatched`). The bare form is why a correctly dispatched `list_dir` was
    /// mis-scored as a false positive: backtick-only extraction recovered an empty
    /// expected set, so `calledTools − expectedTools` flagged the right call as an
    /// FP. The bare matcher is anchored to the exact `… to actually be dispatched`
    /// frame, so free-prose requirement assertions (e.g. "Scenario requires the
    /// shopping list to be read from the fixture") still yield nothing rather than
    /// risk crediting a phantom expected tool — under-counting the expected set is
    /// safe (it never manufactures a false positive *or* a false true-positive),
    /// whereas loose prose matching could. A genuinely wrong tool therefore still
    /// scores as FP.
    static func expectedToolsFromAssertion(_ message: String) -> [String] {
        guard message.hasPrefix("Scenario requires") else { return [] }
        var tools: [String] = []
        var rest = Substring(message)
        while let open = rest.firstIndex(of: "`") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "`") else { break }
            let token = String(rest[afterOpen..<close])
            // A tool identifier — reject anything that isn't a bare snake/alnum id
            // so an incidentally back-ticked prose fragment can't slip through.
            if !token.isEmpty,
               token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                tools.append(token)
            }
            rest = rest[rest.index(after: close)...]
        }
        // Bare-token dispatch frame: `Scenario requires <id> to actually be
        // dispatched`. Only the single identifier sitting *exactly* between the
        // `Scenario requires ` prefix and the ` to actually be dispatched` marker
        // is recovered — a backtick-wrapped token contains backticks (failing the
        // id check) and is left to the loop above, and prose between the two
        // anchors (multiple words / spaces) never satisfies the bare-id check.
        let prefix = "Scenario requires "
        let dispatchMarker = " to actually be dispatched"
        if message.hasPrefix(prefix), let marker = message.range(of: dispatchMarker) {
            let tokenStart = message.index(message.startIndex, offsetBy: prefix.count)
            if tokenStart <= marker.lowerBound {
                let token = String(message[tokenStart..<marker.lowerBound])
                if !token.isEmpty,
                   token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    tools.append(token)
                }
            }
        }
        return tools
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
        let header = "backend,model,quant,scenario,assertionsPassed,assertionsFailed,errored,toolCallCount,verdict,toolTP,toolFP,toolFN,precision,recall,f1"
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
                row.verdict.rawValue,
                String(row.toolTP),
                String(row.toolFP),
                String(row.toolFN),
                fixed(row.confusion.precision),
                fixed(row.confusion.recall),
                fixed(row.confusion.f1)
            ].joined(separator: ",")
        }
        return ([header] + body).joined(separator: "\n")
    }

    /// Formats a metric to 4 decimals with a fixed locale so CSV output is
    /// stable across machines (no comma decimal separators).
    private static func fixed(_ value: Double) -> String {
        String(format: "%.4f", value)
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
