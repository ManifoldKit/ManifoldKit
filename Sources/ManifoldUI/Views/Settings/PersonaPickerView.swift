import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Picker and management UI for the persona/prompt library within
/// `GenerationSettingsView`.
///
/// Reads and writes personas through a `PersonaStore` injected via the
/// SwiftUI environment (typically from `ManifoldBootstrap.personaStore`).
/// The view does not import SwiftData — the store is the only persistence
/// surface visible to the UI.
public struct PersonaPickerView: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.personaStore) private var personaStore

    @State private var personas: [PersonaRecord] = []
    @State private var showSaveAlert = false
    @State private var newPersonaName = ""
    @State private var showDeleteConfirmation = false
    @State private var personaToDelete: PersonaRecord?

    public init() {}

    public var body: some View {
        Section("Personas") {
            if !personas.isEmpty {
                ForEach(personas) { persona in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(persona.name)
                                .font(.body)
                            Text(persona.systemPrompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Apply") {
                            applyPersona(persona)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Apply \(persona.name)")
                        .accessibilityHint("Sets the system prompt from this persona")
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            personaToDelete = persona
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                newPersonaName = ""
                showSaveAlert = true
            } label: {
                Label("Save Current as Persona", systemImage: "plus.circle")
            }
        }
        .task { await refresh() }
        .alert("Save Persona", isPresented: $showSaveAlert) {
            TextField("Persona name", text: $newPersonaName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await saveCurrentAsPersona() }
            }
            .disabled(newPersonaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a name for this persona.")
        }
        .alert("Delete Persona", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { personaToDelete = nil }
            Button("Delete", role: .destructive) {
                if let persona = personaToDelete {
                    Task { await deletePersona(persona) }
                }
                personaToDelete = nil
            }
        } message: {
            if let persona = personaToDelete {
                Text("Delete \"\(persona.name)\"?")
            }
        }
    }

    // MARK: - Actions

    private func applyPersona(_ persona: PersonaRecord) {
        viewModel.systemPrompt = persona.systemPrompt
    }

    private func refresh() async {
        guard let personaStore else { return }
        do {
            personas = try await personaStore.fetchPersonas()
        } catch {
            Log.persistence.error("Failed to fetch personas: \(error)")
        }
    }

    private func saveCurrentAsPersona() async {
        guard let personaStore else { return }
        let name = newPersonaName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let record = PersonaRecord(
            name: name,
            systemPrompt: viewModel.systemPrompt
        )
        do {
            try await personaStore.insertPersona(record)
            await refresh()
        } catch {
            Log.persistence.error("Failed to save persona: \(error)")
        }
    }

    private func deletePersona(_ persona: PersonaRecord) async {
        guard let personaStore else { return }
        do {
            try await personaStore.deletePersona(persona.id)
            await refresh()
        } catch {
            Log.persistence.error("Failed to delete persona: \(error)")
        }
    }
}

// MARK: - Environment plumbing

private struct PersonaStoreKey: EnvironmentKey {
    static let defaultValue: (any PersonaStore)? = nil
}

extension EnvironmentValues {
    /// Injection point for the `PersonaStore` consumed by
    /// ``PersonaPickerView``.
    public var personaStore: (any PersonaStore)? {
        get { self[PersonaStoreKey.self] }
        set { self[PersonaStoreKey.self] = newValue }
    }
}
