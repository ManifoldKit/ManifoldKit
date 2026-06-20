import Foundation

/// Unified pre-load decision for a model.
///
/// Captures the context-clamp and memory-fit decisions in a single value. Backends
/// consume a plan directly via `InferenceBackend.loadModel(from:plan:)`; UI builds
/// one via `ModelLoadPlan.compute(for:requestedContextSize:strategy:)` so every
/// load path sees the same authoritative context and verdict.
public struct ModelLoadPlan: Sendable {

    /// Conservative per-token KV-cache cost (bytes) for callers that build ``Inputs``
    /// directly without GGUF metadata to read.
    ///
    /// Most app-side fit checks should prefer the fully-public, canonical pre-download
    /// entry point ``estimate(for:requestedContextSize:environment:absoluteContextCeiling:headroomFraction:)``,
    /// which derives the ``MemoryStrategy`` from ``DownloadableModel/modelType`` and applies
    /// this fallback internally. Reach for this constant only when constructing an ``Inputs``
    /// value by hand (e.g. a host serving a curated/recommended shelf with only manifest-level
    /// fields) — it lets callers stay on the public surface instead of importing the
    /// `@_spi(BackendInternals)` ``GGUFKVCacheEstimator``.
    ///
    /// This is the legacy 8 KB/token heuristic: conservative versus real grouped-query-attention
    /// architectures (which are typically cheaper per token), so a verdict computed with it is at
    /// least as strict as the post-download `compute(...)` path for the same inputs.
    ///
    /// Single source of truth — this aliases the SPI estimator's
    /// `GGUFKVCacheEstimator.legacyFallbackBytesPerToken` so the public constant and the
    /// internal heuristic can never drift (a unit test asserts the two stay equal).
    public static let conservativeFallbackBytesPerToken: UInt64 =
        GGUFKVCacheEstimator.legacyFallbackBytesPerToken

    /// The raw inputs a plan was computed from. Captured on the plan so callers can
    /// log, diff, or re-evaluate with different parameters without re-querying state.
    public struct Inputs: Sendable, Equatable {
        public let modelFileSize: UInt64
        public let memoryStrategy: MemoryStrategy
        public let requestedContextSize: Int
        public let trainedContextLength: Int?
        public let kvBytesPerToken: UInt64
        public let availableMemoryBytes: UInt64
        public let physicalMemoryBytes: UInt64
        public let absoluteContextCeiling: Int
        public let headroomFraction: Double
        public let appOverheadBytes: UInt64
        /// Measured per-token resident cost learned during a prior prefill
        /// (see ``PrefillFootprintEstimator``). When present and non-zero it
        /// overrides ``kvBytesPerToken`` for the memory-ceiling math, letting the
        /// plan recompute `effectiveContextSize` against a *measured* budget. `nil`
        /// (the default) leaves the static heuristic path byte-for-byte unchanged.
        public let measuredBytesPerToken: UInt64?

        public init(
            modelFileSize: UInt64,
            memoryStrategy: MemoryStrategy,
            requestedContextSize: Int,
            trainedContextLength: Int?,
            kvBytesPerToken: UInt64,
            availableMemoryBytes: UInt64,
            physicalMemoryBytes: UInt64,
            absoluteContextCeiling: Int,
            headroomFraction: Double,
            appOverheadBytes: UInt64 = 0,
            measuredBytesPerToken: UInt64? = nil
        ) {
            self.modelFileSize = modelFileSize
            self.memoryStrategy = memoryStrategy
            self.requestedContextSize = requestedContextSize
            self.trainedContextLength = trainedContextLength
            self.kvBytesPerToken = kvBytesPerToken
            self.availableMemoryBytes = availableMemoryBytes
            self.physicalMemoryBytes = physicalMemoryBytes
            self.absoluteContextCeiling = absoluteContextCeiling
            self.headroomFraction = headroomFraction
            self.appOverheadBytes = appOverheadBytes
            self.measuredBytesPerToken = measuredBytesPerToken
        }
    }

    /// The decision produced from an `Inputs`. Decoupled from `Inputs` so UI code can
    /// show the verdict summary without re-carrying every input field.
    public struct Outcome: Sendable, Equatable {
        public let effectiveContextSize: Int
        public let estimatedResidentBytes: UInt64
        public let estimatedKVBytes: UInt64
        public let totalEstimatedBytes: UInt64
        public let verdict: Verdict
        /// Info-only reasons (clamps) may appear even when `verdict == .allow`.
        public let reasons: [Reason]

