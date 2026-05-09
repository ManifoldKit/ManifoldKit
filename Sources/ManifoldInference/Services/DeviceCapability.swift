import Foundation

/// A namespace of pure query predicates that answer capability questions about the
/// current device.
///
/// All three helpers are thin wrappers over ``ModelCapabilityTier``,
/// ``DeviceCapabilityService``, and ``ModelLoadPlan``. They add no new logic — only
/// a friendlier, composable surface that callers can use without reaching into each
/// service individually.
///
/// ```swift
/// // Before showing a download button:
/// if DeviceCapability.supports(tier: .balanced) {
///     // show download option
/// }
///
/// // Before recommending a variant for a given framework:
/// let top = DeviceCapability.highestSupportedTier(for: .gguf)
///
/// // Before starting a load:
/// guard DeviceCapability.canLoadModel(estimatedMemoryMB: 4_200) else {
///     // warn the user
/// }
/// ```
public enum DeviceCapability {

    // MARK: - Tier Membership

    /// Returns `true` when the current device's physical RAM is likely sufficient to
    /// run a model at the given ``ModelCapabilityTier``.
    ///
    /// The check uses the same conservative `.resident` memory strategy as
    /// ``ModelLoadPlan/canRunModel(sizeBytes:physicalMemoryBytes:)`` — it treats the
    /// entire model as resident in RAM so that the answer is safe for pre-download
    /// recommendation UI.
    ///
    /// The reference model sizes per tier match the midpoint of each tier's file-size
    /// range as documented in ``ModelCapabilityTier``:
    ///
    /// | Tier      | Probe size |
    /// |-----------|-----------|
    /// | minimal   | 1 GB       |
    /// | fast      | 3 GB       |
    /// | balanced  | 7 GB       |
    /// | capable   | 15 GB      |
    /// | frontier  | 22 GB      |
    ///
    /// - Parameter tier: The capability tier to test.
    /// - Returns: `true` if a representative model at that tier should fit in memory.
    public static func supports(tier: ModelCapabilityTier) -> Bool {
        let physical = ProcessInfo.processInfo.physicalMemory
        return ModelLoadPlan.canRunModel(sizeBytes: probeSizeBytes(for: tier),
                                        physicalMemoryBytes: physical)
    }

    // MARK: - Highest Supported Tier

    /// Returns the highest ``ModelCapabilityTier`` whose representative probe size fits
    /// in memory for the given backend framework.
    ///
    /// Iterates tiers from highest to lowest, returning the first that passes
    /// ``supports(tier:)``. Always returns at least `.minimal` — even extremely
    /// memory-constrained devices can handle a heavily quantised model.
    ///
    /// `.foundation` models are system-managed (the OS owns their memory budget), so
    /// they always satisfy at least `.fast` regardless of available RAM.
    ///
    /// - Parameter framework: The ``ModelType`` (backend framework) being queried.
    /// - Returns: The highest tier this device can comfortably run.
    public static func highestSupportedTier(for framework: ModelType) -> ModelCapabilityTier {
        // Foundation models are managed by the OS — no local memory budget applies.
        // Apple's on-device model is approximately 3B parameters → .fast floor.
        if framework == .foundation {
            let orderedDescending: [ModelCapabilityTier] = [
                .frontier, .capable, .balanced, .fast
            ]
            for tier in orderedDescending {
                if supports(tier: tier) {
                    return tier
                }
            }
            return .fast
        }

        // Local backends (gguf / mlx): tiers in descending order — return the first
        // one whose probe size fits in physical RAM.
        let orderedDescending: [ModelCapabilityTier] = [
            .frontier, .capable, .balanced, .fast, .minimal
        ]
        for tier in orderedDescending {
            if supports(tier: tier) {
                return tier
            }
        }
        // Logically unreachable: supports(.minimal) is always true (1 GB probe).
        return .minimal
    }

    // MARK: - Memory Headroom

    /// Returns `true` when the device has enough available memory to load a model
    /// whose estimated RAM footprint is `estimatedMemoryMB` megabytes.
    ///
    /// Uses ``DeviceCapabilityService/queryAvailableMemory()`` for the current
    /// process-level budget, then applies an 85 % allow threshold (matching
    /// ``ModelLoadPlan/Verdict/allow``). This is intentionally stricter than
    /// ``supports(tier:)``: whereas `supports` uses physical RAM to answer
    /// "would this device ever run such a model?", `canLoadModel` uses *current*
    /// available memory to answer "can we start loading *right now*?".
    ///
    /// - Parameter estimatedMemoryMB: Estimated RAM requirement in megabytes.
    ///   Pass the model's file size for a conservative (`.resident`) estimate, or
    ///   a backend-specific active footprint when available.
    /// - Returns: `true` if the estimated memory need is within 85 % of available memory.
    public static func canLoadModel(estimatedMemoryMB: Int) -> Bool {
        guard estimatedMemoryMB > 0 else { return true }
        let estimatedBytes = UInt64(estimatedMemoryMB) * 1_048_576   // MB → bytes
        let available = DeviceCapabilityService.queryAvailableMemory()
        // Mirror the ModelLoadPlan allow threshold: total ≤ 85 % of available.
        let allowThreshold = UInt64(Double(available) * 0.85)
        return estimatedBytes <= allowThreshold
    }

    // MARK: - Private Helpers

    /// Representative probe size (bytes) for each capability tier.
    ///
    /// Chosen as a point inside each tier's file-size range that is large enough
    /// to be a meaningful test but not at the very top of the range (which would
    /// exclude devices that can *comfortably* run that tier):
    ///
    /// - minimal  (< 2 GB): 1 GB probe
    /// - fast     (2–5 GB): 3 GB probe
    /// - balanced (5–10 GB): 7 GB probe
    /// - capable  (10–21 GB): 15 GB probe
    /// - frontier (21 GB+): 22 GB probe
    private static func probeSizeBytes(for tier: ModelCapabilityTier) -> UInt64 {
        switch tier {
        case .minimal:  return  1 * 1_073_741_824
        case .fast:     return  3 * 1_073_741_824
        case .balanced: return  7 * 1_073_741_824
        case .capable:  return 15 * 1_073_741_824
        case .frontier: return 22 * 1_073_741_824
        }
    }
}
