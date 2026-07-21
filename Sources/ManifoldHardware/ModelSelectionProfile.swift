import Foundation

// This file defines the pure value types for a *selection-time* model descriptor.
// A host reads these to rank candidate models BEFORE committing to loading one —
// including Apple Foundation Models as a zero-download "Tier 0". The whole point
// is that these facts are queryable without instantiating a backend, mirroring the
// `LocalInferenceAdapter.declaredCapabilities` precedent ("read the claims without
// booting the backend"). They complement — and do NOT replace — the runtime fit
// machinery (`ModelLoadPlan`, `ModelFitScorer`): a later step extends the scorer to
// consume these, but the types here carry no logic and no I/O.

/// A product-visible disclosure that a backend may sanitize generated content.
///
/// This is a *selection* decision, not a runtime one: a host ranks candidates by
/// whether their output is subject to a content filter before it ever loads one,
/// so a user who needs unfiltered generation can prefer a model that declares
/// `.none`. Apple Foundation Models ⇒ `.applied` (the OS sanitizes); local
/// GGUF/MLX ⇒ `.none` (no filtering layer); cloud providers ⇒ provider-declared.
/// `.unknown` is the honest default when no claim is available.
public enum ContentFilteringDisclosure: Sendable, Equatable, Codable {
    /// No content-filtering layer is applied (e.g. local GGUF / MLX).
    case none
    /// The backend sanitizes generated content (e.g. Apple Foundation Models).
    case applied
    /// No disclosure is available; the host should not assume either way.
    case unknown
}

/// Where a candidate model physically lives at selection time.
///
/// Distinct from the catalog's `DownloadState`: that tracks *live* progress
/// (queued / downloading / failed, with byte counters that change as a transfer
/// runs). `ResidencyState` is the *static* selection-time fact — what it would
/// take to make this model usable right now — so the recommender can rank a
/// zero-download OS-resident model against an N-byte pull without subscribing to
/// any download machinery.
public enum ResidencyState: Sendable, Equatable {
    /// Provided by the OS with zero download (e.g. Apple Foundation Models).
    case osResident
    /// Already present on disk; usable without a network transfer.
    case downloaded
    /// Not yet present; would require pulling `sizeBytes` bytes to use.
    case downloadable(sizeBytes: UInt64)
}

/// A selection-time descriptor a host reads to rank a model before loading it.
///
/// Every field is a claim that can be answered without instantiating a backend —
/// the `LocalInferenceAdapter.declaredCapabilities` precedent. The recommender
/// uses these to order candidates (footprint vs. device memory, MoE decode speed
/// via active-parameter bytes, context budget, filtering disclosure) so the
/// "which model should I pick?" decision happens entirely pre-boot.
public struct ModelSelectionProfile: Sendable, Equatable {
    /// Stable identifier for the model this profile describes.
    public let modelID: String
    /// Where the model lives at selection time (OS-resident, on disk, or a pull).
    public let residency: ResidencyState
    /// Estimated total resident + KV footprint from a load plan, in bytes.
    ///
    /// `nil` when unknown (e.g. an OS-resident model whose internals are opaque).
    /// Lets the recommender compare a candidate's memory cost against device RAM
    /// before loading.
    public let estimatedFootprintBytes: UInt64?
    /// Quantized bytes streamed per decode token-pass, in bytes.
    ///
    /// For mixture-of-experts models only a subset of weights is touched per token,
    /// so this is smaller than the resident footprint and is the right proxy for
    /// decode throughput. `nil` means dense or unknown — fall back to footprint.
    public let activeParameterBytes: UInt64?
    /// Whether generated content is subject to a backend content filter.
    public let contentFiltering: ContentFilteringDisclosure
    /// Declared maximum context length in tokens, or `nil` when not advertised.
    public let declaredContextLength: Int?

    public init(
        modelID: String,
        residency: ResidencyState,
        estimatedFootprintBytes: UInt64? = nil,
        activeParameterBytes: UInt64? = nil,
        contentFiltering: ContentFilteringDisclosure,
        declaredContextLength: Int? = nil
    ) {
        self.modelID = modelID
        self.residency = residency
        self.estimatedFootprintBytes = estimatedFootprintBytes
        self.activeParameterBytes = activeParameterBytes
        self.contentFiltering = contentFiltering
        self.declaredContextLength = declaredContextLength
    }
}

/// A single rankable entry in a model recommendation list.
///
/// Unifies two otherwise-incompatible shapes so the recommender can rank an
/// OS-resident "Tier 0" model (described by a `ModelSelectionProfile`) in the same
/// ordered list as downloadable upgrades (described by `DownloadableModel`). Without
/// this, Tier 0 would have to live in a separate code path and could never be
/// compared head-to-head against a model the user could download.
///
/// ## The `.resident` seam — host-constructs, not yet wired by any shipped path
///
/// As of the 2026-07-03 inert-surface audit (re-confirmed in the 2026-07
/// #2128 sweep), no production code path constructs a `.resident` case.
/// `Sources/ManifoldKit/QuickStartSeed.swift` maps every seed to
/// `.downloadable(...)`, so `ModelFitScorer.scoreResident(...)` and the
/// `.resident` branches of `score(candidate:)`/`rank(candidates:)` never run
/// in the shipped app. This is a real, tested capability with no wired
/// producer yet — not dead code — and it stays public because a host
/// supplies the missing producer itself, the same way `ModelSelectionProfile`
/// documents itself as reachable "without instantiating a backend."
///
/// A host that wants the "Apple Foundation Models as an instant Tier 0"
/// unified ranking (described in `ManifoldUIModelManagement`'s
/// "Device-Aware Model Recommendations" DocC article) builds one
/// `.resident` candidate per OS-resident model and mixes it into the same
/// candidate list as its `.downloadable` entries:
///
/// ```swift,no-build
/// import ManifoldHardware
///
/// // Your candidate models — replace with the results of a HuggingFace search
/// // or a curated catalog. Empty here so the snippet stands alone.
/// let searchResults: [DownloadableModel] = []
///
/// let foundationCandidate = ModelSelectionCandidate.resident(
///     ModelSelectionProfile(
///         modelID: "apple-foundation",
///         residency: .osResident,
///         contentFiltering: .applied,       // Apple FM sanitizes output
///         declaredContextLength: 4096
///     )
/// )
///
/// let downloadableCandidates: [ModelSelectionCandidate] = searchResults.map { .downloadable($0) }
///
/// let ranked = ModelFitScorer().rank(
///     candidates: [foundationCandidate] + downloadableCandidates,
///     useCase: .chat,
///     device: .current,
///     foundationAvailable: true
/// )
/// ```
///
/// When `foundationAvailable` is `false`, every `.resident` candidate
/// collapses to the bottom of the ranking exactly like a model that won't
/// load on this device — there is no separate "unavailable" code path to
/// handle.
public enum ModelSelectionCandidate: Sendable {
    /// A model already usable now — OS-resident or on disk — with its profile.
    case resident(ModelSelectionProfile)
    /// A model that would need downloading, with its catalog entry.
    case downloadable(DownloadableModel)
}
