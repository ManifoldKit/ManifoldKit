import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Editor for creating or editing an ``APIEndpointRecord``.
///
/// When `endpoint` is `nil`, creates a new endpoint on save.
/// When editing, populates fields from the existing endpoint.
/// Provider selection dynamically updates the base URL and model defaults.
///
/// Reads and writes go through the ``EndpointStore`` injected via the SwiftUI
/// environment. The view does not import SwiftData.
public struct APIEndpointEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.endpointStore) private var endpointStore

    public let endpoint: APIEndpointRecord? // nil = creating new

    @State private var name: String = ""
    @State private var provider: APIProvider = .openAI
    @State private var baseURL: String = ""
    @State private var modelName: String = ""
    @State private var apiKey: String = ""
    @State private var validationError: String?

    private var isEditing: Bool { endpoint != nil }

    public init(endpoint: APIEndpointRecord?) {
        self.endpoint = endpoint
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $provider) {
                        ForEach(APIProvider.availableInBuild) { p in
                            Text(p.displayName).tag(p)
                        }
                    }

                    TextField("Display Name", text: $name)
                }

                Section("Connection") {
                    TextField("Server URL", text: $baseURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif

                    TextField("Model Name", text: $modelName)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                if provider.requiresAPIKey {
                    Section("Authentication") {
                        SecureField("API Key", text: $apiKey)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        if isEditing, let account = endpoint?.keychainAccount,
                           let existing = KeychainService.retrieve(account: account), !existing.isEmpty {
                            Text("Current key: \(KeychainService.masked(existing))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !provider.requiresAPIKey {
                    Section {
                        Label {
                            Text("This provider runs locally and doesn't require an API key.")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "network")
                                .foregroundStyle(.green)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                if let error = validationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Endpoint" : "Add Endpoint")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .onAppear { populateFields() }
            .onChange(of: provider) { _, newProvider in
                if !isEditing {
                    baseURL = newProvider.defaultBaseURL
                    modelName = newProvider.defaultModelName
                    if name.isEmpty || APIProvider.availableInBuild.map(\.displayName).contains(name) {
                        name = newProvider.displayName
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func populateFields() {
        if let endpoint {
            name = endpoint.name
            provider = endpoint.provider
            baseURL = endpoint.baseURL
            modelName = endpoint.modelName
            // Don't populate apiKey — user must re-enter or leave blank to keep existing
        } else {
            name = provider.displayName
            baseURL = provider.defaultBaseURL
            modelName = provider.defaultModelName
        }
    }

    private func save() async {
        guard let endpointStore else {
            validationError = "Endpoint store is not configured."
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModelName = trimmedModelName.isEmpty ? provider.defaultModelName : trimmedModelName

        switch APIEndpointDraftValidator.validate(
            provider: provider,
            baseURL: trimmedURL,
            modelName: resolvedModelName
        ) {
        case .failure(let reason):
            validationError = reason.errorDescription
            return
        case .success:
            break
        }

        validationError = nil

        if let endpoint {
            // Update existing record
            var updated = endpoint
            updated.name = trimmedName
            updated.provider = provider
            updated.baseURL = trimmedURL.isEmpty ? provider.defaultBaseURL : trimmedURL
            updated.modelName = resolvedModelName

            // Capture the prior key before overwriting so a failed record
            // update can be rolled back to it (rather than leaving the freshly
            // written key orphaned).
            var didWriteKey = false
            let priorKey: String? = apiKey.isEmpty
                ? nil
                : KeychainService.retrieve(account: updated.keychainAccount)
            if !apiKey.isEmpty {
                do {
                    try KeychainService.store(key: apiKey, account: updated.keychainAccount)
                    didWriteKey = true
                } catch {
                    // `KeychainError.localizedDescription` already reads as a
                    // complete sentence (e.g. "Couldn't store the API key in
                    // the Keychain: The device appears to be locked…").
                    validationError = error.localizedDescription
                    return
                }
            }

            do {
                try await endpointStore.updateEndpoint(updated)
                dismiss()
            } catch {
                // Roll back the just-written key so a failed record update never
                // leaves an orphaned Keychain item (mirrors the create path).
                if didWriteKey {
                    Self.rollbackKeychainKey(
                        account: updated.keychainAccount,
                        priorKey: priorKey
                    )
                }
                validationError = error.localizedDescription.isEmpty
                    ? "Failed to save the endpoint configuration."
                    : error.localizedDescription
            }
        } else {
            // Create a new record
            let newRecord = APIEndpointRecord(
                name: trimmedName,
                provider: provider,
                baseURL: trimmedURL.isEmpty ? nil : trimmedURL,
                modelName: resolvedModelName
            )

            if !apiKey.isEmpty {
                do {
                    try KeychainService.store(key: apiKey, account: newRecord.keychainAccount)
                } catch {
                    validationError = error.localizedDescription
                    return
                }
            }

            do {
                try await endpointStore.insertEndpoint(newRecord)
                dismiss()
            } catch {
                // Best-effort cleanup of the just-stored Keychain item if the
                // row insert fails — leaves no orphan.
                do {
                    try KeychainService.delete(account: newRecord.keychainAccount)
                } catch {
                    Log.security.warning("Keychain cleanup failed after endpoint save error: \(error.localizedDescription, privacy: .public)")
                }
                validationError = error.localizedDescription.isEmpty
                    ? "Failed to save the endpoint configuration."
                    : error.localizedDescription
            }
        }
    }

    /// Restores the Keychain key for `account` after a failed record update on the
    /// edit path: re-stores `priorKey` if there was one, otherwise deletes the
    /// freshly written (now-orphaned) key. Best-effort — a Keychain failure here
    /// is logged, not surfaced, since the user is already seeing the save error.
    ///
    /// Extracted from `save()` so the rollback contract is unit-testable without
    /// hosting the SwiftUI view.
    static func rollbackKeychainKey(account: String, priorKey: String?) {
        do {
            if let priorKey, !priorKey.isEmpty {
                try KeychainService.store(key: priorKey, account: account)
            } else {
                try KeychainService.delete(account: account)
            }
        } catch {
            Log.security.warning("Keychain rollback failed after endpoint update error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Preview

#Preview("Add Endpoint") {
    APIEndpointEditorView(endpoint: nil)
}
