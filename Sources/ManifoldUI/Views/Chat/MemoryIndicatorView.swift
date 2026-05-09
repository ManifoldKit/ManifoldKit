import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Shows device memory pressure and RAM usage as a compact indicator in the chat toolbar.
///
/// Mirrors the visual style of `ContextIndicatorView`: a small colored dot indicating
/// pressure level, followed by a label showing the current app memory footprint.
///
/// Color coding follows the OS pressure levels:
/// - Green (.nominal) — memory is comfortable
/// - Yellow (.warning) — memory is getting tight
/// - Red (.critical) — memory is critically low
public struct MemoryIndicatorView: View {

    public let pressureLevel: MemoryPressureLevel
    /// Physical RAM of the device, in bytes.
    public let physicalMemoryBytes: UInt64
    /// Current app memory footprint in bytes, or `nil` if unavailable.
    public let appMemoryBytes: UInt64?

    public init(pressureLevel: MemoryPressureLevel, physicalMemoryBytes: UInt64, appMemoryBytes: UInt64?) {
        self.pressureLevel = pressureLevel
        self.physicalMemoryBytes = physicalMemoryBytes
        self.appMemoryBytes = appMemoryBytes
    }

    // MARK: - Derived

    private var indicatorColor: Color {
        switch pressureLevel {
        case .nominal:  return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    private var pressureLabel: String {
        switch pressureLevel {
        case .nominal:  return "Nominal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }

    /// Short label shown next to the dot. We deliberately avoid an "X / Y GB"
    /// fraction because the numerator is this app's footprint while the
    /// denominator is total device RAM, which users can misread as a system-wide
    /// usage meter.
    private var compactLabel: String {
        if let used = appMemoryBytes {
            return "App \(AppMemoryUsage.format(used))"
        }
        let totalGB = Double(physicalMemoryBytes) / (1024 * 1024 * 1024)
        return String(format: "%.0f GB RAM", totalGB)
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 4) {
            // Filled circle — simpler than a ring because pressure is a discrete state
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(compactLabel)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(pressureLevel == .nominal ? .secondary : indicatorColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .help(tooltipText)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var parts = ["Memory pressure \(pressureLevel.rawValue)"]
        if let used = appMemoryBytes {
            parts.append("app using \(AppMemoryUsage.format(used))")
        }
        let totalGB = physicalMemoryBytes / (1024 * 1024 * 1024)
        parts.append("device has \(totalGB) GB RAM")
        return parts.joined(separator: ", ")
    }

    private var tooltipText: String {
        var lines = ["Memory pressure: \(pressureLabel)"]
        let totalGB = physicalMemoryBytes / (1024 * 1024 * 1024)
        lines.append("Device RAM: \(totalGB) GB")
        if let used = appMemoryBytes {
            lines.append("App footprint: \(AppMemoryUsage.format(used))")
            lines.append("This is this app only, not total system memory in use.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Previews

#Preview("Nominal") {
    MemoryIndicatorView(
        pressureLevel: .nominal,
        physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
        appMemoryBytes: 432 * 1024 * 1024
    )
    .padding()
}

#Preview("Warning") {
    MemoryIndicatorView(
        pressureLevel: .warning,
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
        appMemoryBytes: 5_800 * 1024 * 1024
    )
    .padding()
}

#Preview("Critical") {
    MemoryIndicatorView(
        pressureLevel: .critical,
        physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
        appMemoryBytes: 5_900 * 1024 * 1024
    )
    .padding()
}

#Preview("No app usage") {
    MemoryIndicatorView(
        pressureLevel: .nominal,
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
        appMemoryBytes: nil
    )
    .padding()
}
