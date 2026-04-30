import SwiftUI
import UniformTypeIdentifiers
import BaseChatRuntime
import BaseChatInference
import BaseChatUI

/// Inline HuggingFace browser content used by `ModelManagementSheet`.
struct HuggingFaceBrowserView: View {

    @Environment(ModelManagementViewModel.self) private var viewModel
    @Environment(ChatViewModel.self) private var chatViewModel

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

    private static var importContentTypes: [UTType] {
        let gguf = UTType(filenameExtension: "gguf") ?? .data
        return [gguf, .folder]
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            Section {
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

            WhyDownloadView()

            if let message = importSuccessMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(message)
                }
            }

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

            if !viewModel.searchResults.isEmpty {
                let groups = DownloadableModelGroup.group(
                    viewModel.searchResults,
                    sortKey: { viewModel.compatibilityTier(for: $0) }
                )
                Section(viewModel.isDirectRepoLookup ? "Files in \(viewModel.searchQuery)" : "Search Results") {
                    ForEach(groups) { group in
                        if group.variants.count == 1 {
                            DownloadableModelRow(model: group.variants[0])
                        } else {
                            let recommended = group.recommendedVariant(for: viewModel.deviceCapabilityService)
                            let noVariantFits = recommended != nil && !group.variants.contains(where: {
                                $0.sizeBytes > 0 && viewModel.canRunModel(sizeBytes: $0.sizeBytes)
                            })
                            let sortedVariants = recommended.map { rec in
                                [rec] + group.variants.filter { $0.id != rec.id }
                            } ?? group.variants
                            DisclosureGroup {
                                ForEach(sortedVariants) { variant in
                                    VStack(alignment: .leading, spacing: 2) {
                                        DownloadableModelRow(model: variant)
                                        if variant.id == recommended?.id {
                                            Text(noVariantFits ? "Smallest available" : "Recommended")
                                                .font(.caption2)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(.green.opacity(0.15), in: Capsule())
                                                .foregroundStyle(.green)
                                                .padding(.leading, 22)
                                                .padding(.bottom, 2)
                                        }
                                    }
                                }
                            } label: {
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
                        }
                    }
                }
            }

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
        .onChange(of: viewModel.completedDownloadCount) {
            viewModel.invalidateModelCache()
            chatViewModel.refreshModels()

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
                    $0.fileName != chatViewModel.selectedModel?.fileName
                        && !promptedModelIDs.contains($0.id)
                }
            if let model = justCompleted {
                promptedModelIDs.insert(model.id)
                pendingUseNowModel = model
            }
        }
        .alert(
            "Use \(pendingUseNowModel?.displayName ?? "") now?",
            isPresented: Binding(
                get: { pendingUseNowModel != nil },
                set: { if !$0 { pendingUseNowModel = nil } }
            ),
            presenting: pendingUseNowModel
        ) { model in
            Button("Use Now") {
                if let match = chatViewModel.availableModels.first(where: { $0.fileName == model.fileName }) {
                    chatViewModel.selectedModel = match
                } else {
                    // refreshModels() runs synchronously in onChange, so this branch is
                    // only reachable if the file was deleted between download completion
                    // and the user tapping "Use Now".
                    Log.download.warning("Use Now: \(model.fileName) not found in availableModels — file may have been deleted")
                }
                pendingUseNowModel = nil
            }
            Button("Not Now", role: .cancel) {
                pendingUseNowModel = nil
            }
        } message: { _ in
            Text("The download is complete. Switch to this model?")
        }
        .onChange(of: chatViewModel.selectedModel) { _, newModel in
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
            viewModel.activeModelFileName = chatViewModel.selectedModel?.fileName
            viewModel.loadRecommendations(preferredModelIDs: recommendedModelIDs)
        }
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
                chatViewModel.refreshModels()
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
