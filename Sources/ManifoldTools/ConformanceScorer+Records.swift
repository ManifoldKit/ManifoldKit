import Foundation
import ManifoldInference

/// Emits the normalized ``ConformanceRecord`` schema (the cross-leg eval row added
/// in #2041) from a scored transcript.
///
/// This is the single source that turns a `TranscriptLogger` JSONL into
/// `[ConformanceRecord]`, so the Ollama / llama.cpp / MLX / cloud legs — and the
/// companion manifold-mlx / manifold-llama repos — all emit the *same* shape
/// instead of hand-rolling a per-leg `SUMMARY`. It reuses the one parse pass in
/// ``ConformanceScorer/resolve(jsonl:)`` (so the expected-set recovery #2005 and
/// TP attribution #2043 apply identically) and maps each resolved row to a
/// `.measured` record.
///
/// **Absence is not failure.** A transcript that is missing, unreadable, or empty
/// (the model didn't load, the GGUF was absent, the backend was offline) must NOT
/// be dropped silently and must NOT read as a measured zero. When the caller names
/// the cell it expected via ``ExpectedCell``, the file-based emitter returns a
/// single record carrying ``CellStatus/notMeasured(_:)`` / ``CellStatus/loadFail(_:)``
/// instead — the load-bearing distinction ``ConformanceRecord`` exists to preserve.
extension ConformanceScorer {

    /// Caller-supplied provenance the transcript itself doesn't carry.
    ///
    /// - `renderer`: the prompt-rendering path exercised (e.g. `"ollama-server"`,
    ///   `"jinja-prompt"`, `"swift-transformers"`). The transcript never records
    ///   this, so it is a **caller-declared label**, not a measured value — pass
    ///   the renderer the leg was configured with.
    /// - `coreCommit`: the ManifoldKit core commit the eval binary was built from.
    ///   Runs are only comparable across the same core binary. Resolve it from the
    ///   build (git SHA) and pass it in; use a documented placeholder (e.g.
    ///   `"unknown"`) when it can't be resolved.
    public struct RecordContext: Sendable, Equatable {
        public let renderer: String
        public let coreCommit: String
        public let toolingVersions: [String: String]
        public let transcriptRef: String

        public init(
            renderer: String,
            coreCommit: String,
            toolingVersions: [String: String] = [:],
            transcriptRef: String
        ) {
            self.renderer = renderer
            self.coreCommit = coreCommit
            self.toolingVersions = toolingVersions
            self.transcriptRef = transcriptRef
        }
    }

    /// The cell a transcript was *supposed* to measure, so an absent/empty/unreadable
    /// transcript produces a `.notMeasured`/`.loadFail` record for the right
    /// coordinates instead of a silently-dropped row.
    public struct ExpectedCell: Sendable, Equatable {
        public let backend: String
        public let model: String
        public let quant: String
        public let scenario: String
        public let decoyLevel: Int
        public let repeatIndex: Int

        public init(
            backend: String,
            model: String,
            quant: String,
            scenario: String,
            decoyLevel: Int = 0,
            repeatIndex: Int = 0
        ) {
            self.backend = backend
            self.model = model
            self.quant = quant
            self.scenario = scenario
            self.decoyLevel = decoyLevel
            self.repeatIndex = repeatIndex
        }
    }

    /// Maps a scored JSONL transcript to `.measured` ``ConformanceRecord`` rows —
    /// one per (backend × model × quant × scenario) group the scorer produces.
    ///
    /// Returns `[]` for an empty transcript; callers that need the absence handled
    /// as an explicit hole should use ``records(fileAt:context:expectedCell:)`` with
    /// an ``ExpectedCell``.
    public static func records(jsonl text: String, context: RecordContext) -> [ConformanceRecord] {
        resolve(jsonl: text).map { record(from: $0, context: context) }
    }

