import Foundation
// @_spi(BackendInternals): GGUFKVCacheEstimator was promoted from `package`
// to SPI-public in v0.48 (PR C2) for the manifold-llama companion package.
@_spi(BackendInternals) import ManifoldHardware

// MARK: - ModelLoadPlan convenience overloads for ModelInfo

/// `ModelLoadPlan.compute(for:ModelInfo,...)` overloads live in ManifoldInference
/// (not ManifoldHardware) because `ModelInfo` is a ManifoldInference type.
/// `ManifoldHardware` exposes the primitive `compute(inputs:)` variant to avoid an
/// upward dependency. The API surface is preserved unchanged for all callers.
public extension ModelLoadPlan {

    /// Ergonomic factory for a real `ModelInfo`. Fills in architectural KV estimates
    /// from the model when present, otherwise uses the legacy 8 KB/token fallback.
    static func compute(
        for model: ModelInfo,
        requestedContextSize: Int,
        strategy: MemoryStrategy,
        environment: ModelLoadPlan.Environment = .current,
        absoluteContextCeiling: Int = 128_000,
        headroomFraction: Double = 0.40,
        measuredBytesPerToken: UInt64? = nil
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
            appOverheadBytes: appOverhead,
            measuredBytesPerToken: measuredBytesPerToken
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
    static func compute(
        for model: ModelInfo,
        requestedContextSize: Int,
        environment: ModelLoadPlan.Environment = .current,
        absoluteContextCeiling: Int = 128_000,
        headroomFraction: Double = 0.40,
        measuredBytesPerToken: UInt64? = nil
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
                headroomFraction: headroomFraction,
                measuredBytesPerToken: measuredBytesPerToken
            )
        case .gguf:
            return compute(
                for: model,
                requestedContextSize: requestedContextSize,
                strategy: .mappable,
                environment: environment,
                absoluteContextCeiling: absoluteContextCeiling,
                headroomFraction: headroomFraction,
                measuredBytesPerToken: measuredBytesPerToken
            )
        }
    }
}
