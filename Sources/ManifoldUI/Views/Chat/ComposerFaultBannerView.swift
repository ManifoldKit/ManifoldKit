import SwiftUI

/// Composer-scoped fault banner (`docs/UI-REFRESH-2026.md` §6A — "session-
/// level recoverable → banner above the composer with its fix inline").
///
/// Distinct from ``ErrorBannerView`` (turn/session errors surfaced from
/// `ChatViewModel.activeError`, `ChatShellViews.swift`, owned by the
/// L1/chrome tranche): this banner is for faults that are properties of the
/// *composer itself* rather than of a turn — e.g. a ``ComposerPermissionGate``
/// item disappearing because a required capability check failed, or an
/// attachment the composer could not stage. It renders directly above the
/// input field, one tap from its own fix, and never blocks typing/sending
/// text (only the affected affordance is unavailable).
/// Wired into ``ChatComposerSection`` (`ChatShellViews.swift`): rendered
/// above `ChatInputBar` when voice input is enabled
/// (`ManifoldConfiguration.Features.showAudioInput`) but silently withheld
/// because `NSMicrophoneUsageDescription` is missing — the inverse of
/// `ComposerPermissionGate.shouldShowAudioInput`. `package` — an internal
/// chrome component, not a customization seam.
package struct ComposerFaultBannerView: View {

    @Environment(\.manifoldTheme) private var theme

    let message: String
    let fixLabel: String?
    let onFix: (() -> Void)?

    package init(
        message: String,
        fixLabel: String? = nil,
        onFix: (() -> Void)? = nil
    ) {
        self.message = message
        self.fixLabel = fixLabel
        self.onFix = onFix
    }

    package var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(theme.statusWarnColor)
                .accessibilityHidden(true)

            Text(message)
                .font(theme.type.caption)
                .foregroundStyle(theme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let fixLabel, let onFix {
                Button(fixLabel, action: onFix)
                    .buttonStyle(.borderless)
                    .font(theme.type.caption.weight(.semibold))
                    .accessibilityIdentifier("composer-fault-fix-button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.statusWarnSoft, in: RoundedRectangle(cornerRadius: theme.shape.sm))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer-fault-banner")
    }
}

#Preview("With fix") {
    ComposerFaultBannerView(
        message: "Microphone access is off — voice input is unavailable.",
        fixLabel: "Open Settings",
        onFix: {}
    )
    .padding()
}

#Preview("No fix") {
    ComposerFaultBannerView(message: "Attachment could not be staged.")
        .padding()
}
