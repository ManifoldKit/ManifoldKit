import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Compact download progress indicator with cancel button.
///
/// Displays a circular progress ring, percentage text, bytes transferred,
/// and a cancel button. Used inline within `DownloadableModelRow`.
package struct DownloadProgressView: View {

    package let state: DownloadState

    @Environment(ModelManagementViewModel.self) private var viewModel

    package init(state: DownloadState) {
        self.state = state
    }

    package var body: some View {
        switch state.status {
        case .queued:
            queuedView

        case .downloading(let progress, let bytesDownloaded, let totalBytes):
            downloadingView(progress: progress, bytesDownloaded: bytesDownloaded, totalBytes: totalBytes)

        case .completed:
            completedView

        case .failed(let error):
            failedView(error: error)

        case .cancelled:
            cancelledView
        }
    }

    // MARK: - Status Views

    private var queuedView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Queued")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Download queued")
    }

    private func downloadingView(progress: Double, bytesDownloaded: Int64, totalBytes: Int64) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)

                Text(percentageText(progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.cancelDownload(id: state.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }

            Text(bytesText(downloaded: bytesDownloaded, total: totalBytes))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
        .accessibilityValue(bytesText(downloaded: bytesDownloaded, total: totalBytes))
    }

    private var completedView: some View {
        Label("Done", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
    }

    private func failedView(error: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label {
                Text("Failed")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .help(error)
            .accessibilityLabel("Download failed: \(error)")

            Button {
                viewModel.retryDownload(for: state.model)
            } label: {
                Text("Retry")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry download")
        }
    }

    private var cancelledView: some View {
        Text("Cancelled")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Formatting Helpers

    private func percentageText(_ progress: Double) -> String {
        "\(Int(progress * 100))%"
    }

    private func bytesText(downloaded: Int64, total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let downloadedStr = formatter.string(fromByteCount: downloaded)
        let totalStr = formatter.string(fromByteCount: total)
        return "\(downloadedStr) / \(totalStr)"
    }
}

// MARK: - Preview

#Preview {
    let model = DownloadableModel(
        repoID: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
        fileName: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
        displayName: "Mistral 7B Instruct v0.3",
        modelType: .gguf,
        sizeBytes: 4_100_000_000
    )
    let state = DownloadState(model: model)

    VStack(spacing: 20) {
        DownloadProgressView(state: state)
    }
    .padding()
    .environment(ModelManagementViewModel())
}
