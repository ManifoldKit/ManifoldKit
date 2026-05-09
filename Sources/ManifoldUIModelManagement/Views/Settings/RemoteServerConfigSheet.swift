#if Ollama || CloudSaaS
import SwiftUI
import ManifoldRuntime
import ManifoldInference

/// Sheet for manually configuring a remote inference server connection.
///
/// Lets users enter a server URL, optional API key, and backend type for a
/// remote inference endpoint. Persists through the ``EndpointStore`` injected
/// via the SwiftUI environment; the view does not import SwiftData.
///
/// ## Usage
///
/// ```swift
/// .sheet(isPresented: $showRemoteConfig) {
///     RemoteServerConfigSheet { record in
///         // use record
///     }
///     .environment(\.endpointStore, runtime.endpointStore)
/// }
/// ```
public struct RemoteServerConfigSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.endpointStore) private var endpointStore

    /// Called when the user saves the configuration, passing the created record.
    public var onSave: ((APIEndpointRecord) -> Void)?

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var backendType: BackendType = .openAICompatible
    @State private var errorMessage: String?

    public init(onSave: ((APIEndpointRecord) -> Void)? = nil) {
        self.onSave = onSave
    }

    enum BackendType: String, CaseIterable, Identifiable {
        case openAICompatible = "OpenAI-compatible"
        case ollama = "Ollama"

        var id: String { rawValue }

        var defaultPort: String {
            switch self {
            case .openAICompatible: return "8080"
            case .ollama: return "11434"
            }
        }

        var apiProvider: APIProvider {
            switch self {
            case .openAICompatible: return .custom
            case .ollama: return .ollama
            }
        }

    }

    public var body: some View {
        NavigationStack {
            Form {
                backendTypeSection
                connectionSection
                modelSection
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Remote Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Sections

    private var backendTypeSection: some View {
        Section("Backend Type") {
            Picker("Type", selection: $backendType) {
                ForEach(BackendType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: backendType) { _, newType in
                // Pre-fill default URL when type changes.
                if serverURL.isEmpty {
                    serverURL = "http://localhost:\(newType.defaultPort)"
                }
            }
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("Server URL", text: $serverURL, prompt: Text("http://localhost:\(backendType.defaultPort)"))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()

            SecureField("API Key (optional)", text: $apiKey)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Connection")
        } footer: {
            Text("API key is only needed for authenticated endpoints (e.g. vLLM with auth). Leave blank for local Ollama servers.")
                .font(.caption)
        }
    }

    private var modelSection: some View {
        Section {
            TextField("Model name", text: $modelName, prompt: Text(backendType.apiProvider.defaultModelName))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Model")
        } footer: {
            Text("For Ollama: use the tag shown by `ollama list` (e.g. `llama3.2:8b`).")
                .font(.caption)
        }
    }

    // MARK: - Validation & Save

    private var isValid: Bool {
        let resolvedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? backendType.apiProvider.defaultModelName
        if case .success = APIEndpointDraftValidator.validate(
            provider: backendType.apiProvider,
            baseURL: serverURL,
            modelName: resolvedModel
        ) {
            return true
        }
        return false
    }

    private func save() async {
        guard let endpointStore else {
            errorMessage = "Endpoint store is not configured."
            return
        }

        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? backendType.apiProvider.defaultModelName

        switch APIEndpointDraftValidator.validate(
            provider: backendType.apiProvider,
            baseURL: trimmedURL,
            modelName: resolvedModel
        ) {
        case .failure(let reason):
            errorMessage = reason.errorDescription
            return
        case .success:
            break
        }

        let record = APIEndpointRecord(
            name: "\(backendType.rawValue) — \(resolvedModel)",
            provider: backendType.apiProvider,
            baseURL: trimmedURL,
            modelName: resolvedModel
        )

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            do {
                try KeychainService.store(key: trimmedKey, account: record.keychainAccount)
            } catch {
                // `KeychainError.localizedDescription` already reads as a
                // complete sentence — don't prepend another "Could not save…"
                // prefix and double the wording.
                errorMessage = error.localizedDescription
                return
            }
        }

        do {
            try await endpointStore.insertEndpoint(record)
            onSave?(record)
            dismiss()
        } catch {
            // Best-effort Keychain cleanup if the row insert fails.
            if !trimmedKey.isEmpty {
                try? KeychainService.delete(account: record.keychainAccount)
            }
            errorMessage = error.localizedDescription.isEmpty
                ? "Failed to save the server configuration."
                : error.localizedDescription
        }
    }
}

// MARK: - Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#Preview("Remote Server Config") {
    RemoteServerConfigSheet()
}
#endif
