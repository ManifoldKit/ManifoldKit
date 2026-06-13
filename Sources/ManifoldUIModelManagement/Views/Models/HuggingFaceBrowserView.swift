import SwiftUI
import UniformTypeIdentifiers
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

/// Inline HuggingFace browser content used by `ModelManagementSheet`.
struct HuggingFaceBrowserView: View {

    @Environment(ModelManagementViewModel.self) private var viewModel
    @Bindable private var modelRegistry: ModelRegistry

    let recommendedModelIDs: Set<String>?
    let recommendationTitle: String?
    let recommendationMessage: String?

    @State private var showImporter = false
    @State private var importSuccessMessage: String?
    @State private var importErrorMessage: String?
    @State private var pendingUseNowModel: DownloadableModel?
    /// Tracks model IDs we have already offered a "Use Now" prompt for, so that
    /// stale completed entries remaining in `trackedDownloads` are never re-offered
    /// when a subsequent download finishes and increments `completedDownloadCount`.
    @State private var promptedModelIDs: Set<String> = []

    init(
        modelRegistry: ModelRegistry,
        recommendedModelIDs: Set<String>?,
        recommendationTitle: String?,
        recommendationMessage: String?
    ) {
        self._modelRegistry = Bindable(modelRegistry)
        self.recommendedModelIDs = recommendedModelIDs
        self.recommendationTitle = recommendationTitle
        self.recommendationMessage = recommendationMessage
    }

    private static var importContentTypes: [UTType] {
        let gguf = UTType(filenameExtension: "gguf") ?? .data
        return [gguf, .folder]
    }

    /// Refreshes the registry; mirrors the legacy `ChatViewModel.refreshModels()`
    /// best-effort semantics — directory-creation errors are swallowed here
    /// (the legacy path surfaces them via `errorMessage`, but this view is
    /// invoked only after the directory is already populated, so the error
    /// path is unreachable in practice).
    ///
    /// Runs the directory scan off-main via `refreshAsync()` (#1774) so an
    /// import/download-completion refresh never re-blocks the main thread.
    /// `Task {}` inherits @MainActor; the off-main hop happens in the callee.
    private func refreshModels() {
        Task {
            do {
                try await modelRegistry.refreshAsync()
            } catch {
                Log.download.warning("HuggingFaceBrowserView: registry refresh failed: \(error)")
            }
        }
    }

    var body: some View {
        // Split into separately type-checked subtrees — the monolithic `body`
        // expression previously took >200ms to type-check (see
        // -warn-long-function-bodies).
        List {
            searchAndImportSection
            WhyDownloadView()
            importSuccessSection
            recommendationBannerSection
            recommendedSection
            searchingSection
            searchResultsSections
            errorSection
        }
        .onChange(of: viewModel.completedDownloadCount) {
            handleDownloadCompleted()
        }
        .alert(
            "Use \(pendingUseNowModel?.displayName ?? "") now?",
            isPresented: isUseNowAlertPresented,
            presenting: pendingUseNowModel
        ) { model in
            useNowAlertActions(for: model)
        } message: { _ in
            Text("The download is complete. Switch to this model?")
        }
        .onChange(of: modelRegistry.selectedModel) { _, newModel in
            viewModel.activeModelFileName = newModel?.fileName
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .onAppear {
            viewModel.activeModelFileName = modelRegistry.selectedModel?.fileName
            viewModel.loadRecommendations(preferredModelIDs: recommendedModelIDs)
        }
    }

    // MARK: - Sections

    private var searchAndImportSection: some View {
        @Bindable var viewModel = viewModel

        return Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search HuggingFace models...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.webSearch)
                    .submitLabel(.search)
                    #endif
                    .onSubmit {
                        Task { await viewModel.search() }
                    }
                    .accessibilityLabel("Search HuggingFace models")
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }

