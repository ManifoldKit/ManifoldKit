import Foundation

/// A coarse capability classification for a model, based on parameter count or file size.
///
/// Tiers are ordered from least capable (`minimal`) to most capable (`frontier`).
/// Use ``ModelCapabilityTier/estimate(from:)`` for a static size-based estimate, or
/// prefer a ``ModelBenchmarkResult`` when one is available for measured accuracy.
public enum ModelCapabilityTier: Int, Comparable, Codable, Sendable {
    /// Less than ~2 GB — very heavily quantised or small parameter count. Basic tasks only.
    case minimal   = 0
    /// ~2–5 GB — responsive everyday use (2–7B class models).
    case fast      = 1
    /// ~5–10 GB — good quality/speed tradeoff (8–13B class models).
    case balanced  = 2
    /// ~10–21 GB — strong reasoning capability (14–30B class models).
    case capable   = 3
    /// 21 GB+ or cloud — best quality available.
    case frontier  = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// A short human-readable label for this tier.
    public var label: String {
        switch self {
        case .minimal:  return "Minimal"
        case .fast:     return "Fast"
        case .balanced: return "Balanced"
        case .capable:  return "Capable"
        case .frontier: return "Frontier"
        }
    }
}

// MARK: - Static Estimation

extension ModelCapabilityTier {

    /// Estimates a capability tier from raw model metadata without running any inference.
    ///
    /// Uses on-disk file size as a proxy for parameter count. This is a conservative
    /// heuristic — use a ``ModelBenchmarkResult`` when measured data is available.
    ///
    /// - Parameters:
    ///   - fileSize: On-disk file size in bytes.
    ///   - modelType: The inference backend the model targets.
    /// - Returns: A tier estimate appropriate for the model's size and backend.
    public static func estimate(fileSize: UInt64, modelType: ModelType) -> ModelCapabilityTier {
        switch modelType {
        case .foundation:
            // Apple Foundation Model is approximately 3B parameters.
            return .fast
        case .gguf, .mlx:
            let gb = Double(fileSize) / 1_073_741_824
            switch gb {
            case ..<2:    return .minimal
            case 2..<5:   return .fast
            case 5..<10:  return .balanced
            case 10..<21: return .capable
            default:      return .frontier
            }
        }
    }
}

// MARK: - Benchmark Result

/// A measured snapshot of a model's runtime performance and capability tier.
///
/// Results are produced by ``StandardBenchmarkRunner`` and can be persisted via
/// ``ModelBenchmarkCache`` so expensive benchmarks are not re-run on every launch.
/// Check ``isStale`` to decide whether to re-run a benchmark.
public struct ModelBenchmarkResult: Codable, Sendable, Equatable, Hashable {

    /// The capability tier confirmed by this benchmark run.
    public let tier: ModelCapabilityTier

    /// Measured generation speed in tokens per second, or `nil` if not measured.
    public let tokensPerSecond: Double?

    /// Peak process memory at the time of measurement (bytes), or `nil` if not measured.
    public let memoryBytes: Int64?

    /// When this benchmark was taken.
    public let measuredAt: Date

    /// `true` when the result is older than 7 days and should be re-measured.
    public var isStale: Bool {
        Date().timeIntervalSince(measuredAt) > 7 * 24 * 3_600
    }

    public init(
        tier: ModelCapabilityTier,
        tokensPerSecond: Double? = nil,
        memoryBytes: Int64? = nil,
        measuredAt: Date = Date()
    ) {
        self.tier = tier
        self.tokensPerSecond = tokensPerSecond
        self.memoryBytes = memoryBytes
        self.measuredAt = measuredAt
    }
}