        public init(
            effectiveContextSize: Int,
            estimatedResidentBytes: UInt64,
            estimatedKVBytes: UInt64,
            totalEstimatedBytes: UInt64,
            verdict: Verdict,
            reasons: [Reason]
        ) {
            self.effectiveContextSize = effectiveContextSize
            self.estimatedResidentBytes = estimatedResidentBytes
            self.estimatedKVBytes = estimatedKVBytes
            self.totalEstimatedBytes = totalEstimatedBytes
            self.verdict = verdict
            self.reasons = reasons
        }
    }

    public let inputs: Inputs
    public let outcome: Outcome

    public init(inputs: Inputs, outcome: Outcome) {
        self.inputs = inputs
        self.outcome = outcome
    }

    // MARK: - Convenience pass-throughs

    public var effectiveContextSize: Int { outcome.effectiveContextSize }
    public var verdict: Verdict { outcome.verdict }
    public var reasons: [Reason] { outcome.reasons }

    // MARK: - Verdict / Reason

    public enum Verdict: Sendable, Equatable {
        /// Safe to proceed.
        case allow
        /// Tight fit — may work but risks swapping / pressure.
        case warn
        /// Insufficient memory — loading will likely fail.
        case deny
    }

    public enum Reason: Sendable, Equatable {
        case insufficientResident(required: UInt64, available: UInt64)
        case insufficientKVCache(required: UInt64, available: UInt64)
        /// Info-only: requested context exceeded the model's trained length, clamped.
        case trainedContextExceeded(requested: Int, trained: Int)
        /// Info-only: requested context exceeded the absolute ceiling, clamped.
        case absoluteCeilingReached(requested: Int, ceiling: Int)
        /// Info-only: requested context exceeded what memory allows, clamped.
        case memoryCeilingReached(requested: Int, ceiling: Int)
    }

    // MARK: - Environment

    /// Injects system-memory queries so tests (and callers that want to evaluate
    /// hypothetical devices) can avoid hitting the real OS.
    public struct Environment: Sendable {
        public let availableMemoryBytes: @Sendable () -> UInt64
        public let physicalMemoryBytes: UInt64

        public init(
            availableMemoryBytes: @escaping @Sendable () -> UInt64,
            physicalMemoryBytes: UInt64
        ) {
            self.availableMemoryBytes = availableMemoryBytes
            self.physicalMemoryBytes = physicalMemoryBytes
        }

