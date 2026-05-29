import SwiftUI
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

/// Storage management sheet for viewing and deleting downloaded models.
///
/// Shows total storage used, the models directory path, and a list of
/// downloaded models with their sizes and delete buttons.
public struct StorageManagementView: View {

    /// Resolved registry. The canonical init takes one explicitly; the
    /// deprecated init reads it from `ChatViewModel` via the environment.
    private let registrySource: RegistrySource

    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var modelToDelete: ModelInfo?
    @State private var showDeleteConfirmation = false

    /// Canonical init — pass the registry the host already constructed
    /// (typically `chatViewModel.modelRegistry`).
    public init(modelRegistry: ModelRegistry) {
        self.registrySource = .explicit(modelRegistry)
    }

    /// Deprecated environment-based init. Reads ``ChatViewModel`` from the
    /// SwiftUI environment and forwards to the registry-driven path.
    /// Pass `modelRegistry` explicitly instead.
    @available(*, deprecated, message: "Use StorageManagementView(modelRegistry:) and pass chatViewModel.modelRegistry explicitly.")
    public init() {
        self.registrySource = .environment
    }

    private enum RegistrySource {
        case explicit(ModelRegistry)
        case environment
    }

    public var body: some View {
        switch registrySource {
        case .explicit(let registry):
            content(modelRegistry: registry)
        case .environment:
            EnvironmentBridge { registry in
                content(modelRegistry: registry)
            }
        }
    }

    @ViewBuilder
    private func content(modelRegistry: ModelRegistry) -> some View {
        NavigationStack {
            List {
                storageOverviewSection
                downloadedModelsSection(modelRegistry: modelRegistry)
            }
            .navigationTitle("Storage")
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
        }
    }

    /// Internal helper that pulls ``ChatViewModel`` from the environment so
    /// the deprecated `init()` overload can keep working without violating
    /// `@Environment` lookup rules (which require a `View` body site).
    private struct EnvironmentBridge<Content: View>: View {
        @Environment(ChatViewModel.self) private var chatViewModel
        let content: (ModelRegistry) -> Content

        var body: some View {
            content(chatViewModel.modelRegistry)
        }
    }

    // MARK: - Storage Overview

    private var storageOverviewSection: some View {
        Section("Storage Overview") {
            HStack {
                Label("Total Used", systemImage: "externaldrive.fill")
                Spacer()
                Text(managementViewModel.totalStorageUsed)
                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(.red)
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
            do {
                try modelRegistry.refresh()
            } catch {
                Log.download.warning("StorageManagementView: registry refresh after delete failed: \(error)")
            }
        } catch {
            Log.download.error("Failed to delete model: \(error)")
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
