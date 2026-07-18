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
/// Wired into ``ChatView`` via `ChatNoModelLoadedContent`
/// (`ChatShellViews.swift`): rendered instead of the plain welcome
/// placeholder when `isFirstRun` is true and no models are configured yet.
/// `package` — an internal chrome component, not a customization seam a
/// consumer app constructs directly.
package struct FirstRunFunnelView: View {

    @Environment(\.manifoldTheme) private var theme

    let appName: String
    let onBrowseModels: () -> Void
    let onConfigureEndpoint: () -> Void

    package init(
        appName: String,
        onBrowseModels: @escaping () -> Void,
        onConfigureEndpoint: @escaping () -> Void
    ) {
        self.appName = appName
        self.onBrowseModels = onBrowseModels
        self.onConfigureEndpoint = onConfigureEndpoint
    }

    package var body: some View {
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
