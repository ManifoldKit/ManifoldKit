import Foundation
// @_spi(BackendInternals): the scorer reuses ManifoldHardware primitives
// (DeviceProfile, ModelLoadPlan.Environment, package-visible composite helpers).
@_spi(BackendInternals) import ManifoldHardware

// MARK: - ModelFitScorer bridge for ModelInfo

/// Fit-scoring for the models a user actually has on disk.
///
/// `ModelFitScorer` ships scoring overloads for `DownloadableModel` (pre-download
/// catalog entries) and `ModelSelectionProfile` (resident descriptors), but
/// `ModelRegistry.availableModels` is `[ModelInfo]` — the on-disk shape. Without
/// this bridge nothing could rank the models already present locally.
///
/// This overload derives the scorer's four inputs from `ModelInfo`'s existing
/// fields and reuses the *same* dimension math as the downloadable path:
/// - **fit**: from `ModelLoadPlan.compute(for: model, ...)` — the ModelInfo-aware
///   plan factory in `ModelLoadPlan+ModelInfo.swift`, which reads the GGUF KV
///   estimate when present rather than the legacy fallback. We never recompute
///   resident/KV byte math here.
/// - **quality**: `ModelFitScorer.qualityScore(sizeBytes:quantization:)` — the
///   identical size-tier × quant-width curve `DownloadableModel` scoring uses.
/// - **speed**: `bandwidth ÷ active-bytes-per-token`, with `activeParameterBytes`
///   as the denominator (MoE) falling back to `fileSize` (dense/unknown).
/// - **context**: `detectedContextLength` vs. the use case's `contextNeed`,
///   neutral (0.5) when the header carried no context length.
public extension ModelFitScorer {

    /// Scores a single on-disk `ModelInfo` under a use case.
    ///
    /// - Parameters:
    ///   - model: The on-disk candidate.
    ///   - useCase: Biases the dimension weights and context need.
    ///   - requestedContextSize: Context size the fit dimension is evaluated at.
    ///   - device: Device profile supplying memory + bandwidth (injectable for tests).
    ///   - environment: Memory environment for the `ModelLoadPlan` fit estimate.
    ///     Defaults to one derived from `device` so a single injected `DeviceProfile`
    ///     drives both the speed and fit dimensions consistently.
    /// - Returns: A `ModelFitScore`, or `nil` if the model has no usable size and is
    ///   not an OS-resident foundation model (size 0 is legitimate for foundation).
    func score(
        _ model: ModelInfo,
        useCase: ModelUseCase,
        requestedContextSize: Int = 4_096,
        device: DeviceProfile = .current,
        environment: ModelLoadPlan.Environment? = nil
    ) -> ModelFitScore? {
        // Foundation models are OS-resident with a 0-byte file footprint; every other
        // type needs a real size to score. A genuine 0-byte local file is unscoreable.
        guard model.modelType == .foundation || model.fileSize > 0 else { return nil }

        let weights = useCase.weights
        let env = environment ?? ModelLoadPlan.Environment(
            availableMemoryBytes: { device.usableMemoryBytes },
            physicalMemoryBytes: device.physicalMemoryBytes
        )

        // --- fit: reuse the ModelInfo-aware load plan; do NOT recompute byte math. ---
        let plan = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: requestedContextSize,
            environment: env
        )
        let willRun = plan.verdict != .deny
        let fit: Double
        switch plan.verdict {
        case .allow: fit = 1.0
        case .warn:  fit = 0.5
        case .deny:  fit = 0.0
        }

        // --- quality: identical size-tier × quant-width curve as downloadable scoring. ---
        let quality = ModelFitScorer.qualityScore(
            sizeBytes: model.fileSize,
            quantization: model.quantization
        )

        // --- speed: bandwidth ÷ active-bytes-per-token. ---
        // why: decode throughput is memory-bandwidth bound by the bytes streamed per
        // token-pass. For MoE only the active experts are touched, so
        // `activeParameterBytes` is the right denominator; dense/unknown falls back to
        // the full file size. Foundation models have a 0-byte file, so they fall back
        // to the OS-resident assumed active footprint to land in the usable speed band.
        let activeBytes: UInt64
        if let active = model.activeParameterBytes, active > 0 {
            activeBytes = active
        } else if model.modelType == .foundation {
            activeBytes = ModelFitScorer.osResidentAssumedActiveBytes
        } else {
            activeBytes = model.fileSize
        }
        let (estimatedTPS, speed) = speedDimension(activeBytes: activeBytes, device: device)

        // --- context: detected length vs. need; neutral when unknown. ---
        let context: Double
        if let known = model.detectedContextLength, known > 0 {
            let raw = Double(known) / Double(max(useCase.contextNeed, 1))
            context = Swift.max(0.0, Swift.min(1.0, raw))
        } else {
            context = 0.5
        }

        let composite = ModelFitScorer.composite(
            quality: quality,
            speed: speed,
            fit: fit,
            context: context,
            weights: weights,
            willRun: willRun
        )

        return ModelFitScore(
            quality: quality,
            speed: speed,
            fit: fit,
            context: context,
            composite: composite,
            estimatedTokensPerSecond: estimatedTPS,
            memoryBytes: plan.outcome.totalEstimatedBytes,
            willRun: willRun
        )
    }

    /// Ranks on-disk models best-first (descending composite) under a use case.
    ///
    /// Mirrors the `rank(_:DownloadableModel...)` convenience: models that fail to
    /// score (0-byte non-foundation files) are dropped.
    func rank(
        _ models: [ModelInfo],
        useCase: ModelUseCase,
        requestedContextSize: Int = 4_096,
        device: DeviceProfile = .current,
        environment: ModelLoadPlan.Environment? = nil
    ) -> [(ModelInfo, ModelFitScore)] {
        models.compactMap { model in
            guard let s = score(
                model,
                useCase: useCase,
                requestedContextSize: requestedContextSize,
                device: device,
                environment: environment
            ) else { return nil }
            return (model, s)
        }
        .sorted { $0.1.composite > $1.1.composite }
    }
}
