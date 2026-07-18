import SwiftUI

/// In-transcript turn-failure card (`docs/UI-REFRESH-2026.md` §6A — "the
/// rule: failures render at their scope. Turn-level → in-transcript card
/// (statusError soft fill, Retry + Details)").
///
/// Distinct from ``ErrorBannerView`` (`ChatShellViews.swift`, owned by the
/// L1/chrome tranche) — that banner renders *session-level* recoverable
/// faults (API key missing, memory pressure) above the composer. This card
/// is for a single failed *turn*: the assistant's generation failed for this
/// message and the failure should read at the message's own position in the
/// transcript rather than escalating to a page-level banner.
///
/// Wired into ``ChatHistoryView``: rendered after the transcript when
/// `viewModel.activeError?.kind == .generation` — `ChatErrorRecoveryBanner`
/// explicitly excludes that kind so it never double-renders as a banner too.
/// `package` — an internal chrome component, not a customization seam.
package struct TurnFailureCardView: View {

    @Environment(\.manifoldTheme) private var theme

    let message: String
    let onRetry: (() -> Void)?
    let onDetails: (() -> Void)?

    package init(
        message: String,
        onRetry: (() -> Void)? = nil,
        onDetails: (() -> Void)? = nil
    ) {
        self.message = message
        self.onRetry = onRetry
        self.onDetails = onDetails
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.statusErrorColor)
                    .accessibilityHidden(true)
                Text(message)
                    .font(theme.type.caption)
                    .foregroundStyle(theme.ink)
            }

            HStack(spacing: 12) {
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderless)
                        .font(theme.type.caption.weight(.semibold))
                        .accessibilityIdentifier("turn-failure-retry-button")
                }
                if let onDetails {
                    Button("Details", action: onDetails)
                        .buttonStyle(.borderless)
                        .font(theme.type.caption)
                        .foregroundStyle(theme.ink2)
                        .accessibilityIdentifier("turn-failure-details-button")
                }
            }
        }
        .padding(10)
        .background(theme.statusErrorSoft, in: RoundedRectangle(cornerRadius: theme.shape.md))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("turn-failure-card")
    }
}

#Preview("Retry + Details") {
    TurnFailureCardView(
        message: "Generation failed — the model ran out of context.",
        onRetry: {},
        onDetails: {}
    )
    .padding()
}

#Preview("No actions") {
    TurnFailureCardView(message: "Generation failed.")
        .padding()
}
