import SwiftUI

/// One tappable demo-scenario card. Used by `ChatEmptyStateView` and
/// referenced indirectly by the toolbar `Demos` menu (which renders plain
/// `Menu`/`Button` rows without this view).
struct DemoScenarioCard: View {

    let scenario: DemoScenario
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: scenario.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(scenario.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(scenario.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(scenario.accessibilityID)
        .accessibilityLabel(Text("\(scenario.title). \(scenario.blurb)"))
    }
}
