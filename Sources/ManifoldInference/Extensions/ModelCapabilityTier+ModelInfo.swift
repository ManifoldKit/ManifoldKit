import Foundation

// MARK: - ModelCapabilityTier convenience for ModelInfo

/// `ModelCapabilityTier.estimate(from:)` convenience overload that accepts a
/// `ModelInfo` value. Lives in ManifoldInference (not ManifoldHardware) because
/// `ModelInfo` is a ManifoldInference type; `ManifoldHardware` exposes the
/// primitive `estimate(fileSize:modelType:)` variant to avoid an upward dep.
public extension ModelCapabilityTier {

    /// Estimates a capability tier from a ``ModelInfo`` value.
    ///
    /// Uses on-disk file size as a proxy for parameter count. This is a conservative
    /// heuristic — use a ``ModelBenchmarkResult`` when measured data is available.
    ///
    /// - Parameter modelInfo: The model whose size and type will be inspected.
    /// - Returns: A tier estimate appropriate for the model's size and backend.
    static func estimate(from modelInfo: ModelInfo) -> ModelCapabilityTier {
        estimate(fileSize: modelInfo.fileSize, modelType: modelInfo.modelType)
    }
}
