import Foundation

/// Cache key for a measured tool-calling conformance verdict.
///
/// Tool-call conformance is a property of the **weights × packaging × backend**,
/// not of a device — so the key is `(model × quant × backend)`, mirroring the
/// plan's matrix (`docs/plans/tool-call-conformance.md`). Two artifacts that
/// differ only in quantization can land on opposite sides of the
/// supported/unsupported line, and the backend's renderer/parser moves the rate
/// too, so all three coordinates are load-bearing.
///
/// `quant` is optional because some artifacts (e.g. full-precision or
/// backend-internal formats) carry no meaningful quantization label.
public struct ToolCallConformanceKey: Hashable, Sendable, Codable {

    /// The model identity (e.g. `"Qwen2.5-7B-Instruct"`). Not the file name —
    /// quantization is carried separately so the same weights at different
    /// quants share a model coordinate.
    public let model: String

    /// The quantization label (e.g. `"Q4_K_M"`), or `nil` when the artifact
    /// carries no meaningful quant.
    public let quant: String?

    /// The backend family that rendered and parsed the calls (e.g. `"llama"`,
    /// `"mlx"`, `"ollama"`). The renderer/parser pair is part of the verdict.
    public let backend: String

    public init(model: String, quant: String?, backend: String) {
        self.model = model
        self.quant = quant
        self.backend = backend
    }
}

/// The tool-calling capability verdict for a cache cell.
///
/// `unknown` is the lazy default for any cell that has not been measured — it is
/// never a cold-start tax.
///
/// ## Host policy for `unknown` (#2005)
///
/// A host treats `unknown` tool-call conformance as **"recommend = no;
/// allow-with-warning = host's call"**: don't surface the model as a
/// tool-calling recommendation, but the host may still let the user select it
/// and drive tools behind a warning. Crucially, a **toolless** static template
/// resolves to `unknown`, *not* `unsupported`: MK's own prompt-injection
/// (`ToolSystemPromptBuilder`) can drive tool calls on models whose template
/// declares no tools block (e.g. Mistral-v0.3), so a static `unsupported` would
/// mis-grey a usable model. `unsupported` is reserved for a **measured**
/// near-zero emission verdict.
public enum ToolCallCapability: String, Codable, Sendable {
    /// Measured able to drive tool calls. A positive verdict is measurement-only
    /// — the static layer never writes `supported`.
    case supported
    /// Proven unable — reserved for a **measured** soak that produced ~0%
    /// parseable calls. NOT inferred statically: a toolless template is
    /// `unknown` (see the type doc), because MK prompt-injection can still drive
    /// tools on it.
    case unsupported
    /// Not yet measured, or statically expressible-but-unproven. The default for
    /// an unpopulated cell, and the verdict for every static template (toolless
    /// or tool-bearing) until a soak measures it.
    case unknown
}

/// Which layer of the conformance pipeline produced a verdict.
///
/// Ordered weakest → strongest evidence: a `templateExpressible` positive is
/// only necessary-not-sufficient, whereas `measured` is the authoritative
/// verdict source.
public enum ToolCallConformanceSource: String, Codable, Sendable {
    /// Derived from the chat template alone (`{% if tools %}` present/absent).
    /// Authoritative for the negative; necessary-not-sufficient for the positive.
    case templateExpressible
    /// The static render-consistency check confirmed MK's renderer emits the
    /// template-declared dialect (catches the #1909 class without a soak).
    case renderConsistent
    /// A live soak through the real render+parse path measured the rate. The
    /// only authoritative positive verdict.
    case measured
}

/// A measured tool-calling conformance verdict for one `(model × quant × backend)` cell.
///
/// The analog of `ModelBenchmarkResult`, with one deliberate distinction:
/// `ModelBenchmarkResult` (tokens/sec) is **device-specific** and decays, so it
/// carries a 7-day `isStale`. `ToolCallConformance` is a property of the
/// **weights** — measure it on any machine and it holds on every machine — so it
/// **does not decay** and intentionally carries no TTL / `isStale` helper.
/// `measuredAt` is recorded for provenance, not for expiry.
public struct ToolCallConformance: Sendable, Codable, Equatable {

