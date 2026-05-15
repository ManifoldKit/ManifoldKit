import Foundation
import ManifoldInference

// @unchecked Sendable: `client` is a weak var (mutable reference).
// Thread safety is guaranteed by MCPSession's actor isolation upstream —
// sessionDidReceive is only ever called from MCPSession's internal receiveTask,
// which is serialised by the actor. Concurrent access to `client` is therefore
// impossible in practice.
private final class MCPClientSessionHook: MCPSessionStateHook, @unchecked Sendable {
    weak var client: MCPClient?
    let serverID: UUID

    init(client: MCPClient, serverID: UUID) {
        self.client = client
        self.serverID = serverID
    }

    func sessionDidTransition(_ state: MCPSessionState) async {
        _ = state
    }

    func sessionDidSend(_ message: MCPJSONRPCMessage) async {
        _ = message
    }

    func sessionDidReceive(_ message: MCPJSONRPCMessage) async {
        guard case .notification = message else { return }
        await client?.handleSessionMessage(serverID: serverID, message: message)
    }
}

private final class WeakMCPClientBox: @unchecked Sendable {
    weak var client: MCPClient?

    init(client: MCPClient) {
        self.client = client
    }
}

public actor MCPClient {
    public nonisolated let connectionEvents: AsyncStream<MCPConnectionEvent>
    public nonisolated let connectionState: AsyncStream<MCPConnectionState>

    private let configuration: MCPClientConfiguration
    private let connectionEventContinuation: AsyncStream<MCPConnectionEvent>.Continuation
    private let connectionStateContinuation: AsyncStream<MCPConnectionState>.Continuation
    private var sourcesByID: [UUID: MCPToolSource] = [:]
    private var sessionsByID: [UUID: MCPSession] = [:]
    private var networkPathTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    public init(configuration: MCPClientConfiguration = .init()) {
        self.configuration = configuration
        let (connectionEvents, eventContinuation) = AsyncStream.makeStream(of: MCPConnectionEvent.self)
        let (connectionState, stateContinuation) = AsyncStream.makeStream(of: MCPConnectionState.self)
        self.connectionEvents = connectionEvents
        self.connectionState = connectionState
        connectionEventContinuation = eventContinuation
        connectionStateContinuation = stateContinuation
        connectionStateContinuation.yield(.idle)

        Task { await self.startObserverTasks() }
    }

    deinit {
        networkPathTask?.cancel()
        lifecycleTask?.cancel()
    }

    public func connect(
        _ descriptor: MCPServerDescriptor,
        authorization: any MCPAuthorization = MCPNoAuthorization()
    ) async throws -> MCPToolSource {
        connectionStateContinuation.yield(.connecting)
        connectionEventContinuation.yield(.connecting(serverID: descriptor.id))

        do {
            let transport = try makeTransport(for: descriptor, authorization: authorization)
            let stateHook = MCPClientSessionHook(client: self, serverID: descriptor.id)
            let session = MCPSession(
                descriptor: descriptor,
                transport: transport,
                codec: MCPJSONRPCCodec(
                    maxMessageBytes: configuration.maxMessageBytes,
                    maxJSONNestingDepth: configuration.maxJSONNestingDepth
                ),
                requestTimeout: descriptor.initializationTimeout,
                maxConcurrentRequests: configuration.maxConcurrentRequestsPerSession,
                stateHook: stateHook
            )

            let capabilities = try await session.start()
            let source = MCPToolSource(
                serverID: descriptor.id,
                displayName: descriptor.displayName,
                capabilities: capabilities,
                toolNamespace: descriptor.toolNamespace,
                toolFilter: descriptor.toolFilter,
                approvalPolicy: descriptor.approvalPolicy,
                listTools: { [session] in
                    try await session.sendRequest(method: "tools/list", params: nil)
                },
                callTool: { [session] toolName, arguments in
                    try await session.sendRequest(
                        method: "tools/call",
                        params: .object([
                            "name": .string(toolName),
                            "arguments": arguments,
                        ])
                    )
                }
            )
            sessionsByID[descriptor.id] = session
            sourcesByID[descriptor.id] = source
            connectionStateContinuation.yield(.ready)
            connectionEventContinuation.yield(.connected(serverID: descriptor.id, capabilities: capabilities))
            return source
        } catch let error as MCPError {
            connectionStateContinuation.yield(.failed)
            connectionEventContinuation.yield(.error(serverID: descriptor.id, error))
            throw error
        } catch {
            let mcpError = MCPError.transportFailure(error.localizedDescription)
            connectionStateContinuation.yield(.failed)
            connectionEventContinuation.yield(.error(serverID: descriptor.id, mcpError))
            throw mcpError
        }
    }

    public func disconnect(serverID: UUID) async {
        if let session = sessionsByID.removeValue(forKey: serverID) {
            await session.close(reason: .requested)
        }
        if let source = sourcesByID.removeValue(forKey: serverID) {
            await source.close()
        }
        connectionEventContinuation.yield(.disconnected(serverID: serverID, reason: .requested))
        connectionStateContinuation.yield(sourcesByID.isEmpty ? .idle : .ready)
    }

    public func disconnectAll() async {
        let sessions = sessionsByID.values
        sessionsByID.removeAll()
        for session in sessions {
            await session.close(reason: .requested)
        }
        let sources = sourcesByID.values
        sourcesByID.removeAll()
        for source in sources {
            await source.close()
        }
        connectionStateContinuation.yield(.idle)
    }

    public func sources() async -> [MCPToolSource] {
        Array(sourcesByID.values)
    }

    private func makeTransport(
        for descriptor: MCPServerDescriptor,
        authorization: any MCPAuthorization
    ) throws -> any MCPTransport {
        switch descriptor.transport {
        case .streamableHTTP(let endpoint, let headers):
            try MCPSSRFPolicy.validateTransportURL(endpoint)
            return MCPStreamableHTTPTransport(configuration: MCPTransportConfiguration(
                endpoint: endpoint,
                headers: headers,
                authorization: authorization,
                sseLimits: configuration.sseStreamLimits,
                maxMessageBytes: configuration.maxMessageBytes
            ))
        case .stdio(let command):
            #if os(macOS) && !targetEnvironment(macCatalyst)
            return MCPStdioTransport(
                command: command,
                maxMessageBytes: configuration.maxMessageBytes
            )
            #else
            throw MCPError.transportFailure("stdio MCP transport is unavailable on this platform")
            #endif
        }
    }

    internal func handleSessionMessage(serverID: UUID, message: MCPJSONRPCMessage) async {
        guard case .notification(let method, _) = message,
              method == "notifications/tools/list_changed",
              let source = sourcesByID[serverID] else {
            return
        }

        do {
            let delta = try await source.refreshToolsAndReturnDelta(invalidateApprovalsForChangedTools: true)
            if delta.addedNames.isEmpty == false || delta.removedNames.isEmpty == false {
                connectionEventContinuation.yield(.toolsChanged(
                    serverID: serverID,
                    addedNames: delta.addedNames,
                    removedNames: delta.removedNames
                ))
            }
        } catch let error as MCPError {
            connectionEventContinuation.yield(.error(serverID: serverID, error))
        } catch {
            connectionEventContinuation.yield(.error(serverID: serverID, .transportFailure(error.localizedDescription)))
        }
    }

    private func startObserverTasks() {
        let weakBox = WeakMCPClientBox(client: self)

        if let observer = configuration.networkPathObserver {
            let updates = observer.pathUpdates
            networkPathTask = Task {
                for await status in updates {
                    guard let client = weakBox.client else { return }
                    await client.handleNetworkPath(status)
                }
            }
        }

        if let observer = configuration.lifecycleObserver {
            let updates = observer.events
            lifecycleTask = Task {
                for await event in updates {
                    guard let client = weakBox.client else { return }
                    await client.handleLifecycleEvent(event)
                }
            }
        }
    }

    private func handleNetworkPath(_ status: MCPNetworkPathStatus) async {
        switch status {
        case .satisfied:
            connectionStateContinuation.yield(sourcesByID.isEmpty ? .idle : .ready)
        case .unsatisfied, .requiresConnection:
            guard sessionsByID.isEmpty == false else {
                connectionStateContinuation.yield(.idle)
                return
            }
            connectionStateContinuation.yield(.reconnecting)
            await closeAllSessions(reason: .networkUnavailable, error: .networkUnavailable)
        }
    }

    private func handleLifecycleEvent(_ event: MCPLifecycleEvent) async {
        switch event {
        case .didEnterBackground:
            guard configuration.lifecyclePolicy == .cancelOnBackground else { return }
            guard sessionsByID.isEmpty == false else { return }
            await closeAllSessions(reason: .requested, error: .backgroundedDuringDispatch)
        case .willEnterForeground:
            connectionStateContinuation.yield(sourcesByID.isEmpty ? .idle : .ready)
        case .memoryWarning:
            guard sessionsByID.isEmpty == false else { return }
            await closeAllSessions(reason: .memoryPressure, error: .transportFailure("memory warning"))
        }
    }

    private func closeAllSessions(
        reason: MCPDisconnectReason,
        error: MCPError?
    ) async {
        let sessions = sessionsByID
        let sources = sourcesByID
        sessionsByID.removeAll()
        sourcesByID.removeAll()

        for (serverID, session) in sessions {
            await session.close(reason: reason)
            if let source = sources[serverID] {
                await source.close()
            }
            if let error {
                connectionEventContinuation.yield(.error(serverID: serverID, error))
            }
            connectionEventContinuation.yield(.disconnected(serverID: serverID, reason: reason))
        }

        connectionStateContinuation.yield(.idle)
    }
}
