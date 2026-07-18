import SwiftUI

/// First-run state screen (`docs/UI-REFRESH-2026.md` §6A): "First run is a
/// funnel (primary → model management, secondary → endpoint setup)."
///
/// Rendered instead of the plain welcome placeholder when
/// ``ChatViewModel/isFirstRun`` is `true` and no model is loaded yet — a
/// bootstrap failure owns the *whole* screen (see ``BootstrapLoadingView``'s
/// sibling failure treatment); this view owns only the "nothing configured
/// yet" first-launch moment, which is recoverable and welcoming rather than
/// an error state.
///
/// Wiring note: this view is intentionally host-agnostic (two closures, no
/// `@Environment` reads) so it composes into `ChatNoModelLoadedContent`
/// (`ChatShellViews.swift`, owned by the L1/chrome tranche) without this
/// tranche needing to touch that file directly.
public struct FirstRunFunnelView: View {

    @Environment(\.manifoldTheme) private var theme

    let appName: String
    let onBrowseModels: () -> Void
    let onConfigureEndpoint: () -> Void

    public init(
        appName: String,
        onBrowseModels: @escaping () -> Void,
        onConfigureEndpoint: @escaping () -> Void
    ) {
        self.appName = appName
        self.onBrowseModels = onBrowseModels
        self.onConfigureEndpoint = onConfigureEndpoint
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to \(appName)")
                    .font(theme.type.title)

                Text("Download a model on-device, or connect a cloud backend, to start chatting.")
                    .font(theme.type.body)
                    .foregroundStyle(theme.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            VStack(spacing: 10) {
                Button(action: onBrowseModels) {
                    Label("Browse Models", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("first-run-browse-models-button")

                Button(action: onConfigureEndpoint) {
                    Text("Connect a cloud endpoint instead")
                }
                .buttonStyle(.plain)
                .font(theme.type.caption)
                .foregroundStyle(theme.ink2)
                .accessibilityIdentifier("first-run-configure-endpoint-button")
            }
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run-funnel")
    }
}

#Preview {
    FirstRunFunnelView(
        appName: "Sample Chat",
        onBrowseModels: {},
        onConfigureEndpoint: {}
    )
}
