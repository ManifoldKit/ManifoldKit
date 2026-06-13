import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Picker and management UI for sampler presets within `GenerationSettingsView`.
///
/// Reads and writes presets through a `SamplerPresetStore` injected via the
/// SwiftUI environment (typically from `ManifoldBootstrap.samplerPresetStore`).
/// The view does not import SwiftData — the store is the only persistence
/// surface visible to the UI.
public struct SamplerPresetPickerView: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.samplerPresetStore) private var presetStore

    @State private var presets: [SamplerPresetRecord] = []
    @State private var showSaveAlert = false
    @State private var newPresetName = ""
    @State private var showDeleteConfirmation = false
    @State private var presetToDelete: SamplerPresetRecord?

    public init() {}

    public var body: some View {
        Section("Sampler Presets") {
            if !presets.isEmpty {
                ForEach(presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.body)
                            Text("T:\(String(format: "%.1f", preset.temperature)) P:\(String(format: "%.2f", preset.topP)) R:\(String(format: "%.2f", preset.repeatPenalty))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Apply") {
                            applyPreset(preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Apply \(preset.name)")
                        .accessibilityHint("Sets temperature, top P, and repeat penalty from this preset")
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            presetToDelete = preset
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                newPresetName = ""
                showSaveAlert = true
            } label: {
                Label("Save Current as Preset", systemImage: "plus.circle")
            }
        }
        .task { await refresh() }
        .alert("Save Preset", isPresented: $showSaveAlert) {
            TextField("Preset name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await saveCurrentAsPreset() }
            }
            .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a name for this sampler preset.")
        }
        .alert("Delete Preset", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { presetToDelete = nil }
            Button("Delete", role: .destructive) {
                if let preset = presetToDelete {
                    Task { await deletePreset(preset) }
                }
                presetToDelete = nil
            }
        } message: {
            if let preset = presetToDelete {
                Text("Delete \"\(preset.name)\"?")
            }
        }
    }

    // MARK: - Actions

    private func applyPreset(_ preset: SamplerPresetRecord) {
        viewModel.temperature = preset.temperature
        viewModel.topP = preset.topP
        viewModel.repeatPenalty = preset.repeatPenalty
    }

    private func refresh() async {
        guard let presetStore else { return }
        do {
            presets = try await presetStore.fetchPresets()
        } catch {
            Log.persistence.error("Failed to fetch sampler presets: \(error)")
        }
    }

    private func saveCurrentAsPreset() async {
        guard let presetStore else { return }
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let record = SamplerPresetRecord(
            name: name,
            temperature: viewModel.temperature,
            topP: viewModel.topP,
            repeatPenalty: viewModel.repeatPenalty
        )
        do {
            try await presetStore.insertPreset(record)
            await refresh()
        } catch {
            Log.persistence.error("Failed to save preset: \(error)")
        }
    }

    private func deletePreset(_ preset: SamplerPresetRecord) async {
        guard let presetStore else { return }
        do {
            try await presetStore.deletePreset(preset.id)
            await refresh()
        } catch {
            Log.persistence.error("Failed to delete preset: \(error)")
        }
    }
}

// MARK: - Environment plumbing

private struct SamplerPresetStoreKey: EnvironmentKey {
    static let defaultValue: (any SamplerPresetStore)? = nil
}

extension EnvironmentValues {
    /// Injection point for the `SamplerPresetStore` consumed by
    /// ``SamplerPresetPickerView``.
    public var samplerPresetStore: (any SamplerPresetStore)? {
        get { self[SamplerPresetStoreKey.self] }
        set { self[SamplerPresetStoreKey.self] = newValue }
    }
}
