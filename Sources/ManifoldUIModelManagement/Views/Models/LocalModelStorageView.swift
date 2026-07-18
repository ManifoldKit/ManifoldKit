import SwiftUI
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

/// Inline local model storage content used by `ModelManagementSheet`.
struct LocalModelStorageView: View {

    private let modelRegistry: ModelRegistry
    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(\.manifoldTheme) private var theme: ManifoldTheme

    @State private var modelToDelete: ModelInfo?
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage: String?

    init(modelRegistry: ModelRegistry) {
        self.modelRegistry = modelRegistry
    }

    var body: some View {
        List {
            storageOverviewSection
            downloadedModelsSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        // Populate the cached storage snapshot off-main on appear, not on every
        // body eval (#1787). Single-flight inside the view model.
        .task {
            managementViewModel.refreshDiscoveredModels()
        }
        // A finished download adds a file on disk; refresh the cached snapshot.
        .onChange(of: managementViewModel.completedDownloadCount) { _, _ in
            managementViewModel.forceRefreshDiscoveredModels()
        }
        .alert(
            "Delete Model",
            isPresented: $showDeleteConfirmation,
            presenting: modelToDelete
        ) { model in
            Button("Delete", role: .destructive) {
                deleteModel(model)
            }
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
        } message: { model in
            Text("Are you sure you want to delete \"\(model.name)\"? This will free \(model.fileSizeFormatted) of storage. This action cannot be undone.")
        }
        .alert(
            "Delete Failed",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private var storageOverviewSection: some View {
        Section("Storage Overview") {
            HStack {
                Label("Total Used", systemImage: "externaldrive.fill")
                Spacer()
                // Show a placeholder during the first scan rather than a false
                // "0 KB" before the cache is populated (#1787).
                if managementViewModel.isRefreshingModels && !managementViewModel.hasLoadedModelsOnce {
                    Text("Calculating…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(managementViewModel.totalStorageUsed)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Models Directory")
                    .font(.subheadline)

                #if os(macOS)
                Button {
                    openModelsDirectoryInFinder()
                } label: {
                    Text(managementViewModel.modelsDirectoryPath)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open models directory in Finder")
                #else
                Text(managementViewModel.modelsDirectoryPath)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                #endif
            }
        }
    }

    private var downloadedModelsSection: some View {
        Section("Downloaded Models") {
            let models = modelRegistry.availableModels.filter { $0.modelType != .foundation }

            if models.isEmpty {
                Text("No downloaded models.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .font(.body)
                                .lineLimit(2)

                            HStack(spacing: 6) {
                                Text(model.backendLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.fileSizeFormatted)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button {
                            modelToDelete = model
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(theme.statusError)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(model.name)")
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.name), \(model.backendLabel), \(model.fileSizeFormatted)")
                }
            }
        }
    }

    private func deleteModel(_ model: ModelInfo) {
        do {
            try managementViewModel.deleteModel(model)
            // Off-main rescan so a post-delete refresh never re-blocks the main
            // thread (#1774); `Task {}` inherits @MainActor, the scan hops off
            // inside `refreshAsync()`.
            Task {
                do {
                    try await modelRegistry.refreshAsync()
                } catch {
                    Log.download.warning("LocalModelStorageView: registry refresh after delete failed: \(error)")
                }
            }
        } catch {
            Log.download.error("Failed to delete model: \(error)")
            deleteErrorMessage = error.localizedDescription
        }
        modelToDelete = nil
    }

    #if os(macOS)
    private func openModelsDirectoryInFinder() {
        let url = URL(fileURLWithPath: managementViewModel.modelsDirectoryPath)
        NSWorkspace.shared.open(url)
    }
    #endif
}
