import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Displays the active operational warnings from a `DiagnosticsService`.
///
/// Designed to live inside a settings sheet as a disclosure group or
/// standalone navigation destination. Each warning can be dismissed
/// individually; "Dismiss All" clears the list.
public struct DiagnosticsView: View {

    @Bindable private var diagnostics: DiagnosticsService

    public init(diagnostics: DiagnosticsService) {
        self.diagnostics = diagnostics
    }

    public var body: some View {
        Group {
            if diagnostics.isEmpty {
                ContentUnavailableView(
                    "No Warnings",
                    systemImage: "checkmark.circle",
                    description: Text("Background tasks are running cleanly.")
                )
            } else {
                List {
                    ForEach(diagnostics.warnings) { warning in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(warning.error.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(warning.error.localizedDescription)
                                .font(.callout)
                            Text(warning.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .swipeActions {
                            Button("Dismiss", role: .destructive) {
                                diagnostics.dismiss(warning.id)
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Dismiss All") {
                            diagnostics.dismissAll()
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}

/// A compact disclosure showing the active operational warnings from a
/// `DiagnosticsService`, rendered as one `Section` (header "Diagnostics")
/// so it drops directly into a `Form`/`List` alongside sibling sections.
///
/// Embedded in ``GenerationSettingsView``'s Advanced section, wherever a
/// `SessionManagerViewModel` carrying a `DiagnosticsService` reaches that
/// view via the environment (`.environment(sessionManager)` from the
/// canonical bootstrap recipe, or any host that calls
/// `SessionManagerViewModel.configure(bootstrap:)` /
/// `configureAndLoad(bootstrap:)`). Hosts that build their own settings
/// surface — or want the row somewhere other than "Advanced" — can still
/// construct it directly and embed it standalone; it needs nothing beyond
/// the `DiagnosticsService` passed to `init(diagnostics:)`.
public struct DiagnosticsDisclosure: View {

    @Bindable private var diagnostics: DiagnosticsService

    public init(diagnostics: DiagnosticsService) {
        self.diagnostics = diagnostics
    }

    public var body: some View {
        Section {
            if diagnostics.isEmpty {
                Label("No warnings", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics.warnings) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.error.category).font(.caption).foregroundStyle(.secondary)
                            Text(warning.error.localizedDescription).font(.callout)
                        }
                        Spacer()
                        Button {
                            diagnostics.dismiss(warning.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss warning")
                    }
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            if !diagnostics.isEmpty {
                Text("\(diagnostics.count) non-fatal warning\(diagnostics.count == 1 ? "" : "s") from background tasks.")
            }
        }
    }
}
