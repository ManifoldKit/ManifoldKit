#if MLX
import Foundation

/// Policy controlling how much GPU buffer cache MLX retains for reuse between
/// operations.
///
/// MLX maintains a pool of freed Metal buffers up to a configurable limit so
/// that subsequent allocations of the same shape can recycle them instead of
/// going through the OS allocator. The right size is a tradeoff between
/// per-step allocator overhead (smaller pool = more thrashing, slower decode)
/// and peak resident memory (larger pool = more headroom held).
///
/// The historical default of 20 MB was inherited from the `mlx-swift-examples`
/// LLMEval sample, which uses it as a "minimum footprint demo" value. It is
/// dramatically too small for sustained chat or story workloads on Apple
/// Silicon Macs, where 256 MB–1 GB is more appropriate. Use `.auto` (the
/// default) unless you have measured something specific.
///
/// The cache is process-global on the MLX module. If multiple `MLXBackend`
/// instances load models sequentially, the most recent load's policy wins.
public enum MLXCachePolicy: Sendable, Equatable {

    /// Auto-pick a sensible cache size based on the device's physical RAM.
    /// This is the default and the right choice unless you have benchmarked
    /// something specific.
    case auto

    /// Minimal caching (~20 MB) — the historical default and the value used
    /// by the `mlx-swift-examples` LLMEval sample. Trades throughput for
    /// minimum peak memory. Use only on extremely memory-constrained devices
    /// where allocator thrashing is preferable to peak footprint.
    case minimal

    /// Generous caching — roughly 25% of physical RAM, capped at 4 GB. Use
    /// when you have plenty of headroom and want maximum sustained throughput.
    case generous

    /// An explicit byte count, for when you have benchmarked your specific
    /// model + workload combination and know exactly what you want.
    case explicit(bytes: Int)

    /// Resolves the policy to a concrete byte count for the current device.
    public func resolvedBytes() -> Int {
        switch self {
        case .auto:
            return Self.autoBytes()
        case .minimal:
            return 20 * 1024 * 1024
        case .generous:
            return Self.generousBytes()
        case .explicit(let bytes):
            return max(0, bytes)
        }
    }

    // MARK: - Heuristics

    /// Bucketed by device class. These numbers are informed guesses, not
    /// measured optima — they will be tuned in a follow-up once we have real
    /// per-device throughput data.
    private static func autoBytes() -> Int {
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        switch physicalGB {
        case ..<7:    return  64 * 1024 * 1024  // older iPhones (~6 GB)
        case ..<10:   return 128 * 1024 * 1024  // current mid iPhones, base iPads (~8 GB)
        case ..<18:   return 256 * 1024 * 1024  // 16 GB Macs, high-end iPads
        case ..<36:   return 512 * 1024 * 1024  // 24-32 GB Macs
        default:      return 1024 * 1024 * 1024 // 36+ GB Macs (M-Pro/Max/Ultra)
        }
    }

    private static func generousBytes() -> Int {
        let physical = ProcessInfo.processInfo.physicalMemory
        let quarter = physical / 4
        let cap: UInt64 = 4 * 1024 * 1024 * 1024
        return Int(min(quarter, cap))
    }
}
#endif
