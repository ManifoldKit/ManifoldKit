import SwiftUI

/// Loading indicator shown during model loading, with optional progress.
public struct ModelLoadingIndicatorView: View {
    public let progress: Double?
    public let onCancel: () -> Void

    public init(progress: Double? = nil, onCancel: @escaping () -> Void = {}) {
        self.progress = progress
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
            } else {
                ProgressView()
            }
            Text("Loading model…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading model, please wait")
    }
}

#Preview("Indeterminate") {
    ModelLoadingIndicatorView()
}

#Preview("With Progress") {
    ModelLoadingIndicatorView(progress: 0.65)
}
