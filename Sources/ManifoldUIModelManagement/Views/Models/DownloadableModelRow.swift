import SwiftUI
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

/// A row displaying a downloadable model with compatibility badge and download controls.
///
/// Shows the model name, size, description, and a contextual action: download button,
/// progress indicator, or "Downloaded" badge depending on the model's current state.
/// When the model's backend is not available in the current build, an informational
/// note is shown — the user can still download the file for future use.
package struct DownloadableModelRow: View {

    package let model: DownloadableModel

    /// When `true`, render the device-aware speed badge and (if `rationale` is set)
    /// the one-line "why". The browser passes `true` for search-result variants and
    /// the recommended pick; it stays `false` for contexts (e.g. the curated
    /// "Recommended for Your Device" section) that already convey fit some other way.
    private let showFitGuidance: Bool

    /// Pre-computed one-line justification shown under the row when non-`nil`.
    /// Surfaced only on the top-ranked / recommended variant to avoid repeating it
    /// on every row. Honest by construction — see `ModelFitScore.rationale`.
    private let rationale: String?

    /// Runtime backend-availability source. Threaded explicitly from
    /// `HuggingFaceBrowserView` (which already holds the host's registry) rather than
    /// read from `CompiledBackends.current`: MLX / llama.cpp register at RUNTIME from
    /// the companion packages and are NEVER in `CompiledBackends.detected()` by
    /// construction, so a compile-time read reports every GGUF/MLX row unavailable
    /// even when the companion is installed and registered. Same fix, same reason as
    /// `ModelManagementSheet.availableTabs`' `runtimeDownloadable` check (#1749).
    private let modelRegistry: ModelRegistry

    @Environment(ModelManagementViewModel.self) private var viewModel
    @Environment(FrameworkCapabilityService.self) private var capabilityService: FrameworkCapabilityService?
    @Environment(\.manifoldTheme) private var theme

    package init(
        model: DownloadableModel,
        modelRegistry: ModelRegistry,
        showFitGuidance: Bool = false,
        rationale: String? = nil
    ) {
        self.model = model
        self.modelRegistry = modelRegistry
        self.showFitGuidance = showFitGuidance
        self.rationale = rationale
    }

    /// Resolves backend compatibility from the injected `FrameworkCapabilityService`
    /// when one is in the environment; otherwise from `modelRegistry`, which reflects
    /// RUNTIME backend registration (see the `modelRegistry` property doc comment
    /// above for why `CompiledBackends.current` must never be used here).
    @MainActor
    static func resolveCompatibility(
        for modelType: ModelType,
        capabilityService: FrameworkCapabilityService?,
        modelRegistry: ModelRegistry
    ) -> ModelCompatibilityResult {
        capabilityService?.compatibility(for: modelType)
            ?? modelRegistry.compatibility(for: modelType)
    }

    private var backendCompatibility: ModelCompatibilityResult {
        Self.resolveCompatibility(
            for: model.modelType,
            capabilityService: capabilityService,
            modelRegistry: modelRegistry
        )
    }

    package var body: some View {
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
                            .background(theme.infoSoft, in: Capsule())
                            .foregroundStyle(theme.infoColor)
                            .accessibilityLabel("Curated model")
                    }

                    fitBadge
                    speedBadge
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
                        .foregroundStyle(theme.statusWarnColor)
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

                // One-line honest "why" on the recommended/top variant only. Built from
                // qualitative buckets, never raw tok/s — see ModelFitScore.rationale.
                if let rationale {
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                        .accessibilityLabel("Why: \(rationale)")
                }
            }

            Spacer()

            trailingContent
        }
        .padding(.vertical, 4)
    }

    // MARK: - Fit Badge

    /// Three-way device-fit verdict badge (Excellent / Good / Marginal / Not recommended)
    /// rendered green / yellow / red for *this* device, before download.
    ///
    /// Shown only when `showFitGuidance` is set and the model has a usable size, alongside
    /// the `SpeedClass` badge. Uses the `FitQuality` *word* and a tint, never a raw composite
    /// score — the underlying figure is a coarse estimate and a bare number reads as fact.
    @ViewBuilder
    private var fitBadge: some View {
        if showFitGuidance, model.sizeBytes > 0, let score = viewModel.fitScore(for: model) {
            let quality = score.fitQuality
            Text(quality.label)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Self.fitTint(quality, theme: theme).opacity(0.15), in: Capsule())
                .foregroundStyle(Self.fitTint(quality, theme: theme))
                .accessibilityLabel("Device fit: \(quality.label). Approximate guidance, not a guarantee.")
        }
    }

    /// Maps a `FitQuality` verdict to its badge tint, from the status tier
    /// (`ManifoldTheme.statusOKColor`/`statusWarnColor`/`statusErrorColor`).
    /// Static + pure so the verdict→color contract is unit-testable without
    /// standing up a SwiftUI hierarchy; `theme` defaults to ``ManifoldTheme/standard``
    /// so existing call sites (this type's own `FitVerdictBadgeTests` pin) keep
    /// compiling and keep asserting the historical green/yellow/red values.
    static func fitTint(_ quality: FitQuality, theme: ManifoldTheme = .standard) -> Color {
        switch quality {
        case .excellent, .good:  return theme.statusOKColor
        case .marginal:          return theme.statusWarnColor
        case .notRecommended:    return theme.statusErrorColor
        }
    }

    // MARK: - Speed Badge

    /// Qualitative speed badge (Fast / Usable / Sluggish / Too slow) for the device.
    ///
    /// Shown only when `showFitGuidance` is set and the model has a usable size. We
    /// present the `SpeedClass` *word*, never a raw tok/s decimal — the underlying
    /// figure is a coarse estimate, and a bare number reads as a measured fact.
    @ViewBuilder
    private var speedBadge: some View {
        if showFitGuidance, model.sizeBytes > 0, let score = viewModel.fitScore(for: model) {
            let speed = score.speedClass
            Text(speed.label)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(speedTint(speed).opacity(0.15), in: Capsule())
                .foregroundStyle(speedTint(speed))
                .accessibilityLabel("Estimated speed: \(speed.label). Approximate guidance, not a guarantee.")
        }
    }

    /// `.usable`/`.sluggish` don't fit the OK/warn/error severity triad (see
    /// `ManifoldTheme.categorical`'s doc comment), so they route through the
    /// categorical tier; `.fast`/`.tooSlow` map naturally onto status tokens.
    private func speedTint(_ speed: SpeedClass) -> Color {
        switch speed {
        case .fast:     return theme.statusOKColor
        case .usable:   return theme.categorical.blueColor
        case .sluggish: return theme.categorical.orangeColor
        case .tooSlow:  return theme.statusErrorColor
        }
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
        if canRun { return theme.statusOKColor }
        if isBorderline { return theme.statusWarnColor }
        return theme.statusErrorColor
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
            .foregroundStyle(theme.infoColor)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("Active model")
    }

    private var downloadedBadge: some View {
        Label("Downloaded", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(theme.statusOKColor)
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
                    .foregroundStyle(insufficient ? Color.secondary : theme.infoColor)
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

private struct DownloadableModelRowPreviewHost: View {
    let inferenceService = InferenceService()
    var modelRegistry: ModelRegistry {
        ModelRegistry(
            inferenceService: inferenceService,
            modelStorage: ModelStorageService(baseDirectory: FileManager.default.temporaryDirectory)
        )
    }

    var body: some View {
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
                ),
                modelRegistry: modelRegistry
            )
        }
        .environment(ModelManagementViewModel())
        .task { inferenceService.declareSupport(for: .gguf) }
    }
}

#Preview {
    DownloadableModelRowPreviewHost()
}