    /// Scores a transcript file and emits ``ConformanceRecord`` rows, handling the
    /// absence case so a hole in the matrix is never confused with a failure.
    ///
    /// - An unreadable file (e.g. the run never wrote a transcript because the
    ///   weights failed to load) → one ``CellStatus/loadFail(_:)`` record for
    ///   `expectedCell`.
    /// - A non-UTF-8 / empty transcript (no scorable rows) → one
    ///   ``CellStatus/notMeasured(_:)`` record for `expectedCell`.
    /// - When `expectedCell` is `nil`, the absence cases return `[]` (the caller
    ///   chose not to name a cell, so there is nothing to attribute the hole to).
    ///
    /// This method does not throw: an unreadable transcript is data about the cell,
    /// not a programming error to propagate.
    public static func records(
        fileAt url: URL,
        context: RecordContext,
        expectedCell: ExpectedCell? = nil
    ) -> [ConformanceRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // The transcript could not be read — most often because the run never
            // produced one (missing GGUF, backend offline). That is a load hole,
            // not a measured failure.
            if let cell = expectedCell {
                return [notMeasuredRecord(cell, context: context, status: .loadFail("transcript unreadable: \(error)"))]
            }
            return []
        }
        guard let text = String(data: data, encoding: .utf8) else {
            if let cell = expectedCell {
                return [notMeasuredRecord(cell, context: context, status: .notMeasured("transcript not valid UTF-8"))]
            }
            return []
        }
        let rows = resolve(jsonl: text)
        guard !rows.isEmpty else {
            if let cell = expectedCell {
                return [notMeasuredRecord(cell, context: context, status: .notMeasured("transcript empty: no scorable rows"))]
            }
            return []
        }
        return rows.map { record(from: $0, context: context) }
    }

    /// Builds a single un-measured record for a named cell. `verdict` and
    /// `toolSelection` are `nil` (there is no measurement); `failureClass` mirrors
    /// the load/render holes so matrix triage can bucket them.
    public static func notMeasuredRecord(
        _ cell: ExpectedCell,
        context: RecordContext,
        status: CellStatus
    ) -> ConformanceRecord {
        let failure: FailureClass?
        switch status {
        case .loadFail:
            failure = .loadFail
        case .renderFail:
            failure = .renderFail
        case .notMeasured, .measured:
            failure = nil
        }
        return ConformanceRecord(
            backend: cell.backend,
            model: cell.model,
            quant: cell.quant,
            renderer: context.renderer,
            scenario: cell.scenario,
            decoyLevel: cell.decoyLevel,
            repeatIndex: cell.repeatIndex,
            status: status,
            verdict: nil,
            toolSelection: nil,
            failureClass: failure,
            transcriptRef: context.transcriptRef,
            coreCommit: context.coreCommit,
            toolingVersions: context.toolingVersions
        )
    }

    /// Pretty-printed, stable-key JSON for a record array (the `--emit-records`
    /// payload). Overloads the ``ResultRow`` encoder of the same name.
    public static func encodeJSON(_ records: [ConformanceRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(records)
    }

    // MARK: - Internal mapping

    /// Maps one measured ``ResolvedRow`` to a `.measured` ``ConformanceRecord``.
    ///
    /// `repeatIndex` comes from `row.repeatIndex`, which the scorer recovers
    /// from the transcript's per-record `repeatIndex` stamp (written by
    /// ``TranscriptLogger`` when the CLI's `--repeat-index` flag is set) —
    /// the grouping key includes it alongside backend/model/quant/scenario, so
    /// repeats of the same cell appended into one transcript resolve to
    /// separate rows instead of merging. A transcript that never stamped a
    /// repeat index (older runs, or callers that don't pass `--repeat-index`)
    /// resolves to `0`, matching the field's pre-repeat default.
    static func record(from row: ResolvedRow, context: RecordContext) -> ConformanceRecord {
        // Decoy pressure = the count of decoy distractors advertised this run.
        // Current transcripts advertise decoys under their real names, so
        // membership in the shared `DecoyTools` pool isolates them (the pool is
        // disjoint from the six reference tools by contract — see DecoyTools).
        // Transcripts recorded before the shared pool used a `decoy_tool_<n>_<base>`
        // name prefix instead; keep that prefix check as a legacy fallback so old
        // transcripts still score. The two name families are disjoint (no pool
        // entry starts with `decoy_tool_`), so summing the counts is exact for
        // both generations and for any mixed transcript.
        let poolNames = Set(DecoyTools.names(DecoyTools.maxCount))
        let decoyLevel = row.advertisedTools.filter {
            poolNames.contains($0) || $0.hasPrefix("decoy_tool_")
        }.count

        // Absence is not failure. A group that never produced a model turn — or that
        // recorded an explicit infra error — was not measured: the backend rejected
        // the model (e.g. a 404 on a nonexistent Ollama tag) before any generation.
        // Scoring that as a measured `noCall` fabricates a false zero that pollutes
        // the conformance matrix (#2087). Emit a non-measured hole instead, keying it
        // to the cell the transcript names. `errored` takes precedence: a run that
        // produced a partial turn (some tokens / a tool call) and *then* threw is an
        // interrupted generation, not a clean measurement, so the hole wins over the
        // partial signal.
        if row.errored || !row.producedModelTurn {
            let cell = ExpectedCell(
                backend: row.backend ?? "unknown",
                model: row.model ?? "unknown",
                quant: row.quant ?? "unknown",
                scenario: row.scenario,
                decoyLevel: decoyLevel,
                repeatIndex: row.repeatIndex
            )
            // An explicit `error` event is a positive infra-failure signal → a
            // `loadFail` (💥) hole, unless the message carries the one
            // distinguishable prompt-rendering-failure signal available today:
            // `PromptRenderer.render` throws `InferenceError.inferenceFailure`
            // prefixed with `InferenceError.promptRenderFailurePrefix` when an
            // embedded chat template can't be rendered and the enum fallback
            // can't carry the requested tools. That case routes to `.renderFail`
            // instead, so the matrix distinguishes "no usable prompt" from a
            // generic backend/infra error. A bare prompt-only transcript is the
            // same failure observed only by absence → `notMeasured` (🚫).
            let status: CellStatus
            if row.errored, let message = row.errorMessage, message.contains(InferenceError.promptRenderFailurePrefix) {
                status = .renderFail
            } else if row.errored {
                status = .loadFail(row.errorMessage ?? "backend reported an error before a model turn")
            } else {
                status = .notMeasured("transcript has a prompt but no model turn — the backend rejected the model before generation (#2087)")
            }
            return notMeasuredRecord(cell, context: context, status: status)
        }

        let verdict = row.verdict
        let toolSelection: Scores? = row.isToolBearing
            ? Scores(
                precision: row.confusion.precision,
                recall: row.confusion.recall,
                f1: row.confusion.f1
            )
            : nil
        return ConformanceRecord(
            backend: row.backend ?? "unknown",
            model: row.model ?? "unknown",
            quant: row.quant ?? "unknown",
            renderer: context.renderer,
            scenario: row.scenario,
            decoyLevel: decoyLevel,
            repeatIndex: row.repeatIndex,
            status: .measured,
            verdict: verdict,
            toolSelection: toolSelection,
            failureClass: failureClass(for: row, verdict: verdict),
            transcriptRef: context.transcriptRef,
            coreCommit: context.coreCommit,
            toolingVersions: context.toolingVersions
        )
    }

    /// Coarse failure bucket for a *measured* row. `nil` on a clean pass.
    static func failureClass(for row: ResolvedRow, verdict: Verdict) -> FailureClass? {
        guard verdict != .pass else { return nil }
        // Required a tool but called none → the model under-called.
        if row.isToolBearing && row.calledTools.isEmpty { return .noCall }
        // Called wrong/extra tools (decoys or off-target) → low selection precision.
        if row.confusion.fp > 0 { return .lowPrecision }
        return nil
    }
}
