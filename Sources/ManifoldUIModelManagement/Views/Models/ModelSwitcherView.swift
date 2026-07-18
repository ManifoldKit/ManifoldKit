import SwiftUI
import ManifoldInference
import ManifoldUI

/// The quick model switcher — spec §5's "what do I talk to right now?"
/// surface (`docs/UI-REFRESH-2026.md` §5, issue #2307 Unit 2 §L3). Presents
/// the unified ``ModelSwitcherRow`` list built by ``ModelSwitcher``.
///
/// This view is presentation-agnostic: it renders row content only. Per spec
/// §2's platform chrome rules, the host decides how to present it — a
/// popover anchored to the toolbar chip on macOS (system-owned chrome; this
/// view never draws a bar), a sheet with `.presentationDetents` on iOS. That
/// host wiring lives at the call site (`ChatView`'s toolbar), out of this
/// tranche's owned paths — this type is the reusable content those call
/// sites present.
public struct ModelSwitcherView: View {
    public let rows: [ModelSwitcherRow]
    public let onSelect: (ModelSwitcherEntry) -> Void
    public let onFixEndpoint: ((APIEndpointRecord) -> Void)?

    public init(
        rows: [ModelSwitcherRow],
        onSelect: @escaping (ModelSwitcherEntry) -> Void,
        onFixEndpoint: ((APIEndpointRecord) -> Void)? = nil
    ) {
        self.rows = rows
        self.onSelect = onSelect
        self.onFixEndpoint = onFixEndpoint
    }

    public var body: some View {
        List(rows) { row in
            ModelSwitcherRowView(row: row, onFixEndpoint: onFixEndpoint)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard row.isAvailable else { return }
                    onSelect(row.entry)
                }
        }
        .accessibilityLabel("Model switcher")
        .accessibilityIdentifier("model-switcher-list")
    }
}

/// One row: identity + one qualitative fitness signal + capability glyphs +
/// live state, per spec §5's switcher rules.
public struct ModelSwitcherRowView: View {
    public let row: ModelSwitcherRow
    public let onFixEndpoint: ((APIEndpointRecord) -> Void)?

    @Environment(\.manifoldTheme) private var theme

    public init(row: ModelSwitcherRow, onFixEndpoint: ((APIEndpointRecord) -> Void)? = nil) {
        self.row = row
        self.onFixEndpoint = onFixEndpoint
    }

    public var body: some View {
        HStack(spacing: 10) {
            fitDot

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.entry.displayName)
                        .font(theme.type.body)
                        .foregroundStyle(row.isAvailable ? theme.ink : theme.ink3)

                    ForEach(row.capabilityGlyphs, id: \.self) { glyph in
                        Text(glyph.glyph)
                            .font(theme.type.caption2)
                            .foregroundStyle(theme.ink2)
                            .accessibilityLabel(glyph.accessibilityLabel)
                    }

                    if row.isSelected {
                        Image(systemName: "checkmark")
                            .font(theme.type.caption2)
                            .foregroundStyle(theme.accent)
                            .accessibilityLabel("In use")
                    }
                }

                if let reason = row.unavailableReason {
                    Text(reason)
                        .font(theme.type.caption)
                        .foregroundStyle(theme.statusWarnColor)
                        .lineLimit(2)
                }

                if case .downloading(let progress, _, _)? = row.downloadStatus {
                    ProgressView(value: progress)
                        .frame(maxWidth: 120)
                        .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
                }
            }

            Spacer()

            if let endpoint = faultedEndpoint, let onFixEndpoint {
                Button("Fix") { onFixEndpoint(endpoint) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.statusWarnColor)
            }
        }
        .opacity(row.isAvailable ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isSelected ? "In use" : "")
    }

    private var faultedEndpoint: APIEndpointRecord? {
        guard row.endpointFault != nil, case .endpoint(let endpoint) = row.entry else { return nil }
        return endpoint
    }

    /// Spec §5 rule 1: "dot = device-RAM fit... accent for cloud." Local
    /// rows render the qualitative verdict tier; endpoint rows (`fitVerdict
    /// == nil`) render the theme's accent instead of a fit claim.
    @ViewBuilder
    private var fitDot: some View {
        if case .endpoint = row.entry {
            Circle().fill(theme.accent).frame(width: 8, height: 8)
        } else {
            switch row.fitVerdict {
            case .good:
                Circle().fill(theme.statusOK).frame(width: 8, height: 8)
            case .warn:
                Circle().fill(theme.statusWarn).frame(width: 8, height: 8)
            case .poor:
                Circle().fill(theme.statusError).frame(width: 8, height: 8)
            case .unknown, .none:
                Circle().fill(theme.ink3).frame(width: 8, height: 8)
            }
        }
    }
}
