import SwiftUI
import BaseChatRuntime

/// Collapsible explainer that helps users understand why they might want
/// to download a model instead of using the built-in Foundation model.
///
/// Collapsed by default to keep the model browser clean for returning users.
public struct WhyDownloadView: View {

    @Environment(ModelManagementViewModel.self) private var viewModel

    @State private var isExpanded = false

    public init() {}

    public var body: some View {
        DisclosureGroup("Why download a model?", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("The built-in Apple Foundation Model works great for quick chats with no setup required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloaded models offer:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    benefitRow(icon: "text.justify.left", text: "Longer context windows for extended conversations")
                    benefitRow(icon: "slider.horizontal.3", text: "More control over generation settings")
                    benefitRow(icon: "sparkles", text: "Specialized models fine-tuned for creative writing")
                    benefitRow(icon: "arrow.left.arrow.right", text: "Compatibility with open-source character formats")
                }

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("Your device can run \(viewModel.recommendation.description.lowercased()).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Benefit Row

    private func benefitRow(icon: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 20)
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        WhyDownloadView()
    }
    .environment(ModelManagementViewModel())
}
