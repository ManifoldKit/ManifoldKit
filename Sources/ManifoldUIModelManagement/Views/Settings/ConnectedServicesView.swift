import SwiftUI
import ManifoldInference
import ManifoldUI
import ManifoldMCP
import Observation

/// Connected Services (MCP) settings surface (`docs/UI-REFRESH-2026.md` §6B,
/// **experimental** — decided in scope 2026-07-17).
///
/// Promoted from the demo app's `ConnectedServicesView`
/// (`Example/Advanced/MCP/DemoMCPCoordinator.swift`) into the package,
/// re-themed onto ``ManifoldTheme`` tokens. Rules this view enforces:
///
/// - Connection state uses the status tier (connected/reauth/off =
///   OK/warn/neutral).
/// - A plain-language consent card explains data flow **before** the first
///   tool exposure — the confirmation dialog below is that gate; a server's
///   tools are never registered into `toolRegistry` until the user accepts
///   it (`MCPDataDisclosureConsentStore.accept(serverID:)` runs before
///   ``connect(_:)``).
/// - Connecting a server never implies approving its tool calls — per-call
///   approval stays in the tool card (``ToolInvocationView``); this view
///   only ever registers tool *availability*, never auto-approves a call.
/// - Tool counts and the Foundation Models 16-tool cap render via
///   ``MCPToolCountView`` (the new `ManifoldMCP` package edge this tranche
///   adds — see the `Package.swift` diff and the PR body's flagged review
///   item).
///
/// ## Reauthentication
///
/// A server whose session needs re-authorization (`snapshot.authorizationRequest
/// != nil`) surfaces the same "Authorization required" affordance a failed
/// tool call's ``ToolErrorPresentation/ReauthenticationCTA`` (action ID
/// `"mcp.reauthenticate.<service>"`) describes in the transcript — tapping
/// "Connect" here re-runs the OAuth flow. Routing a tap on that in-transcript
/// CTA to *present this sheet* is a host-level action-dispatch wire-up
/// (`ChatViewModel`/app code own presenting sheets) that sits outside this
/// tranche's owned UI paths; this view is the destination that CTA should
/// land on.
///
/// **`public`, not `package`** — this is a whole settings *screen* a host
/// app presents itself (typically as a sheet from its own Settings surface),
/// the same shape as the already-public ``APIConfigurationView``. Unlike
/// this tranche's other new views (which became internal `ChatView` chrome
/// once wired), there is no in-package call site that presents this sheet —
/// a consumer app is the only possible caller, so `package` access would
/// make the type unusable by definition.
public struct ConnectedServicesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.manifoldTheme) private var theme
    @State private var coordinator: MCPConnectedServicesCoordinator
    @State private var pendingConnect: MCPServerDescriptor?
    private let disclosureConsentStore: MCPDataDisclosureConsentStore

    /// - Parameters:
    ///   - toolRegistry: Registry the connected servers' tools are registered
    ///     into/out of as servers connect/disconnect.
    ///   - catalog: Servers offered for connection. Defaults to
    ///     ``MCPCatalog/all`` (the built-in Notion/Linear/GitHub OAuth-gated
    ///     entries); hosts append their own descriptors (e.g. a local stdio
    ///     server) by passing a superset.
    ///   - isFoundationModelsActive: Probe used to decide whether the
    ///     Foundation Models tool cap is biting for the active backend.
    ///   - userDefaults: Backing store for per-server consent flags. Inject a
    ///     unique-per-test suite in tests (see `AGENTS.md` "Inject
    ///     `UserDefaults`").
    public init(
        toolRegistry: ToolRegistry,
        catalog: [MCPServerDescriptor] = MCPCatalog.all,
        isFoundationModelsActive: @escaping () -> Bool = { false },
        userDefaults: UserDefaults = .standard
    ) {
        _coordinator = State(initialValue: MCPConnectedServicesCoordinator(
            toolRegistry: toolRegistry,
            catalog: catalog,
            isFoundationModelsActive: isFoundationModelsActive
        ))
        self.disclosureConsentStore = MCPDataDisclosureConsentStore(userDefaults: userDefaults)
    }

    public var body: some View {
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
            // The plain-language consent card: shown before the server's
            // tools are ever registered (`connect(_:)` runs only from the
            // "Connect" button below, which is either this dialog's own
            // action or gated behind `hasAccepted(serverID:)`).
            .confirmationDialog(
                "Review data use",
                isPresented: Binding(
                    get: { pendingConnect != nil },
                    set: { if !$0 { pendingConnect = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let descriptor = pendingConnect {
                    Button("Connect") {
                        disclosureConsentStore.accept(serverID: descriptor.id)
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
                        .font(theme.type.body.weight(.semibold))
                    Text(snapshot.statusText)
                        .font(theme.type.caption)
                        .foregroundStyle(statusColor(for: snapshot))
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
                        if disclosureConsentStore.hasAccepted(serverID: descriptor.id) {
                            coordinator.connect(descriptor)
                        } else {
                            pendingConnect = descriptor
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(snapshot.isBusy)
                    .accessibilityIdentifier("connected-service-connect-\(descriptor.id.uuidString)")
                }
            }

            if let auth = snapshot.authorizationRequest {
                Label("Authorization required", systemImage: "person.badge.key")
                    .font(theme.type.caption)
                    .foregroundStyle(theme.statusWarnColor)
                if auth.requiredScopes.isEmpty == false {
                    Text("Scopes: \(auth.requiredScopes.joined(separator: ", "))")
                        .font(theme.type.caption2)
                        .foregroundStyle(theme.ink2)
                }
            }

            if let error = snapshot.errorMessage {
                Text(error)
                    .font(theme.type.caption2)
                    .foregroundStyle(theme.statusErrorColor)
                    .lineLimit(3)
            }

            if snapshot.isConnected {
                MCPToolCountView(
                    totalToolCount: snapshot.toolCount,
                    compatibleToolCount: snapshot.foundationModelsCapActive ? snapshot.enabledToolCount : nil
                )
            }

            DisclosureGroup("Data use") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(descriptor.dataDisclosure)
                        .font(theme.type.caption)
                    Text("Approval policy: \(approvalLabel(descriptor.approvalPolicy))")
                        .font(theme.type.caption2)
                        .foregroundStyle(theme.ink2)
                }
            }
            .font(theme.type.caption)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("connected-service-row-\(descriptor.id.uuidString)")
    }

    /// Status tier mapping (spec §6B): connected → OK, reauth needed → warn,
    /// off/idle → neutral ink.
    private func statusColor(for snapshot: ConnectedServiceSnapshot) -> AnyShapeStyle {
        if snapshot.isConnected { return AnyShapeStyle(theme.statusOKColor) }
        if snapshot.authorizationRequest != nil || snapshot.state == .failed { return AnyShapeStyle(theme.statusWarnColor) }
        return theme.ink2
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
        return "\(descriptor.dataDisclosure)\(scopes)\n\nYou will only see this disclosure the first time you connect this service."
    }
}

/// UI-only per-server consent flag store — gates registering a server's
/// tools into the shared `ToolRegistry` behind an explicit, remembered
/// "Connect" acceptance the first time each server is connected.
struct MCPDataDisclosureConsentStore {
    private let userDefaults: UserDefaults
    private let keyPrefix = "manifold.mcp.dataDisclosure.accepted."

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func hasAccepted(serverID: UUID) -> Bool {
        userDefaults.bool(forKey: key(for: serverID))
    }

    func accept(serverID: UUID) {
        userDefaults.set(true, forKey: key(for: serverID))
    }

    private func key(for serverID: UUID) -> String {
        keyPrefix + serverID.uuidString
    }
}

/// Per-server UI projection of `MCPConnectionState` + tool counts —
/// ``MCPConnectedServicesCoordinator`` maps raw `MCPConnectionEvent`s onto
/// this so the view never holds MCP transport types directly.
struct ConnectedServiceSnapshot {
    var state: MCPConnectionState = .idle
    var isConnected = false
    var isBusy = false
    /// Total number of MCP tools registered for this server after the
    /// source's own filter (allowList/denyList/maxToolCount) has been
    /// applied.
    var toolCount = 0
    /// Number of tools currently surfaced to the active backend. When the
    /// Foundation Models cap is biting, this drops below ``toolCount``.
    var enabledToolCount = 0
    /// Mirror of `MCPConnectedServicesCoordinator.isFoundationModelsActive()`
    /// captured at the most recent refresh.
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

/// Coordinator for ``ConnectedServicesView``. Owns the `MCPClient`, drives
/// connect/disconnect lifecycle, and projects raw `MCPConnectionEvent` /
/// `MCPConnectionState` into snapshots the view can observe without holding
/// any MCP transport types directly. Promoted from the demo app's
/// `DemoMCPCoordinator` (`Example/Advanced/MCP/DemoMCPCoordinator.swift`),
/// generalized to take its catalog from the caller instead of hardcoding a
/// demo server.
@MainActor
@Observable
final class MCPConnectedServicesCoordinator {
    private let toolRegistry: ToolRegistry
    private let client: MCPClient
    private var sourcesByID: [UUID: MCPToolSource] = [:]
    private var snapshotsByID: [UUID: ConnectedServiceSnapshot] = [:]
    private var eventsTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    let catalog: [MCPServerDescriptor]
    let catalogHelpText: String

    /// Probe used to decide whether the Foundation Models tool cap is
    /// biting. When `true`, each per-server snapshot's `enabledToolCount`
    /// reflects only the tools that pass
    /// ``MCPToolSource/foundationModelsEnabledNames(maxDepth:cap:)``. When
    /// `false`, `enabledToolCount` mirrors `toolCount`.
    var isFoundationModelsActive: () -> Bool

    init(
        toolRegistry: ToolRegistry,
        catalog: [MCPServerDescriptor],
        isFoundationModelsActive: @escaping () -> Bool = { false }
    ) {
        self.toolRegistry = toolRegistry
        self.client = MCPClient()
        self.isFoundationModelsActive = isFoundationModelsActive
        self.catalog = catalog
        self.catalogHelpText = catalog.isEmpty
            ? "No services configured."
            : "Tap Connect on a service to start its session."

        for descriptor in catalog {
            snapshotsByID[descriptor.id] = .init()
        }
    }

    func startListenersIfNeeded() {
        guard eventsTask == nil, stateTask == nil else { return }

        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.connectionEvents {
                await self.handle(event)
            }
        }

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in client.connectionState {
                await self.handle(state)
            }
        }
    }

    func snapshot(for serverID: UUID) -> ConnectedServiceSnapshot {
        snapshotsByID[serverID] ?? .init()
    }

    func connect(_ descriptor: MCPServerDescriptor) {
        guard sourcesByID[descriptor.id] == nil else { return }
        markBusy(true, serverID: descriptor.id)
        setState(.connecting, serverID: descriptor.id)

        Task {
            do {
                let source = try await client.connect(descriptor)
                await source.register(in: toolRegistry)
                let count = await source.currentToolNames().count
                // Snapshot the probe once so the enabled-count calculation
                // and the `foundationModelsCapActive` flag agree on the same
                // backend state, even if the user switches models mid-await.
                let foundationActive = isFoundationModelsActive()
                let enabledCount = await self.enabledCount(
                    for: source,
                    totalCount: count,
                    foundationActive: foundationActive
                )
                await MainActor.run {
                    self.sourcesByID[descriptor.id] = source
                    self.updateSnapshot(descriptor.id) { snapshot in
                        snapshot.isBusy = false
                        snapshot.isConnected = true
                        snapshot.state = .ready
                        snapshot.toolCount = count
                        snapshot.enabledToolCount = enabledCount
                        snapshot.foundationModelsCapActive = foundationActive
                        snapshot.errorMessage = nil
                        snapshot.authorizationRequest = nil
                    }
                }
                await self.refreshAdvertisedToolNames(foundationActive: foundationActive)
            } catch let mcpError as MCPError {
                await MainActor.run {
                    self.updateSnapshot(descriptor.id) { snapshot in
                        snapshot.isBusy = false
                        snapshot.isConnected = false
                        snapshot.state = .failed
                        snapshot.errorMessage = Self.errorMessage(for: mcpError)
                        if case .authorizationRequired(let request) = mcpError {
                            snapshot.authorizationRequest = request
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.updateSnapshot(descriptor.id) { snapshot in
                        snapshot.isBusy = false
                        snapshot.isConnected = false
                        snapshot.state = .failed
                        snapshot.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func disconnect(_ serverID: UUID) {
        guard let source = sourcesByID[serverID] else { return }
        markBusy(true, serverID: serverID)

        Task {
            await source.unregister(from: toolRegistry)
            await client.disconnect(serverID: serverID)
            await MainActor.run {
                self.sourcesByID.removeValue(forKey: serverID)
                self.updateSnapshot(serverID) { snapshot in
                    snapshot.isBusy = false
                    snapshot.isConnected = false
                    snapshot.state = .idle
                    snapshot.toolCount = 0
                    snapshot.enabledToolCount = 0
                    snapshot.errorMessage = nil
                    snapshot.authorizationRequest = nil
                }
            }
            await self.refreshAdvertisedToolNames(foundationActive: self.isFoundationModelsActive())
        }
    }

    private func handle(_ event: MCPConnectionEvent) async {
        switch event {
        case .connecting(let serverID):
            updateSnapshot(serverID) { snapshot in
                snapshot.state = .connecting
            }
        case .connected(let serverID, _):
            updateSnapshot(serverID) { snapshot in
                snapshot.state = .ready
                snapshot.isConnected = true
                snapshot.errorMessage = nil
                snapshot.authorizationRequest = nil
            }
            await refreshToolCount(for: serverID)
        case .toolsChanged(let serverID, _, _):
            await refreshToolCount(for: serverID)
        case .authorizationRequired(let serverID, let request):
            updateSnapshot(serverID) { snapshot in
                snapshot.authorizationRequest = request
                snapshot.errorMessage = "Authorization required before this service can be used."
                snapshot.state = .failed
                snapshot.isBusy = false
            }
        case .scopeDowngraded(let serverID, let requested, let granted):
            updateSnapshot(serverID) { snapshot in
                snapshot.errorMessage = "Granted scopes: \(granted.joined(separator: ", ")) (requested: \(requested.joined(separator: ", ")))."
            }
        case .disconnected(let serverID, _):
            sourcesByID.removeValue(forKey: serverID)
            updateSnapshot(serverID) { snapshot in
                snapshot.state = .idle
                snapshot.isConnected = false
                snapshot.isBusy = false
                snapshot.toolCount = 0
                snapshot.enabledToolCount = 0
            }
        case .error(let serverID, let error):
            updateSnapshot(serverID) { snapshot in
                snapshot.state = .failed
                snapshot.isBusy = false
                snapshot.errorMessage = Self.errorMessage(for: error)
                if case .authorizationRequired(let request) = error {
                    snapshot.authorizationRequest = request
                }
            }
        }
    }

    private func handle(_ state: MCPConnectionState) async {
        if state == .idle {
            for serverID in snapshotsByID.keys where sourcesByID[serverID] == nil {
                updateSnapshot(serverID) { snapshot in
                    if snapshot.isBusy == false {
                        snapshot.state = .idle
                    }
                }
            }
        }
    }

    private func refreshToolCount(for serverID: UUID) async {
        guard let source = sourcesByID[serverID] else { return }
        // Snapshot the probe once and reuse it for both the enabled-count
        // calculation and the snapshot flag, so they can't disagree if the
        // active backend changes mid-await.
        let foundationActive = isFoundationModelsActive()
        let toolCount = await source.currentToolNames().count
        let enabledCount = await enabledCount(
            for: source,
            totalCount: toolCount,
            foundationActive: foundationActive
        )
        await MainActor.run {
            self.updateSnapshot(serverID) { snapshot in
                snapshot.toolCount = toolCount
                snapshot.enabledToolCount = enabledCount
                snapshot.foundationModelsCapActive = foundationActive
                snapshot.isConnected = true
            }
        }
        await refreshAdvertisedToolNames(foundationActive: foundationActive)
    }

    private func enabledCount(
        for source: MCPToolSource,
        totalCount: Int,
        foundationActive: Bool
    ) async -> Int {
        guard foundationActive else { return totalCount }
        return await source.foundationModelsEnabledNames().count
    }

    private func refreshAdvertisedToolNames(foundationActive: Bool) async {
        guard foundationActive else {
            toolRegistry.advertisedToolNames = nil
            return
        }

        var allMCPToolNames: Set<String> = []
        var enabledMCPToolNames: Set<String> = []
        for source in sourcesByID.values {
            let currentNames = await source.currentToolNames()
            allMCPToolNames.formUnion(currentNames.map { $0.lowercased() })
            let enabledNames = await source.foundationModelsEnabledNames()
            enabledMCPToolNames.formUnion(enabledNames.map { $0.lowercased() })
        }

        guard allMCPToolNames.isEmpty == false else {
            toolRegistry.advertisedToolNames = nil
            return
        }

        let nonMCPToolNames = toolRegistry.definitions
            .map(\.name)
            .filter { allMCPToolNames.contains($0.lowercased()) == false }
            .map { $0.lowercased() }
        toolRegistry.advertisedToolNames = Set(nonMCPToolNames).union(enabledMCPToolNames)
    }

    /// Re-runs the per-server enabled-count projection using the current
    /// `isFoundationModelsActive()` value. Call this when the active backend
    /// changes (e.g., user picks a new model in Settings) so the
    /// "X of Y enabled" labels stay in sync without waiting for a
    /// tools/list refresh.
    func refreshEnabledCounts() {
        let serverIDs = Array(sourcesByID.keys)
        for serverID in serverIDs {
            Task { await refreshToolCount(for: serverID) }
        }
    }

    private func setState(_ state: MCPConnectionState, serverID: UUID) {
        updateSnapshot(serverID) { snapshot in
            snapshot.state = state
        }
    }

    private func markBusy(_ value: Bool, serverID: UUID) {
        updateSnapshot(serverID) { snapshot in
            snapshot.isBusy = value
        }
    }

    private func updateSnapshot(_ serverID: UUID, transform: (inout ConnectedServiceSnapshot) -> Void) {
        var snapshot = snapshotsByID[serverID] ?? .init()
        transform(&snapshot)
        snapshotsByID[serverID] = snapshot
    }

    private static func errorMessage(for error: MCPError) -> String {
        switch error {
        case .authorizationRequired:
            return "Authorization required before this service can be used."
        case .requestTimeout:
            return "Connection timed out."
        case .networkUnavailable:
            return "Network unavailable."
        case .unauthorized:
            return "Unauthorized."
        case .failed(let message), .transportFailure(let message), .authorizationFailed(let message):
            return message
        default:
            return String(describing: error)
        }
    }
}
