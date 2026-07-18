import SwiftUI
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

/// A row displaying a summary of an ``APIEndpointRecord`` configuration.
///
/// Shows the endpoint name, provider badge, model name, and a
/// ready/incomplete status indicator based on
/// ``APIEndpointRecord/validateBaseURL()``. When the endpoint is invalid,
/// the specific ``APIEndpointValidationReason`` is surfaced as a subtitle
/// so the user knows what to fix.
package struct APIEndpointRow: View {

    package let endpoint: APIEndpointRecord

    @Environment(\.manifoldTheme) private var theme: ManifoldTheme

    package init(endpoint: APIEndpointRecord) {
        self.endpoint = endpoint
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(endpoint.name)
                    .font(.headline)

                Spacer()

                Text(endpoint.provider.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
            }

            HStack(spacing: 8) {
                Text(endpoint.modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch endpoint.validateBaseURL() {
                case .success:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(theme.statusOK)
                case .failure:
                    Label("Incomplete", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if case .failure(let reason) = endpoint.validateBaseURL(),
               let description = reason.errorDescription {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.name), \(endpoint.provider.displayName), \(endpoint.modelName)")
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint("Tap to edit")
    }

    /// Voice-over status string: "Ready" or the specific failure reason.
    private var accessibilityStatus: String {
        switch endpoint.validateBaseURL() {
        case .success:
            return "Ready"
        case .failure(let reason):
            return reason.errorDescription ?? "Incomplete"
        }
    }
}

// MARK: - Preview

#Preview("Endpoint Row") {
    List {
        APIEndpointRow(
            endpoint: APIEndpointRecord(name: "My OpenAI", provider: .openAI)
        )
        APIEndpointRow(
            endpoint: APIEndpointRecord(name: "Local Ollama", provider: .ollama)
        )
    }
}
