import SwiftUI
import BaseChatInference

#if canImport(BaseChatMCP)
import BaseChatMCP
import Observation

struct ConnectedServicesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: DemoMCPCoordinator
    @State private var pendingConnect: MCPServerDescriptor?

    init(
        toolRegistry: ToolRegistry,
        isFoundationModelsActive: @escaping () -> Bool = { false }
    ) {
        _coordinator = State(initialValue: DemoMCPCoordinator(
            toolRegistry: toolRegistry,
            isFoundationModelsActive: isFoundationModelsActive
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.catalog.isEmpty {
                    ContentUnavailableView {
                        Label("No services configured", systemImage: "link.badge.plus")
                    } description: {
                        Text(coordinator.catalogHelpText)
                    }
                    .accessibilityIdentifier("connected-services-catalog-empty-message")
                } else {
                    List {
                        Section("Connected Services") {
                            ForEach(coordinator.catalog, id: \.id) { descriptor in
                                serviceRow(for: descriptor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Connected Services")
            .accessibilityIdentifier("connected-services-sheet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                coordinator.startListenersIfNeeded()
            }
            .confirmationDialog(
                "Connect service",
                isPresented: Binding(
                    get: { pendingConnect != nil },
                    set: { if !$0 { pendingConnect = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let descriptor = pendingConnect {
                    Button("Connect") {
                        coordinator.connect(descriptor)
                        pendingConnect = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingConnect = nil
                }
            } message: {
                if let descriptor = pendingConnect {
                    Text(disclosureMessage(for: descriptor))
                }
            }
        }
    }

    @ViewBuilder
    private func serviceRow(for descriptor: MCPServerDescriptor) -> some View {
        let snapshot = coordinator.snapshot(for: descriptor.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.displayName)
                        .font(.headline)
                    Text(snapshot.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("connected-service-status-\(descriptor.id.uuidString)")
                }

                Spacer()

                if snapshot.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                if snapshot.isConnected {
                    Button("Disconnect", role: .destructive) {
                        coordinator.disconnect(descriptor.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(snapshot.isBusy)
                    .accessibilityIdentifier("connected-service-disconnect-\(descriptor.id.uuidString)")
                } else {
                    Button("Connect") {
                        pendingConnect = descriptor
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(snapshot.isBusy)
                    .accessibilityIdentifier("connected-service-connect-\(descriptor.id.uuidString)")
                }
            }

            if let auth = snapshot.authorizationRequest {
                Label("Authorization required", systemImage: "person.badge.key")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if auth.requiredScopes.isEmpty == false {
                    Text("Scopes: \(auth.requiredScopes.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = snapshot.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if snapshot.foundationModelsCapActive,
               snapshot.isConnected,
               snapshot.enabledToolCount < snapshot.toolCount {
                Label(
                    "Apple Intelligence supports up to \(MCPToolFilter.foundationModelsToolCap) tools with simple schemas — extras are hidden until you switch to a different backend.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("connected-service-cap-footnote-\(descriptor.id.uuidString)")
            }

            DisclosureGroup("Data use") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(descriptor.dataDisclosure)
                        .font(.caption)
                    Text("Approval policy: \(approvalLabel(descriptor.approvalPolicy))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("connected-service-row-\(descriptor.id.uuidString)")
    }

    private func approvalLabel(_ policy: MCPApprovalPolicy) -> String {
        switch policy {
        case .perCall: return "Per call"
        case .perTurn: return "Per turn"
        case .sessionForTool: return "Session per tool"
        case .sessionForServer: return "Session per server"
        case .persistentForTool: return "Persistent per tool"
        }
    }

    private func disclosureMessage(for descriptor: MCPServerDescriptor) -> String {
        let scopes: String = {
            guard case .oauth(let oauth) = descriptor.authorization else { return "" }
            guard oauth.scopes.isEmpty == false else { return "" }
            return "\n\nRequested scopes: \(oauth.scopes.joined(separator: ", "))."
        }()
        return "\(descriptor.dataDisclosure)\(scopes)"
    }
}

struct ConnectedServiceSnapshot {
    var state: MCPConnectionState = .idle
    var isConnected = false
    var isBusy = false
    /// Total number of MCP tools registered for this server after the source's
    /// own filter (allowList/denyList/maxToolCount) has been applied.
    var toolCount = 0
    /// Number of tools currently surfaced to the active backend. When the
    /// Foundation Models cap (D18 + D21) is biting, this drops below
    /// ``toolCount`` and the UI shows "X of Y enabled" so users can see
    /// the cap in action.
    var enabledToolCount = 0
    /// Mirror of `DemoMCPCoordinator.isFoundationModelsActive()` captured at
    /// the most recent refresh. The view uses this to decide whether to
    /// surface the cap explanation footnote.
    var foundationModelsCapActive = false
    var errorMessage: String?
    var authorizationRequest: MCPAuthorizationRequest?

    var statusText: String {
        let stateText: String = {
            switch state {
            case .idle: return "Idle"
            case .connecting: return "Connecting"
            case .ready: return "Connected"
            case .reconnecting: return "Reconnecting"
            case .failed: return "Failed"
            }
        }()
        if isConnected {
            return "\(stateText) · \(enabledToolCount) of \(toolCount) tools enabled"
        }
        return stateText
    }
}

#else

struct ConnectedServicesView: View {
    @Environment(\.dismiss) private var dismiss

    let toolRegistry: ToolRegistry

    init(
        toolRegistry: ToolRegistry,
        isFoundationModelsActive: @escaping () -> Bool = { false }
    ) {
        self.toolRegistry = toolRegistry
        // Probe is captured but unused — there's no MCP surface to filter when
        // BaseChatMCP isn't linked. Keeps call sites symmetrical.
        _ = isFoundationModelsActive
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Connected Services") {
                    Label("BaseChatMCP is not linked in this build.", systemImage: "link.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connected Services")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#endif
