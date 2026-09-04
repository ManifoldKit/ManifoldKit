import Foundation

/// The single normalized result record every eval leg emits — one row per
/// evaluated cell, the `(model × quant × backend × renderer)` tuple run against
/// one scenario at one decoy level and repeat index.
///
/// It exists so the Ollama, llama.cpp, MLX, and cloud legs — which run in
/// *separate processes* because `llama_backend_init` is once-per-process and MLX
/// needs serialized in-process Metal (see `docs/HARDWARE-TOOLCHAIN.md`) — can
/// each emit the same shape, and a downstream collator can fold them into one
/// matrix without re-deriving per-backend vocabulary. It mirrors the
/// `ConformanceScorer.ResultRow` outputs (the
/// assertion-derived ``ConformanceScorer/Verdict`` and the tool-selection
/// precision/recall/F1) but adds the cell-identity coordinates and, crucially,
/// a first-class ``CellStatus``.
///
/// `notMeasured` is a distinct ``CellStatus`` case — **absence is not failure.**
/// A missing GGUF, an unavailable backend, or a skipped cell must read as
/// `notMeasured`, never as a `fail` ``ConformanceScorer/Verdict``: scoring a hole
/// in the matrix as a failure is exactly the "empty CSV reads as measured" defect
/// this schema was added to kill. When `status` is anything other than
/// `.measured`, `verdict` and `toolSelection` are `nil` — there is no measurement
/// to carry.
public struct ConformanceRecord: Codable, Sendable, Equatable {

    // MARK: Cell identity — the (model × quant × backend × renderer) tuple

    /// Backend family that drove the run, e.g. `"ollama"`, `"llama.cpp"`,
    /// `"mlx"`, `"openrouter"`. Matches `ConformanceScorer.ResultRow.backend`'s
    /// vocabulary (non-optional here: a record always names the cell it measured).
    public let backend: String

    /// Logical model id, e.g. `"mistral-7b-instruct-v0.3"`.
    public let model: String

    /// Quantization / weight label, e.g. `"Q4_K_M"`, `"4bit"`, `"server"`,
    /// `"cloud"`. Mirrors `ConformanceScorer.ResultRow.quant`.
    public let quant: String

    /// The prompt-rendering path exercised, e.g. `"ollama-server"`,
    /// `"jinja-prompt"`, `"swift-transformers"`, `"native"`. Not present on the
    /// scorer row — it is the dimension cross-backend twin-divergence is attributed
    /// to: a divergence needs a same-bytes control before it's a renderer bug.
    public let renderer: String

    // MARK: Scenario coordinates

    /// Scenario id, matching `TranscriptLogger.Event.prompt`'s `scenarioId`.
    public let scenario: String

    /// Number of decoy/distractor tools advertised alongside the required set
    /// (the `--extra-tools N` knob surfaced as `advertisedTools` in the
    /// transcript). `0` for a baseline run.
    public let decoyLevel: Int

    /// Which repetition of an otherwise-identical cell this is. Named
    /// `repeatIndex` because `repeat` is a Swift keyword. Repeats exist so a
    /// verdict-class regression detector can see the 0.10–0.12 F1 run-to-run swing
    /// rather than trust a single sample.
    public let repeatIndex: Int

    // MARK: Outcome

    /// Whether the cell was actually measured, and if not, why. First-class so a
    /// hole in the matrix is never confused with a measured failure.
    public let status: CellStatus

    /// The assertion-derived scenario verdict — reusing the scorer's own
    /// ``ConformanceScorer/Verdict`` (`pass` / `partial` / `fail` / `errored`)
    /// rather than a competing two-case enum, so the record carries exactly what
    /// `ConformanceScorer.ResultRow` produces. `nil` when `status != .measured`.
    public let verdict: ConformanceScorer.Verdict?

    /// Tool-selection precision/recall/F1 for this cell — the same metric the
    /// MLX/llama soak CLIs and `ConfusionCounts` report. `nil` for a no-tool
    /// scenario (an empty expected set is not a tool-selection class) or when the
    /// cell was not measured.
    public let toolSelection: Scores?

    /// Coarse failure bucket when something went wrong, for at-a-glance matrix
    /// triage. `nil` on a clean `pass`.
    public let failureClass: FailureClass?

    // MARK: Provenance

