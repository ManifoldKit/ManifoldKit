import SwiftUI
import BaseChatRuntime
import BaseChatInference
import BaseChatUI

/// Storage management sheet for viewing and deleting downloaded models.
///
/// Shows total storage used, the models directory path, and a list of
/// downloaded models with their sizes and delete buttons.
public struct StorageManagementView: View {

    @Environment(ChatViewModel.self) private var chatViewModel
    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var modelToDelete: ModelInfo?
    @State private var showDeleteConfirmation = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                storageOverviewSection
                downloadedModelsSection
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
                    deleteModel(model)
                }
                Button("Cancel", role: .cancel) {
                    modelToDelete = nil
                }
            } message: { model in
                Text("Are you sure you want to delete \"\(model.name)\"? This will free \(model.fileSizeFormatted) of storage. This action cannot be undone.")
            }
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

    private var downloadedModelsSection: some View {
        Section("Downloaded Models") {
            let models = chatViewModel.availableModels.filter { $0.modelType != .foundation }

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

    private func deleteModel(_ model: ModelInfo) {
        do {
            try managementViewModel.deleteModel(model)
            chatViewModel.refreshModels()
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
    StorageManagementView()
        .environment(ChatViewModel())
        .environment(ModelManagementViewModel())
}