        /// Real-device environment backed by `DeviceCapabilityService.queryAvailableMemory`
        /// and `ProcessInfo.physicalMemory`.
        public static let current: Environment = Environment(
            availableMemoryBytes: { DeviceCapabilityService.queryAvailableMemory() },
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    // MARK: - Computation

    /// Primary entry point. All state must be pre-materialised on the `Inputs`.
    public static func compute(inputs: Inputs) -> ModelLoadPlan {
        let strategy = inputs.memoryStrategy
        let available = inputs.availableMemoryBytes
        let headroom = inputs.headroomFraction

        // Subtract platform app overhead before KV budget math. On iOS the jetsam limit
        // is below `recommendedMaxWorkingSetSize`; leaving no headroom for SwiftData, UI,
        // and OS bookkeeping causes SIGKILL. See issue #471.
        let effective_available = available > inputs.appOverheadBytes
            ? available - inputs.appOverheadBytes
            : 0

        // Resident budget: full weights for .resident, a mmap-style fraction for .mappable.
        // .external keeps the legacy behaviour of "no local weight memory" — 0 resident.
        let residentBudget: UInt64
        switch strategy {
        case .resident:
            residentBudget = inputs.modelFileSize
        case .mappable:
            // Mappable heuristic: min(fileSize/4, 1 GB). mmap-backed loads only need
            // a fraction of the file resident in RAM for active working pages.
            //
            // BUT: even with mmap, a file that is wildly larger than the device's
            // available RAM cannot stream through the page cache without
            // catastrophic thrashing — llama.cpp will either crash or appear to
            // hang. The 1 GB cap alone silently allows e.g. a 140 GB 70B model on
            // a 4 GB iPad. Guard against that below via `impossibleFitRatio`.
            let oneGB: UInt64 = 1_073_741_824
            residentBudget = min(inputs.modelFileSize / 4, oneGB)
        case .external:
            residentBudget = 0
        }

        // KV budget: what's left of available memory after the resident reserve, minus
        // the caller-specified headroom fraction. Saturating subtraction so we never
        // underflow UInt64 when resident > available * (1 - headroom).
        let reserveAfterHeadroom = UInt64(Double(effective_available) * (1.0 - headroom))
        let kvBudget: UInt64 = reserveAfterHeadroom > residentBudget
            ? reserveAfterHeadroom - residentBudget
            : 0

        // Per-token cost for the memory math. Prefer a measured estimate (learned
        // from a real prefill) when one diverges from the heuristic; fall back to
        // the static `kvBytesPerToken` otherwise. When no measurement exists this
        // resolves to `kvBytesPerToken`, keeping the static path byte-for-byte
        // identical to the pre-adaptive behaviour.
        let effectiveBytesPerToken: UInt64
        if let measured = inputs.measuredBytesPerToken, measured > 0 {
            effectiveBytesPerToken = measured
        } else {
            effectiveBytesPerToken = inputs.kvBytesPerToken
        }

        // Memory-derived token ceiling. Guarding against div-by-zero when the caller
        // passed kvBytesPerToken == 0 (shouldn't happen in practice, but cheap to be safe).
        let memoryCeiling: Int = effectiveBytesPerToken == 0
            ? Int.max
            : Int(kvBudget / effectiveBytesPerToken)

        // Walk the ceilings in turn, recording a `Reason` each time a tighter bound wins.
        // `effective` tracks the winning value; we re-check against `requestedContextSize`
        // for the "clamped" comparison so reasons report what the user asked for, not the
        // already-reduced interim value.
        var reasons: [Reason] = []
        var effective = inputs.requestedContextSize

        let trainedCeiling = inputs.trainedContextLength
        if let trained = trainedCeiling, trained < effective {
            reasons.append(.trainedContextExceeded(
                requested: inputs.requestedContextSize,
                trained: trained
            ))
            effective = trained
        }

        if inputs.absoluteContextCeiling < effective {
            reasons.append(.absoluteCeilingReached(
                requested: inputs.requestedContextSize,
                ceiling: inputs.absoluteContextCeiling
            ))
            effective = inputs.absoluteContextCeiling
        }

        if memoryCeiling < effective {
            reasons.append(.memoryCeilingReached(
                requested: inputs.requestedContextSize,
                ceiling: memoryCeiling
            ))
            effective = memoryCeiling
        }

        // Never pass 0 / negative to llama.cpp, even in pathological near-zero memory.
        let effectiveContextSize = max(1, effective)

        let estimatedKV = UInt64(effectiveContextSize) * effectiveBytesPerToken
        let total = residentBudget &+ estimatedKV  // residentBudget is already bounded

        // Impossible-fit guard: regardless of strategy, a model file that is
        // dramatically larger than the device's available RAM cannot load
        // successfully. Under `.mappable`, the residentBudget heuristic caps at
        // 1 GB so a 140 GB file on a 4 GB device would otherwise silently
        // `.allow`; under `.resident` the normal threshold check already denies,
        // but the explicit guard keeps the reason informative. A ratio of 3
        // means a 12 GB file on 4 GB RAM is still permitted (mmap can plausibly
        // handle ~3× working set) while a 30 GB file on 4 GB RAM is rejected
        // before it reaches llama.cpp. `.external` (cloud / system-managed)
        // reports fileSize == 0 and is unaffected.
        let impossibleFitRatio: UInt64 = 3
        let impossibleFit = inputs.modelFileSize > 0
            && available > 0
            && inputs.modelFileSize / available >= impossibleFitRatio

        // Verdict thresholds: allow ≤85% of available, warn up to 100%, deny above.
        // Budget against `effective_available` (raw available minus app overhead),
        // NOT raw `available`. The resident/KV math above already subtracts the
        // platform overhead; budgeting the verdict against raw `available` would
        // mark a model that exceeds true usable memory as `.allow`/`.warn` and then
        // jetsam/SIGKILL it on load. The catastrophic `impossibleFit` gate below
        // intentionally stays on raw `available` (file-vs-RAM ratio, independent of
        // app overhead). See issue #471.
        let allowThreshold = UInt64(Double(effective_available) * 0.85)
        let verdict: Verdict
        var finalReasons = reasons
        if impossibleFit {
            verdict = .deny
            finalReasons.append(.insufficientResident(
                required: inputs.modelFileSize,
                available: available
            ))
        } else if total <= allowThreshold {
            verdict = .allow
        } else if total <= effective_available {
            verdict = .warn
        } else {
            verdict = .deny
            if residentBudget > effective_available {
                finalReasons.append(.insufficientResident(
                    required: residentBudget,
                    available: effective_available
                ))
            } else {
                finalReasons.append(.insufficientKVCache(
                    required: total,
                    available: effective_available
                ))
            }
        }

        let outcome = Outcome(
            effectiveContextSize: effectiveContextSize,
            estimatedResidentBytes: residentBudget,
            estimatedKVBytes: estimatedKV,
            totalEstimatedBytes: total,
            verdict: verdict,
            reasons: finalReasons
        )
        return ModelLoadPlan(inputs: inputs, outcome: outcome)
    }

    /// Pre-flight fit verdict for a `DownloadableModel` (browse-time, pre-download).
    ///
    /// **This is the canonical public entry point for pre-download memory-fit checks.** It needs
    /// only manifest-level fields (`sizeBytes`, `modelType`) — no GGUF header — and applies the
    /// conservative KV fallback internally, so callers never have to construct ``Inputs`` by hand.
    /// Only when you genuinely must build an ``Inputs`` directly should you reach for the public
    /// ``conservativeFallbackBytesPerToken`` constant instead of the `@_spi(BackendInternals)`
    /// estimator.
    ///
    /// Unlike ``compute(for:requestedContextSize:environment:absoluteContextCeiling:headroomFraction:)``
    /// which consumes an on-disk ``ModelInfo`` (with GGUF metadata, detected context length,
    /// arch-derived KV/token), this overload only has the manifest-level fields a HuggingFace
    /// listing exposes: ``DownloadableModel/sizeBytes``, ``DownloadableModel/modelType``, and a
    /// quantization tag extracted from the filename. That means:
    ///
    /// - The trained-context ceiling is unknown — only the absolute ceiling and memory ceiling
    ///   apply, so the clamp result can be *larger* than the post-download `compute(...)` would
    ///   produce (the post-load path will tighten it once GGUF metadata is read).
    /// - KV-bytes-per-token uses the conservative legacy 8 KB/token fallback
    ///   (``GGUFKVCacheEstimator/legacyFallbackBytesPerToken``). Real architectures with grouped-
    ///   query attention or small head dimensions are typically *cheaper* per token, so the
    ///   estimate is at least as conservative as the post-load path for the same `(sizeBytes,
    ///   strategy, available)` triple.
    /// - `MemoryStrategy` is derived from ``DownloadableModel/modelType`` the same way the
    ///   ``ModelInfo``-based overload does: `.gguf` → `.mappable`, `.mlx` → `.resident`,
    ///   `.foundation` → `.external` via ``systemManaged(requestedContextSize:)``.
    ///
    /// The returned `ModelLoadPlan` carries the same `Outcome.verdict` / `reasons` shape as the
    /// post-load path; UI badges can render `.allow` / `.warn` / `.deny` directly off `verdict`,
    /// and inspect `reasons` for clamp annotations (`.memoryCeilingReached`,
    /// `.absoluteCeilingReached`) which can co-occur with `.allow`.
    public static func estimate(
        for model: DownloadableModel,
        requestedContextSize: Int,
        environment: Environment = .current,
        absoluteContextCeiling: Int = 128_000,
        headroomFraction: Double = 0.40
    ) -> ModelLoadPlan {
        switch model.modelType {
        case .foundation:
            return systemManaged(requestedContextSize: requestedContextSize)
        case .mlx, .gguf:
            break
        }

        let strategy: MemoryStrategy = (model.modelType == .mlx) ? .resident : .mappable

        // Manifests don't expose architecture or attention shape, so we cannot run
        // `GGUFKVCacheEstimator.estimateBytesPerToken(...)`. Fall back to the legacy
        // 8 KB/token estimate — conservative vs. real GQA architectures, which keeps
        // pre-download verdicts at least as strict as the post-load `compute(...)`.
        let kvBytesPerToken = GGUFKVCacheEstimator.legacyFallbackBytesPerToken

        #if os(iOS) || os(visionOS)
        // Mirror the iOS jetsam overhead reserve from the ModelInfo-based overload.
        let appOverhead: UInt64 = environment.physicalMemoryBytes < 12_884_901_888
            ? 838_860_800   // 800 MiB
            : 0
        #else
        let appOverhead: UInt64 = 0
        #endif

        let inputs = Inputs(
            modelFileSize: model.sizeBytes,
            memoryStrategy: strategy,
            requestedContextSize: requestedContextSize,
            // Manifest path: no detected trained-context length. Post-load `compute(...)`
            // tightens this once the GGUF header is read.
            trainedContextLength: nil,
            kvBytesPerToken: kvBytesPerToken,
            availableMemoryBytes: environment.availableMemoryBytes(),
            physicalMemoryBytes: environment.physicalMemoryBytes,
            absoluteContextCeiling: absoluteContextCeiling,
            headroomFraction: headroomFraction,
            appOverheadBytes: appOverhead
        )
        return compute(inputs: inputs)
    }

    /// For system-managed backends (Apple Foundation Models) where memory is owned
    /// by the OS and there's nothing to estimate. Always allows with stub fields.
    public static func systemManaged(requestedContextSize: Int) -> ModelLoadPlan {
        let effective = max(1, requestedContextSize)
        let inputs = Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: requestedContextSize,
            trainedContextLength: nil,
            kvBytesPerToken: 0,
            availableMemoryBytes: 0,
            physicalMemoryBytes: 0,
            absoluteContextCeiling: 0,
            headroomFraction: 0
        )
        let outcome = Outcome(
            effectiveContextSize: effective,
            estimatedResidentBytes: 0,
            estimatedKVBytes: 0,
            totalEstimatedBytes: 0,
            verdict: .allow,
            reasons: []
        )
        return ModelLoadPlan(inputs: inputs, outcome: outcome)
    }

