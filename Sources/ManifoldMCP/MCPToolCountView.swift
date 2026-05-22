import SwiftUI

/// A settings-row component that shows how many MCP tools are currently registered
/// and—when Apple Intelligence is available—how many of those fit within the
/// Foundation Models tool cap.
///
/// Intended for use inside a `Form` or `List` settings screen. A typical placement
/// is in a dedicated "MCP Servers" or "Tool Calling" section:
///
/// ```swift
/// Section("Tool Calling") {
///     MCPToolCountView(
///         totalToolCount: source.currentToolNames().count,
///         compatibleToolCount: compatibleNames.count
///     )
/// }
/// ```
///
/// The "(16 max with Apple Intelligence)" footnote is only shown when the device
/// is running iOS 26+ / macOS 26+, keeping the UI clean on older OS versions where
/// Foundation Models is not available.
public struct MCPToolCountView: View {

    /// Total number of tools currently registered across all MCP servers.
    public let totalToolCount: Int

    /// Number of those tools whose JSON schemas are compatible with the
    /// Foundation Models tool surface (non-nil only when the caller has
    /// computed this value, e.g. via ``MCPToolSource/foundationModelsCompatibleNames(maxDepth:)``).
    /// When `nil`, only the total count is displayed.
    public let compatibleToolCount: Int?

    public init(totalToolCount: Int, compatibleToolCount: Int? = nil) {
        self.totalToolCount = totalToolCount
        self.compatibleToolCount = compatibleToolCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tools enabled")
                Spacer()
                Text(countLabel)
                    .foregroundStyle(.secondary)
            }
            if let note = appleIntelligenceNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Private helpers

    private var countLabel: String {
        if let compatibleToolCount {
            return "\(compatibleToolCount) of \(totalToolCount)"
        }
        return "\(totalToolCount)"
    }

    /// Returns a localized footnote when the OS supports Foundation Models and
    /// the tool list would be truncated by the 16-tool cap.
    ///
    /// The `#available` check prevents the note from appearing on older OS versions
    /// where Apple Intelligence is not present — no hardcoded platform check.
    private var appleIntelligenceNote: String? {
        guard #available(iOS 26, macOS 26, *) else { return nil }
        let cap = MCPToolFilter.foundationModelsToolCap
        let effectiveTotal = compatibleToolCount ?? totalToolCount
        if effectiveTotal > cap {
            return "Up to \(cap) tools are used with Apple Intelligence."
        }
        return nil
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Under cap") {
    Form {
        Section("Tool Calling") {
            MCPToolCountView(totalToolCount: 8, compatibleToolCount: 8)
        }
    }
}

#Preview("Over cap") {
    Form {
        Section("Tool Calling") {
            MCPToolCountView(totalToolCount: 25, compatibleToolCount: 20)
        }
    }
}

#Preview("No compatible count") {
    Form {
        Section("Tool Calling") {
            MCPToolCountView(totalToolCount: 12)
        }
    }
}
#endif
