import SwiftUI
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

/// Storage management sheet for viewing and deleting downloaded models.
///
/// Shows total storage used, the models directory path, and a list of
/// downloaded models with their sizes and delete buttons.
public struct StorageManagementView: View {

    /// The registry the host constructed, passed in explicitly. The
    /// environment-reading initializer that used to be the alternative was
    /// removed — see docs/MIGRATION-deprecation-shims-deleted.md.
    private let modelRegistry: ModelRegistry

    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.manifoldTheme) private var theme: ManifoldTheme

    @State private var modelToDelete: ModelInfo?
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage: String?

    /// Canonical init — pass the registry the host already constructed
    /// (typically `chatViewModel.modelRegistry`).
    public init(modelRegistry: ModelRegistry) {
        self.modelRegistry = modelRegistry
    }

    public var body: some View {
        content(modelRegistry: modelRegistry)
    }

    @ViewBuilder
    private func content(modelRegistry: ModelRegistry) -> some View {
        NavigationStack {
            List {
                storageOverviewSection
                downloadedModelsSection(modelRegistry: modelRegistry)
            }
            .navigationTitle("Storage")
            // Populate the cached storage snapshot off-main on appear, not on every
            // body eval (#1787). Single-flight inside the view model.
            .task {
                managementViewModel.refreshDiscoveredModels()
            }
            // A finished download adds a file on disk; refresh the cached snapshot
            // so totalStorageUsed updates without an app restart.
            .onChange(of: managementViewModel.completedDownloadCount) { _, _ in
                managementViewModel.forceRefreshDiscoveredModels()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Delete Model",
                isPresented: $showDeleteConfirmation,
                presenting: modelToDelete
            ) { model in
                Button("Delete", role: .destructive) {
                    deleteModel(model, modelRegistry: modelRegistry)
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
    }

    // MARK: - Storage Overview

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

    // MARK: - Downloaded Models List

    @ViewBuilder
    private func downloadedModelsSection(modelRegistry: ModelRegistry) -> some View {
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

    // MARK: - Actions

    private func deleteModel(_ model: ModelInfo, modelRegistry: ModelRegistry) {
        do {
            try managementViewModel.deleteModel(model)
            // Off-main rescan so a post-delete refresh never re-blocks the main
            // thread (#1774); `Task {}` inherits @MainActor, the scan hops off
            // inside `refreshAsync()`.
            Task {
                do {
                    try await modelRegistry.refreshAsync()
                } catch {
                    Log.download.warning("StorageManagementView: registry refresh after delete failed: \(error)")
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

// MARK: - Preview

#Preview {
    let chatVM = ChatViewModel()
    StorageManagementView(modelRegistry: chatVM.modelRegistry)
        .environment(ModelManagementViewModel())
}