            Button {
                importSuccessMessage = nil
                importErrorMessage = nil
                showImporter = true
            } label: {
                Label("Import Local Model", systemImage: "plus.circle")
            }
            .accessibilityLabel("Import local model")
        }
    }

    @ViewBuilder
    private var importSuccessSection: some View {
        if let message = importSuccessMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(message)
            }
        }
    }

    @ViewBuilder
    private var recommendationBannerSection: some View {
        if let recommendationTitle, let recommendationMessage {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recommendationTitle)
                        .font(.headline)

                    Text(recommendationMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var recommendedSection: some View {
        Section("Recommended for Your Device") {
            if viewModel.recommendedModels.isEmpty {
                Text("No recommendations available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.recommendedModels) { model in
                    DownloadableModelRow(model: model)
                }
            }
        }
    }

    @ViewBuilder
    private var searchingSection: some View {
        if viewModel.isSearching {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Searching...")
                        .accessibilityLabel("Searching for models")
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsSections: some View {
        if !viewModel.searchResults.isEmpty {
            rankingControlsSection

            let groups = sortedGroups()
            let topModelID = (viewModel.sortMode == .recommended)
                ? viewModel.rankedVariants().first?.0.id
                : nil
            Section(viewModel.isDirectRepoLookup ? "Files in \(viewModel.searchQuery)" : "Search Results") {
                ForEach(groups) { group in
                    groupRow(for: group, topModelID: topModelID)
                }
            }
        }
    }

    private var rankingControlsSection: some View {
        @Bindable var viewModel = viewModel

        return Section {
            // Use-case picker — biases the fit ranking. Ranks, never filters:
            // every model below stays visible regardless of selection.
            Picker("Optimize for", selection: $viewModel.selectedUseCase) {
                ForEach(ModelUseCase.allCases, id: \.self) { useCase in
                    Text(useCaseLabel(useCase)).tag(useCase)
                }
            }
            .accessibilityLabel("Optimize recommendations for use case")

            // Sort escape hatch — power users who distrust the recommendation
            // can fall back to the deterministic size / downloads order.
            Picker("Sort", selection: $viewModel.sortMode) {
                ForEach(ModelManagementViewModel.SortMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Sort order")
        }
    }

    @ViewBuilder
    private func groupRow(for group: DownloadableModelGroup, topModelID: String?) -> some View {
        if group.variants.count == 1 {
            let variant = group.variants[0]
            DownloadableModelRow(
                model: variant,
                showFitGuidance: true,
                rationale: rationale(for: variant, topModelID: topModelID)
            )
        } else {
            multiVariantGroupRow(for: group)
        }
    }

    private func multiVariantGroupRow(for group: DownloadableModelGroup) -> some View {
        // "Best for your device": the top-ranked quant for the use
        // case when ranking is active, else the legacy memory-fit pick.
        let recommended = bestVariant(for: group)
        let noVariantFits = recommended != nil && !group.variants.contains(where: {
            $0.sizeBytes > 0 && viewModel.canRunModel(sizeBytes: $0.sizeBytes)
        })
        let sortedVariants = recommended.map { rec in
            [rec] + group.variants.filter { $0.id != rec.id }
        } ?? group.variants
        return DisclosureGroup {
            ForEach(sortedVariants) { variant in
                VStack(alignment: .leading, spacing: 2) {
                    DownloadableModelRow(
                        model: variant,
                        showFitGuidance: true,
                        rationale: variant.id == recommended?.id
                            ? viewModel.fitScore(for: variant)?.rationale
                            : nil
                    )
                    if variant.id == recommended?.id {
                        bestForDeviceBadge(noVariantFits: noVariantFits)
                    }
                }
            }
        } label: {
            groupLabel(for: group)
        }
    }

    private func bestForDeviceBadge(noVariantFits: Bool) -> some View {
        Text(bestForDeviceLabel(noVariantFits: noVariantFits))
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.green.opacity(0.15), in: Capsule())
            .foregroundStyle(.green)
            .padding(.leading, 22)
            .padding(.bottom, 2)
    }

    private func groupLabel(for group: DownloadableModelGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.displayName)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("\(group.variants.count) variants")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let sizeRange = group.sizeRange {
                    Text(sizeRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = importErrorMessage ?? viewModel.searchError {
            Section {
                Label {
                    Text(error)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Search error: \(error)")

                if viewModel.searchError != nil {
                    Button("Retry") {
                        Task { await viewModel.search() }
                    }
                }
            }
        }
    }

    // MARK: - Download completion

    private func handleDownloadCompleted() {
        viewModel.invalidateModelCache()
        refreshModels()

        // After refreshing, offer to switch to the newly completed model if it
        // isn't already the active selection and no prompt is already pending.
        // We filter by `promptedModelIDs` so that stale completed entries that
        // remain in `trackedDownloads` across multiple download cycles are never
        // re-offered when the count increments for a later download.
        guard pendingUseNowModel == nil else { return }
        let justCompleted = viewModel.trackedDownloads.values
            .filter {
                if case .completed = $0.status { return true }
                return false
            }
            .map(\.model)
            .first {
                $0.fileName != modelRegistry.selectedModel?.fileName
                    && !promptedModelIDs.contains($0.id)
            }
        if let model = justCompleted {
            promptedModelIDs.insert(model.id)
            pendingUseNowModel = model
        }
    }

    private var isUseNowAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingUseNowModel != nil },
            set: { if !$0 { pendingUseNowModel = nil } }
        )
    }

    @ViewBuilder
    private func useNowAlertActions(for model: DownloadableModel) -> some View {
        Button("Use Now") {
            if let match = modelRegistry.availableModels.first(where: { $0.fileName == model.fileName }) {
                modelRegistry.selectedModel = match
            } else {
                // refreshModels() now rescans off-main (#1774), so this branch is
                // reachable either if the file was deleted between download
                // completion and the tap, or if the user taps before the rescan
                // lands. Either way the safe action is to log and skip — the model
                // appears in Select once the rescan completes.
                Log.download.warning("Use Now: \(model.fileName) not found in availableModels — file may have been deleted or rescan still in flight")
            }
            pendingUseNowModel = nil
        }
        Button("Not Now", role: .cancel) {
            pendingUseNowModel = nil
        }
    }

    // MARK: - Ranking helpers

    /// Groups the current search results and orders them per the selected `sortMode`.
    ///
    /// `.recommended` orders groups by their best variant's composite fit score for the
    /// selected use case (rank, don't filter — all groups stay present). `.size` reuses
    /// the historical compatibility-tier order; `.downloads` defers to the default
    /// download-count sort. Within a group, variants are always shown smallest-first
    /// (see `DownloadableModelGroup.group`).
    private func sortedGroups() -> [DownloadableModelGroup] {
        switch viewModel.sortMode {
        case .size:
            return DownloadableModelGroup.group(
                viewModel.searchResults,
                sortKey: { viewModel.compatibilityTier(for: $0) }
            )
        case .downloads:
            return DownloadableModelGroup.group(viewModel.searchResults)
        case .recommended:
            // Best composite per group; higher first. Groups with no scoreable variant
            // (all size 0) sort to the bottom but are never dropped.
            let groups = DownloadableModelGroup.group(viewModel.searchResults)
            return groups.sorted { lhs, rhs in
                bestComposite(in: lhs) > bestComposite(in: rhs)
            }
        }
    }

    /// Highest composite fit score among a group's variants, or `-1` when none score.
    private func bestComposite(in group: DownloadableModelGroup) -> Double {
        group.variants
            .compactMap { viewModel.fitScore(for: $0)?.composite }
            .max() ?? -1
    }

    /// The variant to surface as "Best for your device".
    ///
    /// In `.recommended` mode this is the top-ranked quant for the use case; otherwise
    /// it falls back to the legacy largest-that-fits memory pick so the size/downloads
    /// modes keep their familiar behaviour.
    private func bestVariant(for group: DownloadableModelGroup) -> DownloadableModel? {
        switch viewModel.sortMode {
        case .recommended:
            let ranked = group.variants
                .compactMap { variant -> (DownloadableModel, Double)? in
                    guard let score = viewModel.fitScore(for: variant) else { return nil }
                    return (variant, score.composite)
                }
                .max(by: { $0.1 < $1.1 })
            // Fall back to the memory-fit pick when nothing scores (all size 0).
            return ranked?.0 ?? group.recommendedVariant(for: viewModel.deviceCapabilityService)
        case .size, .downloads:
            return group.recommendedVariant(for: viewModel.deviceCapabilityService)
        }
    }

    /// The one-line rationale for a single-variant row, shown only on the overall
    /// top-ranked model so the "why" appears once rather than on every row.
    private func rationale(for model: DownloadableModel, topModelID: String?) -> String? {
        guard let topModelID, model.id == topModelID else { return nil }
        return viewModel.fitScore(for: model)?.rationale
    }

    private func useCaseLabel(_ useCase: ModelUseCase) -> String {
        switch useCase {
        case .general:    return "General"
        case .coding:     return "Coding"
        case .reasoning:  return "Reasoning"
        case .chat:       return "Chat"
        case .multimodal: return "Multimodal"
        case .embedding:  return "Embedding"
        }
    }

    private func bestForDeviceLabel(noVariantFits: Bool) -> String {
        if noVariantFits { return "Smallest available" }
        return viewModel.sortMode == .recommended ? "Best for your device" : "Recommended"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let imported = try viewModel.importModel(from: url)
                refreshModels()
                importErrorMessage = nil
                importSuccessMessage = "Imported \(imported.name). Open Select to use it."
            } catch {
                importSuccessMessage = nil
                importErrorMessage = error.localizedDescription
            }

        case .failure(let error):
            importSuccessMessage = nil
            importErrorMessage = error.localizedDescription
        }
    }
}
