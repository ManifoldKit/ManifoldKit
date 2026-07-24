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
        // Require explicit opt-in for STDIO transport — it spawns an arbitrary
        // subprocess with the app's privileges and bypasses TLS + SSRF guards.
        if case .stdio = descriptor.transport, !descriptor.allowsSTDIOTransport {
            let error = MCPError.transportFailure(
                "STDIO transport requires explicit opt-in via MCPServerDescriptor.allowsSTDIOTransport. " +
                "See SECURITY.md for the threat model."
            )
            connectionStateContinuation.yield(.failed)
            connectionEventContinuation.yield(.error(serverID: descriptor.id, error))
            throw error
        }

        // Require explicit opt-in for unauthenticated servers — tool call arguments
        // are sent in the clear and the server has no cryptographic identity.
        if case .none = descriptor.authorization, !descriptor.isUnauthenticatedUnsafe {
            let error = MCPError.transportFailure(
                "MCP server has no auth configuration. " +
                "Set isUnauthenticatedUnsafe: true to permit unauthenticated connections."
            )
            connectionStateContinuation.yield(.failed)
            connectionEventContinuation.yield(.error(serverID: descriptor.id, error))
            throw error
        }

        // Mirror of the guard above for the opposite mismatch: the descriptor
        // declares OAuth but the caller left `authorization:` at its default
        // MCPNoAuthorization. Without this the connection sails through here
        // and fails opaquely on the first 401 from the transport layer.
        if case .oauth = descriptor.authorization, authorization is MCPNoAuthorization {
            let error = MCPError.transportFailure(
                "MCPServerDescriptor.authorization declares .oauth(...) but connect(_:authorization:) " +
                "was called with the default MCPNoAuthorization. Construct an MCPOAuthAuthorization " +
                "from the descriptor's authorization metadata (MCPAuthorizationDescriptor.OAuthDescriptor, " +
                "i.e. descriptor.authorization's associated value) and pass it as the authorization: argument."
            )
            connectionStateContinuation.yield(.failed)
            connectionEventContinuation.yield(.error(serverID: descriptor.id, error))
            throw error
        }

        // Route this authorization's own event stream (authorizationRequired /
        // scopeDowngraded, raised during token acquisition/refresh) into this
        // client's connectionEvents — the continuation otherwise defaults to
        // nil and those events are never observable by a host.
        if let oauthAuthorization = authorization as? MCPOAuthAuthorization {
            await oauthAuthorization.attach(eventContinuation: connectionEventContinuation)
        }

        connectionStateContinuation.yield(.connecting)
        connectionEventContinuation.yield(.connecting(serverID: descriptor.id))

        do {
            let transport = try makeTransport(for: descriptor, authorization: authorization)
            let stateHook = MCPClientSessionHook(client: self, serverID: descriptor.id)
            let samplingEnabled = Self.samplingEnabled(for: descriptor, configuration: configuration)
            let elicitationEnabled = Self.elicitationEnabled(for: descriptor, configuration: configuration)
            let session = MCPSession(
                descriptor: descriptor,
                transport: transport,
                codec: MCPJSONRPCCodec(
                    maxMessageBytes: configuration.maxMessageBytes,
                    maxJSONNestingDepth: configuration.maxJSONNestingDepth
                ),
                requestTimeout: descriptor.requestTimeout ?? configuration.requestTimeout,
                maxConcurrentRequests: configuration.maxConcurrentRequestsPerSession,
                stateHook: stateHook,
                serverRequestHandler: makeServerRequestHandler(
                    for: descriptor,
                    samplingEnabled: samplingEnabled,
                    elicitationEnabled: elicitationEnabled
                ),
                advertisesSampling: samplingEnabled,
                advertisesElicitation: elicitationEnabled
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

    /// The consent gate for `sampling/createMessage`: a server can only issue sampling
    /// requests when it has opted in (`allowsSampling`) AND the host has wired up a
    /// handler. Extracted to a `nonisolated static` function (rather than inlined in
    /// `connect()`) so tests can assert on the exact gate `connect()` uses instead of
    /// hand-duplicating the boolean expression — see the sibling `elicitationEnabled(for:configuration:)`
    /// doc for why that distinction matters (#2284 review finding 2).
    internal nonisolated static func samplingEnabled(
        for descriptor: MCPServerDescriptor,
        configuration: MCPClientConfiguration
    ) -> Bool {
        descriptor.allowsSampling && configuration.samplingHandler != nil
    }

    /// The consent gate for `elicitation/create`: a server can only issue elicitation
    /// requests when it has opted in (`allowsElicitation`) AND the host has wired up a
    /// handler. `connect()` calls this directly (not a hand-copied boolean expression)
    /// so a test can assert on the SAME logic production code runs.
    ///
    /// Extracted as its own `nonisolated static` function per #2284 review finding 2:
    /// every existing elicitation test constructed `MCPSession` directly via
    /// `makeSession(...)` in `MCPElicitationTests.swift`, hand-passing
    /// `advertisesElicitation:` — none of them exercised this gate itself. Proven
    /// sabotage at review time: deleting `descriptor.allowsElicitation &&` from the old
    /// inline expression left all 15 existing tests green.
    /// `MCPElicitationTests.test_clientGateBlocksElicitationWhenDescriptorOptsOut` now
    /// calls this function directly, so that sabotage fails immediately.
    internal nonisolated static func elicitationEnabled(
        for descriptor: MCPServerDescriptor,
        configuration: MCPClientConfiguration
    ) -> Bool {
        descriptor.allowsElicitation && configuration.elicitationHandler != nil
    }

    /// Builds the `MCPSession`-level server-request handler, wiring
    /// `sampling/createMessage` to the host's `samplingHandler` and
    /// `elicitation/create` to the host's `elicitationHandler` — each only when the
    /// server has opted in (`allowsSampling`/`allowsElicitation`) AND the host has
    /// configured the matching handler. Returning `nil` here (both disabled) is what
    /// makes `MCPSession` advertise neither capability and reply "method not found"
    /// to any server-initiated request; see the security notes on
    /// `MCPClientConfiguration.samplingHandler` and `.elicitationHandler`.
    ///
    /// A single combined closure — rather than one per method — keeps `MCPSession`'s
    /// dispatch seam (`MCPServerRequestHandler`) method-agnostic; capability
    /// advertisement is driven independently by `advertisesSampling`/
    /// `advertisesElicitation` at the call site, not by whether this closure is nil.
    ///
    /// Takes `descriptor` (not just its `id`) so `MCPSamplingRequest`/
    /// `MCPElicitationRequest` can be stamped with `descriptor.id` as `serverID` —
    /// the host's ONLY way to tell which of possibly many connected servers is
    /// asking, since `samplingHandler`/`elicitationHandler` are each one closure
    /// shared across every session (#2284 review, blocker 1). `serverID` always
    /// comes from the descriptor used to `connect(_:)`, never from server-controlled
    /// wire data, so a malicious server cannot spoof another server's identity.
    /// `internal` (not `private`) so a test can drive the real closure `connect()`
    /// wires — mirroring the `elicitationEnabled(for:configuration:)` seam above.
    /// `MCPElicitationTests.test_makeServerRequestHandlerAutoDeclinesUnsupportedSchema`
    /// calls this directly to prove the `isSupportedSchema` auto-decline guard is
    /// live: deleting that guard (forwarding an unsupported schema to the host form
    /// renderer, the exact shape #1926 resolved to prevent) fails that test.
    internal func makeServerRequestHandler(
        for descriptor: MCPServerDescriptor,
        samplingEnabled: Bool,
        elicitationEnabled: Bool
    ) -> MCPServerRequestHandler? {
        guard samplingEnabled || elicitationEnabled else { return nil }
        let serverID = descriptor.id
        let samplingHandler = configuration.samplingHandler
        let elicitationHandler = configuration.elicitationHandler
        return { method, params in
            switch method {
            case "sampling/createMessage":
                guard samplingEnabled, let samplingHandler else {
                    return .failure(MCPJSONRPCErrorObject(code: -32601, message: "Method not found: \(method)", data: nil))
                }
                do {
                    let request = try MCPSamplingRequest(serverID: serverID, params: params)
                    let result = try await samplingHandler(request)
                    return .success(result.jsonRPCResult)
                } catch is CancellationError {
                    return .failure(MCPJSONRPCErrorObject(code: -32800, message: "Request cancelled", data: nil))
                } catch let error as MCPError {
                    return .failure(MCPJSONRPCErrorObject(code: -32602, message: error.localizedDescription, data: nil))
                } catch {
                    Log.inference.error("MCPClient: sampling/createMessage handler threw: \(error, privacy: .private)")
                    return .failure(MCPJSONRPCErrorObject(code: -32000, message: "Sampling handler failed", data: nil))
                }
            case "elicitation/create":
                guard elicitationEnabled, let elicitationHandler else {
                    return .failure(MCPJSONRPCErrorObject(code: -32601, message: "Method not found: \(method)", data: nil))
                }
                do {
                    let request = try MCPElicitationRequest(serverID: serverID, params: params)
                    // Spec restricts `requestedSchema` to a flat object of primitive
                    // properties. #1926 resolved to validate and auto-decline
                    // unsupported shapes rather than forward them to the host's form
                    // renderer (#2284 review finding 3).
                    guard MCPElicitationRequest.isSupportedSchema(request.requestedSchema) else {
                        return .success(MCPElicitationResult(action: .decline).jsonRPCResult)
                    }
                    let result = try await elicitationHandler(request)
                    return .success(result.jsonRPCResult)
                } catch is CancellationError {
                    return .failure(MCPJSONRPCErrorObject(code: -32800, message: "Request cancelled", data: nil))
                } catch let error as MCPError {
                    return .failure(MCPJSONRPCErrorObject(code: -32602, message: error.localizedDescription, data: nil))
                } catch {
                    Log.inference.error("MCPClient: elicitation/create handler threw: \(error, privacy: .private)")
                    return .failure(MCPJSONRPCErrorObject(code: -32000, message: "Elicitation handler failed", data: nil))
                }
            default:
                return .failure(MCPJSONRPCErrorObject(code: -32601, message: "Method not found: \(method)", data: nil))
            }
        }
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