    /// Quick "can this device probably run a model of this size?" check for pre-download
    /// UI recommendation paths (badges, tier sorting, variant suggestion).
    ///
    /// Uses the `.resident` strategy — pessimistic about RAM cost — so the UI stays
    /// conservative when telling users which downloads will fit. Load-time gating uses
    /// the full `compute(for:requestedContextSize:strategy:)` against the backend's true
    /// memory strategy, which may be more permissive (e.g., `.mappable` for GGUF).
    public static func canRunModel(sizeBytes: UInt64, physicalMemoryBytes: UInt64) -> Bool {
        let plan = compute(inputs: Inputs(
            modelFileSize: sizeBytes,
            memoryStrategy: .resident,
            requestedContextSize: 2048,
            trainedContextLength: nil,
            kvBytesPerToken: GGUFKVCacheEstimator.legacyFallbackBytesPerToken,
            availableMemoryBytes: physicalMemoryBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40
        ))
        // .allow only — .warn means "might fit with pressure", which is not a
        // pre-download recommendation. Tier sorting in the UI distinguishes
        // comfortable-fit from borderline by probing at 80% size.
        return plan.verdict == .allow
    }

    /// For cloud backends with no local KV cache. `effectiveContextSize` is purely
    /// informational — cloud providers enforce their own limits server-side.
    public static func cloud(requestedContextSize: Int = 0) -> ModelLoadPlan {
        let effective = max(1, requestedContextSize)
        let inputs = Inputs(
            modelFileSize: 0,
            memoryStrategy: .external,
            requestedContextSize: requestedContextSize,
            trainedContextLength: nil,
            kvBytesPerToken: 0,
            availableMemoryBytes: 0,
            physicalMemoryBytes: 0,
            absoluteContextCeiling: 0,
            headroomFraction: 0
        )
        let outcome = Outcome(
            effectiveContextSize: effective,
            estimatedResidentBytes: 0,
            estimatedKVBytes: 0,
            totalEstimatedBytes: 0,
            verdict: .allow,
            reasons: []
        )
        return ModelLoadPlan(inputs: inputs, outcome: outcome)
    }
}
