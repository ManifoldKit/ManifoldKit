import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// A row displaying a downloadable model with compatibility badge and download controls.
///
/// Shows the model name, size, description, and a contextual action: download button,
/// progress indicator, or "Downloaded" badge depending on the model's current state.
/// When the model's backend is not available in the current build, an informational
/// note is shown — the user can still download the file for future use.
public struct DownloadableModelRow: View {

    public let model: DownloadableModel

    @Environment(ModelManagementViewModel.self) private var viewModel
    @Environment(FrameworkCapabilityService.self) private var capabilityService: FrameworkCapabilityService?

    public init(model: DownloadableModel) {
        self.model = model
    }

    /// Resolves backend compatibility from the injected `FrameworkCapabilityService`
    /// when one is in the environment; otherwise falls back to the compiled-backend
    /// contract via `CompiledBackends.current.compatibility(for:)`, which can return
    /// `.unsupported` for backends that were not compiled into the current build.
    private var backendCompatibility: ModelCompatibilityResult {
        capabilityService?.compatibility(for: model.modelType)
            ?? CompiledBackends.current.compatibility(for: model.modelType)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            compatibilityBadge
                .accessibilityLabel(compatibilityLabel)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(model.sizeFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let quant = model.quantization {
                        Text(quant)
                            .font(.caption2)
                            .fontDesign(.monospaced)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }

                    if model.isCurated {
                        Text("Curated")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Curated model")
                    }
                }

                Text(model.fileName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let description = model.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Inform the user when the backend for this model type is unavailable.
                // Download is still allowed so the file is ready for future use.
                if let reason = backendCompatibility.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.top, 1)
                        .accessibilityLabel("Backend unavailable: \(reason)")
                }

                // Phase 1 of #367: surface verified vs. unverified downloads.
                // When the curated entry ships an `expectedSHA256`, the validator
                // enforces it after download; when it is `nil` (search results,
                // user-pasted URLs, MLX snapshots without per-file digests), the
                // download proceeds without integrity verification.
                if model.expectedSHA256 == nil {
                    Text("Unverified source")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Unverified source — no SHA-256 hash available")
                }
            }

            Spacer()

            trailingContent
        }
        .padding(.vertical, 4)
    }

    // MARK: - Compatibility Badge

    /// Colored circle indicating whether this device can run the model.
    @ViewBuilder
    private var compatibilityBadge: some View {
        // When size is unknown (0), show neutral gray instead of misleading green.
        if model.sizeBytes == 0 {
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
        } else {
            let canRun = viewModel.canRunModel(sizeBytes: model.sizeBytes)
            let isBorderline = !canRun && viewModel.canRunModel(sizeBytes: model.sizeBytes * 80 / 100)

            Circle()
                .fill(badgeColor(canRun: canRun, isBorderline: isBorderline))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
        }
    }

    private func badgeColor(canRun: Bool, isBorderline: Bool) -> Color {
        if canRun { return .green }
        if isBorderline { return .yellow }
        return .red
    }

    private var compatibilityLabel: String {
        let canRun = viewModel.canRunModel(sizeBytes: model.sizeBytes)
        if canRun { return "Compatible with this device" }
        return "May be too large for this device"
    }

    // MARK: - Trailing Content (Download/Progress/Badge)

    @ViewBuilder
    private var trailingContent: some View {
        if viewModel.isModelDownloaded(model) {
            if viewModel.activeModelFileName == model.fileName {
                activeModelBadge
            } else {
                downloadedBadge
            }
        } else if let state = viewModel.downloadState(for: model) {
            DownloadProgressView(state: state)
        } else {
            downloadButton
        }
    }

    private var activeModelBadge: some View {
        Label("In Use", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.blue)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("Active model")
    }

    private var downloadedBadge: some View {
        Label("Downloaded", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
    }

    private var downloadButton: some View {
        let insufficient = viewModel.diskSpaceInsufficient(for: model)
        return VStack(alignment: .trailing, spacing: 2) {
            Button {
                viewModel.startDownload(model)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(insufficient ? Color.secondary : Color.blue)
            }
            .buttonStyle(.plain)
            .disabled(insufficient)
            .accessibilityLabel("Download \(model.displayName)")
            .accessibilityHint(
                insufficient
                ? "Insufficient storage"
                : "Downloads \(model.sizeFormatted) model to this device"
            )

            if insufficient {
                Text("Insufficient storage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        DownloadableModelRow(
            model: DownloadableModel(
                repoID: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
                fileName: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
                displayName: "Mistral 7B Instruct v0.3",
                modelType: .gguf,
                sizeBytes: 4_100_000_000,
                isCurated: true,
                description: "Balanced 7B model, good storytelling quality"
            )
        )
    }
    .environment(ModelManagementViewModel())
}
