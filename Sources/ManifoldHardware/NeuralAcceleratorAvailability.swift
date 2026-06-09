#if os(macOS)
import Metal

/// Heuristic availability of the M5 Neural Accelerator for MLX inference.
///
/// MLX activates NAX automatically when macOS 26.2+ is present on M5-generation
/// (G18+) hardware. No public MTLDevice property or sysctlbyname key for NAX
/// status exists — this uses an MTLDevice name heuristic as a best-effort
/// indicator for informational UI only.
///
/// Use this to surface messaging such as "Running on M5 with Neural Accelerator —
/// expect ~4× faster first-token generation." Do NOT use it to gate inference.
public enum NeuralAcceleratorAvailability: Sendable {
    /// macOS 26.2+ on M5 (or later) hardware. NAX is likely active in MLX.
    case available
    /// macOS 26.2+ present but hardware is not M5-generation or later.
    case unavailableHardware
    /// macOS 26.0/26.1 — OS version gate not met.
    case unavailableOS
    /// Pre-macOS 26 or non-macOS platform.
    case unsupportedPlatform
}

/// Probes for M5 Neural Accelerator availability in ManifoldMLX.
///
/// Apple ML Research measured 3.33–4.06× TTFT speedup on M5 hardware with
/// macOS 26.2+. All M5 variants (MacBook Air, MacBook Pro, Mac mini, Mac Studio)
/// include Neural Accelerators — there is no Pro/Max-only gate.
///
/// Source: https://machinelearning.apple.com/research/exploring-llms-mlx-m5
public enum NeuralAcceleratorProbe: Sendable {
    /// Heuristic availability for the current process.
    ///
    /// Result depends on OS version and MTLDevice name. On CI runners without
    /// M5 hardware, this returns `.unavailableHardware` or `.unavailableOS`.
    public static var availability: NeuralAcceleratorAvailability {
        guard #available(macOS 26.2, *) else {
            if #available(macOS 26, *) { return .unavailableOS }
            return .unsupportedPlatform
        }
        let deviceName = MTLCreateSystemDefaultDevice()?.name ?? ""
        // Extend as new chip families ship (M6, M7, …).
        let isM5OrLater = ["M5", "M6", "M7"].contains { deviceName.contains($0) }
        return isM5OrLater ? .available : .unavailableHardware
    }
}
#endif
