import Foundation

/// Renders a cross-backend tool-calling conformance matrix as Markdown from a
/// flat `[ConformanceRecord]` corpus — the rendered-query replacement for the
/// hand-assembled `MATRIX.md` files under `docs/plans/archive/runs/`.
///
/// Pure and deterministic: it does no I/O, takes no model/backend dependency,
/// and the same records always render byte-identical (every grouping is
/// stable-sorted). That is what lets it run in hosted CI as a unit test against
/// hand-authored record fixtures — no Apple Silicon, no GGUF, no live server.
///
/// **The whole point is honesty about holes.** A ``CellStatus/notMeasured(_:)``
/// or ``CellStatus/loadFail(_:)`` cell renders as a *distinct* row (🚫 / 💥)
/// carrying its reason — never as a `0.000` measured row. A *measured* failure
/// (e.g. the model called no tool, ``FailureClass/noCall``) does render its real
/// `0.000` metrics, because that zero was actually measured. Conflating the two
/// — "absence reads as a measured zero" — is exactly the defect the
/// ``ConformanceRecord`` schema was added to kill.
public enum MatrixRenderer {

    /// Renders the full Markdown document for a record corpus.
    ///
    /// - Parameters:
    ///   - records: the flat record corpus (any mix of backends, models,
    ///     scenarios, decoy levels, and cell statuses).
    ///   - title: the H1 heading. Defaults to the canonical matrix title.
    /// - Returns: a Markdown string. Deterministic for a given `records` value.
    public static func render(
        _ records: [ConformanceRecord],
        title: String = "Cross-Backend Tool-Calling Conformance Matrix"
    ) -> String {
        var sections: [String] = []
        sections.append("# \(title)")
        sections.append(provenanceLine(records))
        sections.append(mainMatrixSection(records))
        if let ladder = decoyLadderSection(records) {
            sections.append(ladder)
        }
        if let cross = crossRuntimeSection(records) {
            sections.append(cross)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Cell identity

    /// The `(backend × model × quant × renderer)` tuple a row aggregates over.
    /// `repeatIndex` is deliberately NOT part of the key: repeats are separate
    /// transcripts that each emit a record, so "runs" for a cell is the *count*
    /// of its records, not a keyed dimension (the scorer fixes `repeatIndex` at 0).
    struct CellKey: Hashable, Comparable {
        let backend: String
        let model: String
        let quant: String
        let renderer: String

        static func < (lhs: CellKey, rhs: CellKey) -> Bool {
            (lhs.backend, lhs.model, lhs.quant, lhs.renderer)
                < (rhs.backend, rhs.model, rhs.quant, rhs.renderer)
        }

        init(_ record: ConformanceRecord) {
            self.backend = record.backend
            self.model = record.model
            self.quant = record.quant
            self.renderer = record.renderer
        }
    }

    // MARK: - Provenance

    private static func provenanceLine(_ records: [ConformanceRecord]) -> String {
        let cells = Set(records.map { CellKey($0) }).count
        let backends = Set(records.map { $0.backend }).sorted()
        let commits = Set(records.map { $0.coreCommit }).sorted()
        let commitText = commits.isEmpty ? "—" : commits.joined(separator: ", ")
        return "Rendered from \(records.count) `ConformanceRecord`(s) across "
            + "\(cells) cell(s) · backends: \(backends.isEmpty ? "—" : backends.joined(separator: ", ")) "
            + "· core: \(commitText)."
    }

    // MARK: - Main matrix (d0)

    private static func mainMatrixSection(_ records: [ConformanceRecord]) -> String {
        let d0 = records.filter { $0.decoyLevel == 0 }
        var lines: [String] = []
        lines.append("## Main matrix (d0 — no decoys)")
        lines.append(
            "Means of tool-selection precision/recall/F1 over the cell's *measured* "
            + "records; `Runs` is the record count. Holes render as their own rows "
            + "(🚫 not measured · 💥 load-fail · 🛑 render-fail) — never as a measured `0.000`. "
            + "Verdicts: ✅ pass · ⚠️ partial / renders-no-call / low-precision · ❌ fail · 💥 errored."
        )
        lines.append("")
        lines.append("| Backend | Model | Quant | Renderer | Runs | Prec | Recall | F1 | Verdict |")
        lines.append("|---------|-------|-------|----------|------|------|--------|----|---------|")

        // Stable cell order: every record contributes its cell key; sort the keys.
        let byCell = Dictionary(grouping: d0) { CellKey($0) }
        for key in byCell.keys.sorted() {
            guard let cellRecords = byCell[key] else { continue }
            lines.append(contentsOf: rows(for: key, records: cellRecords))
        }
        if byCell.isEmpty {
            lines.append("| _(no d0 records)_ | | | | | | | | |")
        }
        return lines.joined(separator: "\n")
    }

    /// The row(s) one cell contributes to the main table. A cell with measured
    /// records emits one aggregated measured row; its non-measured records emit
    /// one honest hole row per distinct status (collapsed + counted).
    private static func rows(for key: CellKey, records: [ConformanceRecord]) -> [String] {
        var out: [String] = []
        let measured = records.filter { $0.status == .measured }
        let holes = records.filter { $0.status != .measured }

        if !measured.isEmpty {
            out.append(measuredRow(key, measured: measured))
        }
        for (label, count) in holeGroups(holes) {
            out.append(holeRow(key, label: label, count: count))
        }
        return out
    }

    private static func measuredRow(_ key: CellKey, measured: [ConformanceRecord]) -> String {
        let scored = measured.compactMap { $0.toolSelection }
        let precision = scored.isEmpty ? "—" : fixed(mean(scored.map { $0.precision }))
        let recall = scored.isEmpty ? "—" : fixed(mean(scored.map { $0.recall }))
        let f1 = scored.isEmpty ? "—" : fixed(mean(scored.map { $0.f1 }))
        let verdict = dominantVerdictLabel(measured)
        return "| \(esc(key.backend)) | \(esc(key.model)) | \(esc(key.quant)) | "
            + "\(esc(key.renderer)) | \(measured.count) | \(precision) | \(recall) | "
            + "\(f1) | \(verdict) |"
    }

    /// A hole row: numeric columns are `—` (NOT `0.000`) and the verdict column
    /// carries the status symbol + reason. This is the load-bearing honesty.
    private static func holeRow(_ key: CellKey, label: String, count: Int) -> String {
        let runs = count > 1 ? "\(count)×" : "0"
        return "| \(esc(key.backend)) | \(esc(key.model)) | \(esc(key.quant)) | "
            + "\(esc(key.renderer)) | \(runs) | — | — | — | \(label) |"
    }

    /// Collapses a cell's non-measured records into `(label, count)` pairs,
    /// deterministically ordered by label.
    private static func holeGroups(_ holes: [ConformanceRecord]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for hole in holes {
            counts[statusLabel(hole.status), default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: - Decoy ladder

    private static func decoyLadderSection(_ records: [ConformanceRecord]) -> String? {
        let ladder = records.filter { $0.decoyLevel > 0 }
        guard !ladder.isEmpty else { return nil }

        // Cells appearing anywhere in the ladder; show their full level spread,
        // baseline (d0) included where present so decay is readable.
        let ladderKeys = Set(ladder.map { CellKey($0) })
        let relevant = records.filter { ladderKeys.contains(CellKey($0)) && $0.status == .measured }
        let levels = Set(relevant.map { $0.decoyLevel }).sorted()
        guard !levels.isEmpty else { return nil }

        // f1[cell][level] = mean F1 of measured, tool-bearing records at that level.
        var byCellLevel: [CellKey: [Int: [Double]]] = [:]
        for record in relevant {
            guard let scores = record.toolSelection else { continue }
            byCellLevel[CellKey(record), default: [:]][record.decoyLevel, default: []].append(scores.f1)
        }

        var lines: [String] = []
        lines.append("## Decoy ladder (mean F1 per decoy level)")
        lines.append(
            "F1 under distractor pressure. `+N` = N decoy tools advertised alongside "
            + "the real set. Blank cells weren't measured at that level."
        )
        lines.append("")
        let header = (["Backend", "Model", "Quant", "Renderer"] + levels.map { levelHeader($0) })
            .joined(separator: " | ")
        lines.append("| \(header) |")
        lines.append("|\(String(repeating: "---|", count: 4 + levels.count))")

        for key in byCellLevel.keys.sorted() {
            guard let perLevel = byCellLevel[key] else { continue }
            var cells = [esc(key.backend), esc(key.model), esc(key.quant), esc(key.renderer)]
            for level in levels {
                if let values = perLevel[level], !values.isEmpty {
                    cells.append(fixed(mean(values)))
                } else {
                    cells.append("—")
                }
            }
            lines.append("| \(cells.joined(separator: " | ")) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func levelHeader(_ level: Int) -> String {
        level == 0 ? "d0" : "+\(level)"
    }

    // MARK: - Cross-runtime view

    private static func crossRuntimeSection(_ records: [ConformanceRecord]) -> String? {
        // Group d0 cells by a normalized (logical) model key so the same model on
        // different backends/quants sits adjacently for human inspection.
        let d0 = records.filter { $0.decoyLevel == 0 }
        let byCell = Dictionary(grouping: d0) { CellKey($0) }
        guard !byCell.isEmpty else { return nil }

        var groups: [String: [CellKey]] = [:]
        for key in byCell.keys {
            groups[normalizedModelKey(key.model), default: []].append(key)
        }
        // Only groups spanning more than one cell are worth a side-by-side.
        let multi = groups.filter { $0.value.count > 1 }
        guard !multi.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("## Cross-runtime view (same logical model, side by side)")
        lines.append(
            "> **Read this as a prompt for inspection, not a verdict.** Cells in a "
            + "group are matched only on a *normalized model name* — they may differ "
            + "in quant, checkpoint, or renderer. A verdict difference here is therefore "
            + "**not, on its own, evidence of a backend bug**: without a same-bytes "
            + "control a divergence is confounded. Use it to decide what to spot-check, "
            + "then read the transcripts."
        )
        lines.append("")
        lines.append("| Logical model | Backend | Quant | Renderer | Runs | F1 | Verdict |")
        lines.append("|---------------|---------|-------|----------|------|----|---------|")

        for normalized in multi.keys.sorted() {
            guard let keys = multi[normalized] else { continue }
            for key in keys.sorted() {
                guard let cellRecords = byCell[key] else { continue }
                let measured = cellRecords.filter { $0.status == .measured }
                let runs: String
                let f1: String
                let verdict: String
                if measured.isEmpty {
                    let groupsForCell = holeGroups(cellRecords.filter { $0.status != .measured })
                    let label = groupsForCell.first?.0 ?? statusLabel(.notMeasured("unknown"))
                    runs = "0"
                    f1 = "—"
                    verdict = label
                } else {
                    let scored = measured.compactMap { $0.toolSelection }
                    runs = "\(measured.count)"
                    f1 = scored.isEmpty ? "—" : fixed(mean(scored.map { $0.f1 }))
                    verdict = dominantVerdictLabel(measured)
                }
                lines.append(
                    "| \(esc(normalized)) | \(esc(key.backend)) | \(esc(key.quant)) | "
                    + "\(esc(key.renderer)) | \(runs) | \(f1) | \(verdict) |"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Best-effort logical-model key: lowercase, split on non-alphanumerics, and
    /// drop quant markers and a few well-known role/format suffixes. Deliberately
    /// conservative — it groups for *adjacency*, and the section labels the match
    /// as approximate, so over- or under-merging never asserts a backend bug.
    static func normalizedModelKey(_ model: String) -> String {
        let lower = model.lowercased()
        let tokens = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        let dropped: Set<String> = ["tools", "tool", "instruct", "it", "chat", "gguf", "mlx", "tooltmpl"]
        let kept = tokens.filter { !$0.isEmpty && !dropped.contains($0) && !isQuantToken($0) }
        return kept.isEmpty ? lower : kept.joined(separator: "-")
    }

    /// Conservative quant-token detector: `q4_K_M`-style (after the split, `q4`,
    /// `k`, `m` arrive separately so we match the `q<digit>` head), bit-width
    /// labels, and the common float markers. Anything ambiguous is kept.
    private static func isQuantToken(_ token: String) -> Bool {
        if token.hasPrefix("q"), let second = token.dropFirst().first, second.isNumber { return true }
        if ["fp16", "fp32", "bf16", "f16", "f32", "4bit", "8bit"].contains(token) { return true }
        if token.hasPrefix("int"), token.count > 3, token.dropFirst(3).allSatisfy(\.isNumber) { return true }
        return false
    }

    // MARK: - Verdict + status labels

    /// F1-band ceiling below which a cell counts as "doesn't really call the right
    /// tool" — only then may a no-call-dominated failure label as `renders-no-call`.
    /// Set just above 0 so a genuine all-no-call cell (mean F1 0.000) still trips it
    /// while any cell that lands real calls (e.g. F1 0.750) never does.
    static let noCallF1Ceiling = 0.05

    /// F1-band floor at/above which a cell reads as `pass` regardless of its most
    /// common failure subtype — a cell selecting the right tool ~90%+ of the time
    /// is passing in aggregate even if a minority of records failed.
    static let passF1Floor = 0.9

    /// Derives a cell's single verdict label from its measured records.
    ///
    /// why F1-first, not failure-subtype-first: a cell's *aggregate* tool-selection
    /// F1 is the honest summary of how often it picks the right tool; the dominant
    /// `failureClass` is only the shape of its *minority* misses. Refining off the
    /// failure subtype alone mislabels a 0.750-F1 cell whose most common miss is
    /// `noCall` as "renders-no-call" — a cell that in fact calls correctly ~75% of
    /// the time. So we band on F1 first, then use verdict/failureClass only to
    /// refine *within* a band. Deterministic: `mean` and `dominant` are order-free.
    static func dominantVerdictLabel(_ measured: [ConformanceRecord]) -> String {
        let verdicts = measured.compactMap { $0.verdict }
        guard let topVerdict = dominant(verdicts, priority: verdictPriority) else { return "—" }

        // A harness/tool error is an infra signal independent of any F1.
        if topVerdict == .errored { return "💥 errored" }

        let f1s = measured.compactMap { $0.toolSelection?.f1 }
        let meanF1 = f1s.isEmpty ? nil : mean(f1s)

        // High aggregate F1 — or an unambiguous pass-dominant cell — reads as pass.
        if topVerdict == .pass || (meanF1 ?? 0) >= passF1Floor { return "✅ pass" }

        // Dominant failure shape among the cell's *failing* records — used only to
        // refine the label once F1 has placed the cell in a band.
        let failClasses = measured
            .filter { $0.verdict == .fail }
            .compactMap { $0.failureClass }
        let topFail = dominant(failClasses, priority: failureClassPriority)

        // renders-no-call is reserved for cells that (almost) never call when
        // required: F1 must be ≈ 0 AND no-call the dominant failure. A cell with no
        // measured F1 at all but no-call-dominated failures also qualifies (nothing
        // contradicts the no-call reading). Above the ceiling the cell DOES call, so
        // the label would be a lie — fall through to the mid-band labels instead.
        if topFail == .noCall {
            let f1NearZero = meanF1.map { $0 <= noCallF1Ceiling } ?? true
            if f1NearZero { return "⚠️ renders-no-call" }
        }

        // Infra-flavoured failure classes keep their distinct symbol regardless of band.
        switch topFail {
        case .truncation:
            return "⚠️ truncation"
        case .loadFail:
            return "💥 load-fail"
        case .renderFail:
            return "🛑 render-fail"
        case .lowPrecision:
            return "⚠️ low-precision"
        case .noCall, .none:
            break
        }

        // Mid band: the cell calls tools but imperfectly. A fail-dominant cell with
        // no measured F1 to soften the verdict stays a hard fail; otherwise partial.
        if topVerdict == .fail, meanF1 == nil { return "❌ fail" }
        return "⚠️ partial"
    }

    private static func statusLabel(_ status: CellStatus) -> String {
        switch status {
        case .measured:
            return "✅ measured"
        case .notMeasured(let reason):
            return "🚫 not measured (\(reason))"
        case .loadFail(let reason):
            return "💥 load-fail (\(reason))"
        case .renderFail:
            return "🛑 render-fail"
        }
    }

    /// Tie-break priority for the dominant verdict (lower wins on a count tie),
    /// so output stays deterministic regardless of record order.
    private static func verdictPriority(_ verdict: ConformanceScorer.Verdict) -> Int {
        switch verdict {
        case .fail: return 0
        case .partial: return 1
        case .errored: return 2
        case .pass: return 3
        }
    }

    private static func failureClassPriority(_ failure: FailureClass) -> Int {
        switch failure {
        case .noCall: return 0
        case .lowPrecision: return 1
        case .truncation: return 2
        case .renderFail: return 3
        case .loadFail: return 4
        }
    }

    /// Most frequent element; ties broken by ascending `priority` then stable.
    private static func dominant<T: Hashable>(_ items: [T], priority: (T) -> Int) -> T? {
        guard !items.isEmpty else { return nil }
        var counts: [T: Int] = [:]
        for item in items { counts[item, default: 0] += 1 }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            // Equal counts: the lower priority value wins, so flip the comparison.
            return priority(lhs.key) > priority(rhs.key)
        }?.key
    }

    // MARK: - Formatting

    /// Mean of a non-empty `[Double]`; `0` for an empty input (callers guard the
    /// empty case before deciding to print `—`).
    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Three-decimal fixed format. `String(format:)` without a locale uses the C
    /// locale (always `.`), so output is byte-stable across machines.
    private static func fixed(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// Escapes a Markdown table cell value (the pipe would break the column).
    private static func esc(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }
}
