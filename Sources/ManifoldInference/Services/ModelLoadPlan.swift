import Foundation

/// Unified pre-load decision for a model.
///
/// Captures the context-clamp and memory-fit decisions in a single value. Backends
/// consume a plan directly via `InferenceBackend.loadModel(from:plan:)`; UI builds
/// one via `ModelLoadPlan.compute(for:requestedContextSize:strategy:)` so every
/// load path sees the same authoritative context and verdict.
public struct ModelLoadPlan: Sendable {

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
            appOverheadBytes: UInt64 = 0
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

        // Memory-derived token ceiling. Guarding against div-by-zero when the caller
        // passed kvBytesPerToken == 0 (shouldn't happen in practice, but cheap to be safe).
        let memoryCeiling: Int = inputs.kvBytesPerToken == 0
            ? Int.max
            : Int(kvBudget / inputs.kvBytesPerToken)

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

        let estimatedKV = UInt64(effectiveContextSize) * inputs.kvBytesPerToken
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
        let allowThreshold = UInt64(Double(available) * 0.85)
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
        } else if total <= available {
            verdict = .warn
        } else {
            verdict = .deny
            if residentBudget > available {
                finalReasons.append(.insufficientResident(
                    required: residentBudget,
                    available: available
                ))
            } else {
                finalReasons.append(.insufficientKVCache(
                    required: total,
                    available: available
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

    /// Ergonomic factory for a real `ModelInfo`. Fills in architectural KV estimates
    /// from the model when present, otherwise uses the legacy 8 KB/token fallback.
    public static func compute(
        for model: ModelInfo,
        requestedContextSize: Int,
        strategy: MemoryStrategy,
        environment: Environment = .current,
        absoluteContextCeiling: Int = 128_000,
        headroomFraction: Double = 0.40
    ) -> ModelLoadPlan {
        let kvBytesPerToken = (model.estimatedKVBytesPerToken ?? 0) > 0
            ? model.estimatedKVBytesPerToken!
            : GGUFKVCacheEstimator.legacyFallbackBytesPerToken

        #if os(iOS) || os(visionOS)
        // 800 MiB headroom for SwiftData, UI, and OS on memory-constrained iOS devices.
        // iOS jetsam kills apps below `recommendedMaxWorkingSetSize`; this margin keeps
        // the KV budget inside the true usable ceiling. Not applied on high-RAM iPads
        // (≥ 12 GB physical) where pressure behaviour is closer to macOS. See #471.
        let appOverhead: UInt64 = environment.physicalMemoryBytes < 12_884_901_888
            ? 838_860_800   // 800 MiB
            : 0
        #else
        let appOverhead: UInt64 = 0
        #endif

        let inputs = Inputs(
            modelFileSize: model.fileSize,
            memoryStrategy: strategy,
            requestedContextSize: requestedContextSize,
            trainedContextLength: model.detectedContextLength,
            kvBytesPerToken: kvBytesPerToken,
            availableMemoryBytes: environment.availableMemoryBytes(),
            physicalMemoryBytes: environment.physicalMemoryBytes,
            absoluteContextCeiling: absoluteContextCeiling,
            headroomFraction: headroomFraction,
            appOverheadBytes: appOverhead
        )
        return compute(inputs: inputs)
    }

    /// Ergonomic factory that infers the right `MemoryStrategy` from `model.modelType`.
    ///
    /// Callers that have a `ModelInfo` but no live backend instance can build a plan
    /// without first looking up which `MemoryStrategy` each model format requires. The
    /// mapping mirrors the default backend roster registered by `DefaultBackends`:
    ///
    /// | `ModelType`   | Strategy     | Why                                              |
    /// |---------------|--------------|--------------------------------------------------|
    /// | `.foundation` | `.external`  | OS owns memory; delegates to `systemManaged`.    |
    /// | `.mlx`        | `.resident`  | Weights must be fully resident (unified memory). |
    /// | `.gguf`       | `.mappable`  | llama.cpp mmap; only active pages need RAM.      |
    ///
    /// Prefer this overload over `compute(for:requestedContextSize:strategy:)` when
    /// you do *not* need to override the strategy — pre-load UI badges, recommendation
    /// paths, and the standard load flow all want the canonical strategy for the
    /// model's format. The strategy-explicit overload is still available for advanced
    /// callers that register a non-default backend (e.g. an MLX backend with a
    /// hypothetical mmap mode) and want to model that explicitly.
    ///
    /// For `.foundation`, the result is identical to ``systemManaged(requestedContextSize:)``
    /// — the OS owns memory and there is nothing to estimate.
    public static func compute(
        for model: ModelInfo,
        requestedContextSize: Int,
        environment: Environment = .current,
        absoluteContextCeiling: Int = 128_000,
        headroomFraction: Double = 0.40
    ) -> ModelLoadPlan {
        switch model.modelType {
        case .foundation:
            return systemManaged(requestedContextSize: requestedContextSize)
        case .mlx:
            return compute(
                for: model,
                requestedContextSize: requestedContextSize,
                strategy: .resident,
                environment: environment,
                absoluteContextCeiling: absoluteContextCeiling,
                headroomFraction: headroomFraction
            )
        case .gguf:
            return compute(
                for: model,
                requestedContextSize: requestedContextSize,
                strategy: .mappable,
                environment: environment,
                absoluteContextCeiling: absoluteContextCeiling,
                headroomFraction: headroomFraction
            )
        }
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
