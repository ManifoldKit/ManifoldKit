import SwiftUI
#if Ollama || CloudSaaS
import ManifoldRuntime
import ManifoldInference
#endif

/// Main settings view for managing cloud API endpoints.
///
/// Presented as a sheet from `GenerationSettingsView`. Lists all configured
/// endpoints with swipe-to-delete, and offers an "Add Endpoint" button that
/// presents `APIEndpointEditorView`.
///
/// Endpoint reads and writes go through the ``EndpointStore`` injected via
/// the SwiftUI environment (typically `ManifoldBootstrap.endpointStore`); the
/// view itself does not import SwiftData.
///
/// The type itself is **always public** — even when neither `Ollama` nor
/// `CloudSaaS` traits are enabled — so that consumer migration code like
/// `apiConfiguration: { APIConfigurationView() }` compiles for chat-only
/// apps that don't pull in cloud backends. With the traits off the body
/// renders an `EmptyView`, so the unused sheet content has zero visual
/// footprint. This mirrors the `BackendRegistrar` idiom in `ManifoldBackends`.
public struct APIConfigurationView: View {

    #if Ollama || CloudSaaS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.endpointStore) private var endpointStore

    @State private var endpoints: [APIEndpointRecord] = []
    @State private var showAddSheet = false
    @State private var endpointToEdit: APIEndpointRecord?
    @State private var showDeleteConfirmation = false
    @State private var endpointToDelete: APIEndpointRecord?
    #endif

    public init() {}

    public var body: some View {
        #if Ollama || CloudSaaS
        NavigationStack {
            Form {
                Section("Endpoints") {
                    if endpoints.isEmpty {
                        Text("No cloud APIs configured.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(endpoints) { endpoint in
                        APIEndpointRow(endpoint: endpoint)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                endpointToEdit = endpoint
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    endpointToDelete = endpoint
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }

                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Endpoint", systemImage: "plus.circle")
                    }
                }

                Section {
                    Label {
                        Text("When using cloud APIs, your messages are sent to external servers. Your conversations are no longer on-device only.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.yellow)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Privacy warning: When using cloud APIs, your messages are sent to external servers. Your conversations are no longer on-device only.")
                }
            }
            .navigationTitle("Cloud APIs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refresh() }
            .sheet(isPresented: $showAddSheet, onDismiss: { Task { await refresh() } }) {
                APIEndpointEditorView(endpoint: nil)
            }
            .sheet(item: $endpointToEdit, onDismiss: { Task { await refresh() } }) { endpoint in
                APIEndpointEditorView(endpoint: endpoint)
            }
            .alert("Delete Endpoint", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { endpointToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let endpoint = endpointToDelete {
                        Task { await deleteEndpoint(endpoint) }
                    }
                    endpointToDelete = nil
                }
            } message: {
                if let endpoint = endpointToDelete {
                    Text("Delete \"\(endpoint.name)\"? The API key will also be removed.")
                }
            }
        }
        #else
        // Cloud APIs are not available in this build configuration. Keeping
        // the type public-but-empty lets host apps wire `apiConfiguration:`
        // unconditionally without a per-trait `#if` at the call site.
        EmptyView()
        #endif
    }

    #if Ollama || CloudSaaS
    private func refresh() async {
        guard let endpointStore else { return }
        do {
            endpoints = try await endpointStore.fetchEndpoints()
        } catch {
            Log.persistence.error("Failed to fetch endpoints: \(error)")
        }
    }

    private func deleteEndpoint(_ endpoint: APIEndpointRecord) async {
        guard let endpointStore else { return }

        // Best-effort Keychain cleanup: if the Keychain delete fails we still
        // remove the endpoint row, because leaving the endpoint in the UI with
        // a dangling key is worse than a potential orphaned Keychain item.
        // The failure is logged by KeychainService for diagnostics.
        do {
            try KeychainService.delete(account: endpoint.keychainAccount)
        } catch {
            Log.persistence.warning("Failed to delete API key from Keychain: \(error.localizedDescription)")
        }

        do {
            try await endpointStore.deleteEndpoint(endpoint.id)
            await refresh()
        } catch {
            Log.persistence.error("Failed to delete endpoint: \(error)")
        }
    }
    #endif
}

// MARK: - Preview

#if Ollama || CloudSaaS
#Preview("API Configuration") {
    APIConfigurationView()
}
#endif
