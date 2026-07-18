import SwiftUI
import ManifoldRuntime

/// Milestone-named bootstrap loading screen (`docs/UI-REFRESH-2026.md` §6A:
/// "Loading states name their milestone").
///
/// Consumes ``RuntimeBootstrapMilestone`` — the same phase enum
/// `ManifoldBootstrap.build(configuration:)` emits on its progress stream —
/// so a host that drains that stream into `@State` can hand each milestone
/// straight to this view with no translation layer. Distinct from
/// ``ModelLoadingIndicatorView`` (which times a single model/endpoint load,
/// not the whole-app bootstrap sequence) and from a bootstrap *failure*,
/// which owns the whole screen but is a host-supplied error view, not this
/// type — this view only ever represents the in-progress path.
///
/// **`public`, not `package`** — deliberately, unlike this tranche's other
/// new state screens. `ManifoldBootstrap.build(configuration:)` runs before
/// `ChatView` (or anything else in `ManifoldUI`) exists, so this view has no
/// internal call site to wire into; its only possible consumer is host-app
/// launch-scene code (the bootstrap recipe's `ProgressView("Starting…")`
/// placeholder in `AGENTS.md`), which sits outside the package boundary.
/// `package` access would make this type unconstructible by the one caller
/// it exists for.
public struct BootstrapLoadingView: View {

    @Environment(\.manifoldTheme) private var theme

    let milestone: RuntimeBootstrapMilestone

    public init(milestone: RuntimeBootstrapMilestone) {
        self.milestone = milestone
    }

    public var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: milestone.fractionComplete)
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)

            Text(milestone.description)
                .font(theme.type.caption)
                .foregroundStyle(theme.ink2)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting up: \(milestone.description)")
        .accessibilityIdentifier("bootstrap-loading-\(milestone)")
    }
}

#Preview("Building model container") {
    BootstrapLoadingView(milestone: .buildingModelContainer)
}

#Preview("Complete") {
    BootstrapLoadingView(milestone: .complete)
}