    /// Path to (or content hash of) the raw `TranscriptLogger` JSONL this record
    /// was reduced from, so a human can always re-read the transcript that
    /// produced a verdict and keep the human transcript spot-check in the loop.
    public let transcriptRef: String

    /// The ManifoldKit core commit the run was built from — runs are only
    /// comparable across the same core binary (eval drivers share the core
    /// binary; never rebuild mid-eval).
    public let coreCommit: String

    /// Tooling/runtime versions that shaped the run (e.g. `"ollama": "0.5.4"`,
    /// `"mlx": "0.18.0"`), so environment drift doesn't read as a regression.
    public let toolingVersions: [String: String]

    public init(
        backend: String,
        model: String,
        quant: String,
        renderer: String,
        scenario: String,
        decoyLevel: Int,
        repeatIndex: Int,
        status: CellStatus,
        verdict: ConformanceScorer.Verdict?,
        toolSelection: Scores?,
        failureClass: FailureClass?,
        transcriptRef: String,
        coreCommit: String,
        toolingVersions: [String: String]
    ) {
        self.backend = backend
        self.model = model
        self.quant = quant
        self.renderer = renderer
        self.scenario = scenario
        self.decoyLevel = decoyLevel
        self.repeatIndex = repeatIndex
        self.status = status
        self.verdict = verdict
        self.toolSelection = toolSelection
        self.failureClass = failureClass
        self.transcriptRef = transcriptRef
        self.coreCommit = coreCommit
        self.toolingVersions = toolingVersions
    }
}

/// Whether a cell was measured, and — when it wasn't — why. The non-`measured`
/// cases are the whole reason this type exists: a hole in the matrix (missing
/// weights, dead backend, a render that never produced a prompt) is a *state*,
/// distinct from a measured `fail` ``ConformanceScorer/Verdict``.
public enum CellStatus: Codable, Sendable, Equatable {
    /// The cell ran end-to-end and produced a scorable transcript.
    case measured
    /// The cell was deliberately not run (e.g. weights absent, backend offline).
    /// The associated string is a human-readable reason for the hole.
    case notMeasured(String)
    /// The model/weights failed to load. The associated string carries the
    /// load error for triage.
    case loadFail(String)
    /// Prompt rendering produced no usable prompt, so no inference ran.
    case renderFail

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    private enum Kind: String, Codable {
        case measured
        case notMeasured
        case loadFail
        case renderFail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .measured:
            self = .measured
        case .notMeasured:
            let reason = try container.decode(String.self, forKey: .reason)
            self = .notMeasured(reason)
        case .loadFail:
            let reason = try container.decode(String.self, forKey: .reason)
            self = .loadFail(reason)
        case .renderFail:
            self = .renderFail
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .measured:
            try container.encode(Kind.measured, forKey: .kind)
        case .notMeasured(let reason):
            try container.encode(Kind.notMeasured, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .loadFail(let reason):
            try container.encode(Kind.loadFail, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .renderFail:
            try container.encode(Kind.renderFail, forKey: .kind)
        }
    }
}

/// Coarse failure bucket for at-a-glance matrix triage. Orthogonal to
/// ``CellStatus``: `loadFail`/`renderFail` mirror the un-measured states, while
/// `noCall`/`lowPrecision`/`truncation` classify *measured* failures.
public enum FailureClass: String, Codable, Sendable {
    /// The model emitted no tool call where one was required.
    case noCall
    /// Prompt rendering failed (mirrors ``CellStatus/renderFail``).
    case renderFail
    /// Model/weights failed to load (mirrors ``CellStatus/loadFail``).
    case loadFail
    /// A tool call was made but selection precision was below threshold (decoys
    /// or wrong tools called).
    case lowPrecision
    /// Generation was truncated before the call could complete.
    case truncation
}

/// A Codable snapshot of tool-selection precision / recall / F1 for one cell.
///
/// Mirrors the `precision`/`recall`/`f1` carried by the core `ConfusionCounts` /
/// `MacroAveragedMetrics`, but is a self-contained `Codable` value so the record
/// round-trips without making those `ManifoldInference` metric types `Codable`
/// (that surface belongs to another module).
public struct Scores: Codable, Sendable, Equatable {
    public let precision: Double
    public let recall: Double
    public let f1: Double

    public init(precision: Double, recall: Double, f1: Double) {
        self.precision = precision
        self.recall = recall
        self.f1 = f1
    }
}
