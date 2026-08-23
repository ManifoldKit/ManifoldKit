import Foundation

/// Cache key for a measured tool-calling conformance verdict.
///
/// Tool-call conformance is a property of the **weights × packaging × backend**,
/// not of a device — so the key is `(model × quant × backend)`, mirroring the
/// architecture's matrix (`docs/plans/tool-calling-architecture.md`). Two artifacts that
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
    /// from the static template layer with zero samples.
    public static let unknownDefault = ToolCallConformance(
        capability: .unknown,
        source: .templateExpressible
    )
}

// The storage-neutral `ToolCallConformanceCache` port, its
// `InMemoryToolCallConformanceCache` spike, and the SwiftData-backed adapter
// were removed 2026-07-22 (issue #2128 inert-surface sweep): the read/write
// path was never wired — no `ManifoldBootstrap.toolCallConformanceCache`
// reader existed in-repo, and the 2026-07-22 eight-consumer screen (all apps
// + manifold-eval + both companions) found zero external adopters. The value
// types above (`ToolCallConformanceKey`/`ToolCallCapability`/
// `ToolCallConformanceSource`/`ToolCallConformance`) are retained — they are
// the dialect vocabulary the companion backends consume — and the
// `ToolCallConformanceRecord` `@Model` + its V11 schema stay put to avoid a
// lightweight-migration bump (see docs/MIGRATION-inert-surface-sweep-2026-07-22.md).
