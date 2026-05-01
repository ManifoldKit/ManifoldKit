import Foundation
import BaseChatInference

#if canImport(BaseChatMCP)
import BaseChatMCP
import Observation

// Coordinator for ConnectedServicesView. Owns the MCPClient, drives connect/disconnect
// lifecycle, and projects raw MCPConnectionEvent/MCPConnectionState into snapshots the
// view can observe without holding any MCP types directly.
@MainActor
@Observable
final class DemoMCPCoordinator {
    private let toolRegistry: ToolRegistry
    private let client: MCPClient
    private var sourcesByID: [UUID: MCPToolSource] = [:]
    private var snapshotsByID: [UUID: ConnectedServiceSnapshot] = [:]
    private var eventsTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    let catalog: [MCPServerDescriptor]
    let catalogHelpText: String

    /// Probe used to decide whether the Foundation Models tool cap is biting.
    /// When `true`, each per-server snapshot's `enabledToolCount` reflects only
    /// the tools that pass ``MCPToolSource/foundationModelsEnabledNames(maxDepth:cap:)``
    /// (schema-compatible, capped at ``MCPToolFilter/foundationModelsToolCap``).
    /// When `false`, `enabledToolCount` mirrors `toolCount`.
    var isFoundationModelsActive: () -> Bool

    init(
        toolRegistry: ToolRegistry,
        isFoundationModelsActive: @escaping () -> Bool = { false }
    ) {
        self.toolRegistry = toolRegistry
        self.client = MCPClient()
        self.isFoundationModelsActive = isFoundationModelsActive

        // Catalog composition rationale (PR #921 / `feat/demo-mcp-server`):
        // - The MCPBuiltinCatalog trait is enabled in the demo's pbxproj so
        //   `MCPCatalog.all` (Notion / Linear / GitHub) is non-empty out of
        //   the box. These OAuth-gated entries are useful for users who have
        //   accounts with those providers, but they aren't a no-config happy
        //   path for someone just kicking the tyres.
        // - To give every macOS user a working tap-to-connect server with
        //   zero credentials, we prepend a stdio descriptor that launches
        //   `@modelcontextprotocol/server-everything` via `npx`. The server
        //   is the official MCP reference implementation and exposes an
        //   `echo` tool the `mcp-echo` demo scenario calls. The descriptor
        //   is gated to macOS because `MCPClient.makeTransport` rejects
        //   stdio on every other platform.
        var assembled: [MCPServerDescriptor] = []
        #if os(macOS) && !targetEnvironment(macCatalyst)
        assembled.append(Self.demoEchoDescriptor)
        #endif
        #if MCPBuiltinCatalog
        assembled.append(contentsOf: MCPCatalog.all)
        #endif
        self.catalog = assembled

        if assembled.isEmpty {
            self.catalogHelpText = "No services configured. Enable the MCPBuiltinCatalog trait or run on macOS to see the demo Echo server."
        } else {
            self.catalogHelpText = "Tap Connect on a service to start its session."
        }

        for descriptor in catalog {
            snapshotsByID[descriptor.id] = .init()
        }
    }

    /// Stable UUID for the demo Echo descriptor — kept stable so the
    /// scenario runner and the connect button refer to the same server
    /// across launches, and so XCUITests can target it deterministically.
    private static let demoEchoServerID = UUID(uuidString: "8E3F1F1B-0E69-4D8B-9D4D-7E2D2F2A8F11")!

    /// macOS-only stdio descriptor for the official MCP "everything" server.
    /// Pulled via `npx -y @modelcontextprotocol/server-everything`, which
    /// requires Node.js on PATH but no credentials. Exposes an `echo` tool
    /// the `mcp-echo` demo scenario invokes end-to-end through the MCP
    /// tool bridge.
    private static var demoEchoDescriptor: MCPServerDescriptor {
        MCPServerDescriptor(
            id: demoEchoServerID,
            displayName: "Demo Echo (local, via npx)",
            transport: .stdio(.npx(package: "@modelcontextprotocol/server-everything")),
            authorization: .none,
            toolNamespace: "everything",
            resourceURL: nil,
            dataDisclosure: "Launches the official MCP reference server locally over stdio. Requires Node.js (npx) on PATH. No credentials are sent off-device; tool arguments stay local to the spawned process.",
            toolFilter: .allowAll,
            approvalPolicy: .perCall
        )
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
                // Snapshot the probe once so the enabled-count calculation and the
                // `foundationModelsCapActive` flag agree on the same backend state,
                // even if the user switches models mid-await. (PR #797 review fix.)
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
        // active backend changes mid-await. (PR #797 review fix.)
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
    }

    private func enabledCount(
        for source: MCPToolSource,
        totalCount: Int,
        foundationActive: Bool
    ) async -> Int {
        guard foundationActive else { return totalCount }
        return await source.foundationModelsEnabledNames().count
    }

    /// Re-runs the per-server enabled-count projection using the current
    /// `isFoundationModelsActive()` value. Call this when the active backend
    /// changes (e.g., user picks a new model in Settings) so the
    /// "X of Y enabled" labels stay in sync without waiting for a tools/list
    /// refresh.
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

#endif
