import ManifoldInference

/// Renders an ``AppEvalOutcome`` as deterministic Markdown.
///
/// Conventions (manifold-eval's report style, adopted here as spec — design
/// v2 §3.4):
/// - Pure function of the outcome struct — no `Date()`/clock reads, so two
///   renders of the same outcome are byte-identical (the property the golden
///   renderer test in `ManifoldAppEvalTests` locks down).
/// - Every dictionary is sorted by key before iteration.
/// - Numbers use fixed precision (`%.4f` for scores, matching manifold-eval's
///   convention for small [0,1]-ranged values).
/// - Raw model/explanation text is always fenced, never interpolated bare
///   into a table cell (a checkpoint's `explanation` can contain arbitrary
///   trace text, including pipe characters that would break a Markdown table).
/// - Absence (`.unavailable`) is a first-class row, not an omitted one.
/// - `# Title` + `##` sections, a bold verdict line, and a blockquote gloss
///   under the title (the shape this repo's own eval tooling uses).
public enum AppEvalMarkdownRenderer {

    public static func render(_ outcome: AppEvalOutcome) -> String {
        var lines: [String] = []
        lines.append("# ManifoldAppEval Report")
        lines.append("")
        lines.append("> Deterministic-lane golden scenario results. Absence (`unavailable`) is reported explicitly — it is never scored as a failure.")
        lines.append("")
        lines.append("**Verdict: \(verdictLabel(outcome.verdict))**")
        lines.append("")

        for fixture in outcome.fixtures.sorted(by: { $0.fixtureID < $1.fixtureID }) {
            lines.append("## \(fixture.fixtureID)")
            lines.append("")
            lines.append("**Fixture verdict: \(verdictLabel(fixture.verdict))**")
            lines.append("")
            lines.append("| Checkpoint | Assertion | Result | Detail |")
            lines.append("|---|---|---|---|")

            let sortedCheckpoints = fixture.checkpoints.sorted { $0.afterTurnIndex < $1.afterTurnIndex }
            for checkpoint in sortedCheckpoints {
                let sortedScoreKeys = checkpoint.scores.keys.sorted()
                if sortedScoreKeys.isEmpty {
                    lines.append("| \(escapeCell(checkpoint.label)) | _(none)_ | — | no assertions declared |")
                    continue
                }
                for key in sortedScoreKeys {
                    guard let score = checkpoint.scores[key] else { continue }
                    lines.append(
                        "| \(escapeCell(checkpoint.label)) | \(escapeCell(key)) | \(resultLabel(score)) | \(escapeCell(detail(score))) |"
                    )
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func verdictLabel(_ verdict: AppEvalVerdict) -> String {
        switch verdict {
        case .pass: return "PASS"
        case .fail: return "FAIL"
        case .error: return "ERROR"
        }
    }

    private static func resultLabel(_ score: Score) -> String {
        switch score.value {
        case .bool(true): return "pass"
        case .bool(false): return "fail"
        case .number(let value): return String(format: "%.4f", value)
        case .unavailable: return "unavailable"
        }
    }

    private static func detail(_ score: Score) -> String {
        var parts: [String] = []
        if let explanation = score.explanation, !explanation.isEmpty {
            parts.append(explanation)
        }
        if !score.metadata.isEmpty {
            let metadataDesc = score.metadata.keys.sorted()
                .map { "\($0)=\(score.metadata[$0] ?? "")" }
                .joined(separator: ", ")
            parts.append("(\(metadataDesc))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    /// Fences pipe/newline characters so arbitrary explanation/trace text
    /// never corrupts the Markdown table structure.
    private static func escapeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}