    /// The verdict for this cell.
    public var capability: ToolCallCapability

    /// The raw dialect family name observed (e.g. `"hermes"`, `"mistral"`).
    /// Kept a `String` to stay decoupled from the `ToolCallDialect` type that
    /// ships in a parallel PR (step 4).
    public var observedDialect: String?

    /// Which layer produced this verdict.
    public var source: ToolCallConformanceSource

    /// Precision of parseable tool calls from the soak, if measured.
    public var precision: Double?

    /// Recall of expected tool calls from the soak, if measured.
    public var recall: Double?

    /// F1 of the soak, if measured.
    public var f1: Double?

    /// When the measurement was taken, for provenance. Not used for expiry —
    /// conformance does not decay.
    public var measuredAt: Date?

    /// How many scenarios/samples backed the measurement. `0` for purely static
    /// (template/render) verdicts.
    public var sampleCount: Int

    public init(
        capability: ToolCallCapability,
        observedDialect: String? = nil,
        source: ToolCallConformanceSource,
        precision: Double? = nil,
        recall: Double? = nil,
        f1: Double? = nil,
        measuredAt: Date? = nil,
        sampleCount: Int = 0
    ) {
        self.capability = capability
        self.observedDialect = observedDialect
        self.source = source
        self.precision = precision
        self.recall = recall
        self.f1 = f1
        self.measuredAt = measuredAt
        self.sampleCount = sampleCount
    }

    /// The lazy default for an unmeasured cell — `unknown`, no dialect, sourced
    /// from the static template layer with zero samples. Returned by a cache for
    /// a key it has never seen.
    public static let unknownDefault = ToolCallConformance(
        capability: .unknown,
        source: .templateExpressible
    )
}

/// Storage-neutral port for persisting measured tool-call conformance verdicts.
///
/// Mirrors ``BenchmarkCache``'s shape: the port trafficks in the
/// ``ToolCallConformance`` value type only — any backing `@Model` never escapes
/// the impl. Keyed by ``ToolCallConformanceKey`` (`model × quant × backend`).
///
/// A missing key returns ``ToolCallConformance/unknownDefault`` rather than
/// `nil`: conformance is lazy and `unknown` until measured, never a cold-start
/// tax. The SwiftData-backed adapter (and its schema migration) is a separate
/// follow-up — this surface ships with an in-memory adapter only.
public protocol ToolCallConformanceCache: Sendable {

    /// Returns the conformance verdict for the given cell, or
    /// ``ToolCallConformance/unknownDefault`` if the cell has never been measured.
    func get(_ key: ToolCallConformanceKey) async -> ToolCallConformance

    /// Stores a verdict for the given cell, replacing any previous entry.
    func put(_ key: ToolCallConformanceKey, _ conformance: ToolCallConformance) async

    /// Returns every cached verdict keyed by cell.
    func fetchAll() async -> [ToolCallConformanceKey: ToolCallConformance]
}

/// In-memory ``ToolCallConformanceCache`` — the write-path spike.
///
/// Proves the `get`/`put` round-trip before anyone wires a SwiftData adapter.
/// An `actor` (not `@unchecked Sendable`) guards the dictionary.
public actor InMemoryToolCallConformanceCache: ToolCallConformanceCache {

    private var storage: [ToolCallConformanceKey: ToolCallConformance]

    public init(seed: [ToolCallConformanceKey: ToolCallConformance] = [:]) {
        self.storage = seed
    }

    public func get(_ key: ToolCallConformanceKey) async -> ToolCallConformance {
        storage[key] ?? .unknownDefault
    }

    public func put(_ key: ToolCallConformanceKey, _ conformance: ToolCallConformance) async {
        storage[key] = conformance
    }

    public func fetchAll() async -> [ToolCallConformanceKey: ToolCallConformance] {
        storage
    }
}
