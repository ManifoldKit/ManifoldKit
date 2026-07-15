import Foundation
import ManifoldInference
import os

internal enum MCPSessionState: Sendable, Equatable {
    case idle
    case connecting
    case ready
    case closed
}

internal protocol MCPSessionStateHook: Sendable {
    func sessionDidTransition(_ state: MCPSessionState) async
    func sessionDidSend(_ message: MCPJSONRPCMessage) async
    func sessionDidReceive(_ message: MCPJSONRPCMessage) async
}

internal struct MCPNoopSessionStateHook: MCPSessionStateHook {
    func sessionDidTransition(_ state: MCPSessionState) async { _ = state }
    func sessionDidSend(_ message: MCPJSONRPCMessage) async { _ = message }
    func sessionDidReceive(_ message: MCPJSONRPCMessage) async { _ = message }
}

/// Handles a server-initiated JSON-RPC request (currently only
/// `sampling/createMessage`). Returning `.failure` replies with a JSON-RPC error
/// frame rather than dropping the request — a server must never be left hanging.
internal typealias MCPServerRequestHandler = @Sendable (
    _ method: String,
    _ params: JSONSchemaValue?
) async -> Result<JSONSchemaValue, MCPJSONRPCErrorObject>

internal actor MCPSession {
    private let descriptor: MCPServerDescriptor
    private let transport: any MCPTransport
    private let codec: MCPJSONRPCCodec
    private let requestTimeout: Duration
    private let maxConcurrentRequests: Int
    private let stateHook: any MCPSessionStateHook
    private let serverRequestHandler: MCPServerRequestHandler?

    private var state: MCPSessionState = .idle
    private var nextRequestID: Int = 1
    private var receiveTask: Task<Void, Never>?
    private var pendingRequests: [MCPRequestID: CheckedContinuation<JSONSchemaValue?, Error>] = [:]

    init(
        descriptor: MCPServerDescriptor,
        transport: any MCPTransport,
        codec: MCPJSONRPCCodec,
        requestTimeout: Duration,
        maxConcurrentRequests: Int,
        stateHook: any MCPSessionStateHook = MCPNoopSessionStateHook(),
        serverRequestHandler: MCPServerRequestHandler? = nil
    ) {
        self.descriptor = descriptor
        self.transport = transport
        self.codec = codec
        self.requestTimeout = requestTimeout
        self.maxConcurrentRequests = maxConcurrentRequests
        self.stateHook = stateHook
        self.serverRequestHandler = serverRequestHandler
    }

    func start() async throws -> MCPCapabilities {
        guard state == .idle else {
            throw MCPError.transportFailure("Session already started")
        }

        state = .connecting
        await stateHook.sessionDidTransition(.connecting)
        try await transport.start()
        startReceiveLoop()

        // Advertise `sampling` only when a server-request handler is actually wired up
        // (descriptor.allowsSampling AND a host samplingHandler configured — see
        // MCPClient.connect). Advertising unconditionally would invite servers to send
        // requests this session will just reject.
        let clientCapabilities: JSONSchemaValue = serverRequestHandler != nil
            ? .object(["sampling": .object([:])])
            : .object([:])

        let initializeParams: JSONSchemaValue = .object([
            "protocolVersion": .string("2025-03-26"),
            "capabilities": clientCapabilities,
            "clientInfo": .object([
                "name": .string(ManifoldConfiguration.shared.appName),
                "version": .string("1.0.0"),
            ]),
        ])

        // The initialize handshake is bounded by `initializationTimeout`, not the
        // steady-state `requestTimeout`: a server's first-response latency (process
        // spawn, model warm-up, auth) is a separate budget from ordinary
        // request/response, and callers set the two independently on the descriptor.
        let response = try await sendRequest(
            method: "initialize",
            params: initializeParams,
            timeout: descriptor.initializationTimeout
        )
        let capabilities = try parseInitializeResponse(response)
        try await sendNotification(method: "notifications/initialized", params: nil)

        state = .ready
        await stateHook.sessionDidTransition(.ready)
        return capabilities
    }

    /// - Parameter timeout: overrides the session's steady-state `requestTimeout`
    ///   for this one call. The initialize handshake passes
    ///   `descriptor.initializationTimeout` here; all other callers omit it.
    func sendRequest(
        method: String,
        params: JSONSchemaValue?,
        timeout: Duration? = nil
    ) async throws -> JSONSchemaValue? {
        guard state != .closed else { throw MCPError.transportClosed }

        if pendingRequests.count >= maxConcurrentRequests {
            throw MCPError.transportFailure("Exceeded max concurrent MCP requests")
        }

        let id = MCPRequestID.int(nextRequestID)
        nextRequestID += 1
        let request = MCPJSONRPCMessage.request(id: id, method: method, params: params)
        let payload = try codec.encode(request)

        // Capture a reference for the cancellation notification. The onCancel closure runs
        // synchronously and cannot be async, so we spawn a detached Task to deliver
        // notifications/cancelled before the server wastes work on an abandoned call.
        return try await withTaskCancellationHandler {
            try await withTimeout(timeout ?? requestTimeout) { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await registerPendingAndSend(
                            id: id,
                            request: request,
                            payload: payload,
                            continuation: continuation
                        )
                    }
                }
            } onTimeout: { [weak self] in
                await self?.handleRequestTimeout(id: id)
            }
        } onCancel: { [weak self] in
            guard let session = self else { return }
            let cancelParams: JSONSchemaValue = .object([
                "requestId": .string(id.description),
                "reason": .string("Cancelled by client"),
            ])
            Task {
                await session.sendNotificationIgnoringErrors(
                    method: "notifications/cancelled",
                    params: cancelParams
                )
            }
        }
    }

    func sendNotification(method: String, params: JSONSchemaValue?) async throws {
        guard state != .closed else { throw MCPError.transportClosed }
        let message = MCPJSONRPCMessage.notification(method: method, params: params)
        let payload = try codec.encode(message)
        try await transport.send(payload, routing: routing(for: message))
        await stateHook.sessionDidSend(message)
    }

    /// Fire-and-forget notification — errors are logged but do not propagate, so callers can
    /// use this from a cancellation handler without preventing `CancellationError` from propagating.
    func sendNotificationIgnoringErrors(method: String, params: JSONSchemaValue?) async {
        let message = MCPJSONRPCMessage.notification(method: method, params: params)
        let payload: Data
        do {
            payload = try codec.encode(message)
        } catch {
            Log.inference.error("MCPSession: failed to encode notification '\(method, privacy: .public)': \(error, privacy: .private)")
            return
        }
        do {
            try await transport.send(payload, routing: routing(for: message))
        } catch {
            Log.inference.error("MCPSession: failed to send notification '\(method, privacy: .public)': \(error, privacy: .private)")
        }
    }

    /// Replies to a server-initiated request (e.g. `sampling/createMessage`) with a
    /// JSON-RPC result frame.
    func sendResult(id: MCPRequestID, result: JSONSchemaValue) async {
        guard state != .closed else { return }
        let message = MCPJSONRPCMessage.result(id: id, result: result)
        do {
            let payload = try codec.encode(message)
            try await transport.send(payload, routing: nil)
            await stateHook.sessionDidSend(message)
        } catch {
            Log.inference.error("MCPSession: failed to send result for request \(id.description, privacy: .public): \(error, privacy: .private)")
        }
    }

    /// Replies to a server-initiated request with a JSON-RPC error frame. Used both
    /// when the handler throws and when no handler is configured for the method —
    /// a server request must always get a reply, never a silent drop.
    func sendError(id: MCPRequestID, error: MCPJSONRPCErrorObject) async {
        guard state != .closed else { return }
        let message = MCPJSONRPCMessage.error(id: id, error: error)
        do {
            let payload = try codec.encode(message)
            try await transport.send(payload, routing: nil)
            await stateHook.sessionDidSend(message)
        } catch {
            Log.inference.error("MCPSession: failed to send error for request \(id.description, privacy: .public): \(error, privacy: .private)")
        }
    }

    func close(reason: MCPDisconnectReason = .requested) async {
        _ = reason
        state = .closed
        await stateHook.sessionDidTransition(.closed)
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()

        let remaining = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in remaining {
            continuation.resume(throwing: MCPError.transportClosed)
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task {
            do {
                for try await payload in transport.incomingMessages {
                    if Task.isCancelled { break }
                    let message = try codec.decode(payload)
                    await stateHook.sessionDidReceive(message)
                    handleIncoming(message)
                }
                await close(reason: .transportClosed)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await close(reason: .requested)
                } else {
                    await close(reason: .failed(error.localizedDescription))
                }
            }
        }
    }

    private func handleIncoming(_ message: MCPJSONRPCMessage) {
        switch message {
        case .result(let id, let result):
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            continuation.resume(returning: result)
        case .error(let id, let error):
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            continuation.resume(throwing: MCPError.protocolError(
                code: error.code,
                message: error.message,
                data: error.data.flatMap(stringify)
            ))
        case .request(let id, let method, let params):
            handleServerRequest(id: id, method: method, params: params)
        case .notification:
            return
        }
    }

    /// Dispatches a server-initiated request. Runs off the receive loop in its own
    /// `Task` so a slow sampling generation doesn't block subsequent incoming
    /// messages from being decoded; `sendResult`/`sendError` reply once it settles.
    /// A request is never silently dropped — even with no handler configured, the
    /// server gets a JSON-RPC error back rather than hanging.
    private func handleServerRequest(id: MCPRequestID, method: String, params: JSONSchemaValue?) {
        guard let serverRequestHandler else {
            Task { [weak self] in
                await self?.sendError(
                    id: id,
                    error: MCPJSONRPCErrorObject(code: -32601, message: "Method not found: \(method)", data: nil)
                )
            }
            return
        }
        Task { [weak self] in
            let result = await serverRequestHandler(method, params)
            switch result {
            case .success(let value):
                await self?.sendResult(id: id, result: value)
            case .failure(let errorObject):
                await self?.sendError(id: id, error: errorObject)
            }
        }
    }

    private func parseInitializeResponse(_ response: JSONSchemaValue?) throws -> MCPCapabilities {
        guard case .object(let object) = response else {
            throw MCPError.malformedMetadata("Initialize response must be an object")
        }

        let protocolVersion = stringValue(object["protocolVersion"]) ?? ""
        if protocolVersion != "2025-03-26" {
            throw MCPError.unsupportedProtocolVersion(server: protocolVersion, client: "2025-03-26")
        }

        let serverInfo = object["serverInfo"]
        let serverName = objectValue(serverInfo)?["name"].flatMap(stringValue) ?? descriptor.displayName
        let serverVersion = objectValue(serverInfo)?["version"].flatMap(stringValue) ?? ""

        let capabilities = objectValue(object["capabilities"])
        let toolCapabilities = capabilities?["tools"].flatMap(objectValue)

        return MCPCapabilities(
            protocolVersion: protocolVersion,
            serverName: serverName,
            serverVersion: serverVersion,
            supportsToolListChanged: toolCapabilities?["listChanged"].flatMap(boolValue) ?? true,
            supportsResources: capabilities?["resources"] != nil,
            supportsPrompts: capabilities?["prompts"] != nil,
            supportsLogging: capabilities?["logging"] != nil
        )
    }

    private func failPendingRequest(id: MCPRequestID, error: Error) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    /// Cleanup invoked when the request timeout wins the race in ``withTimeout``.
    ///
    /// Without this, a server that accepts a request but never answers its id
    /// leaks both the inner continuation and the `pendingRequests[id]`
    /// concurrency slot permanently — after `maxConcurrentRequests` such events
    /// every `sendRequest` throws "Exceeded max concurrent MCP requests" until
    /// reconnect. Evict the entry (resuming the leaked continuation so the slot
    /// is reclaimed) and tell the server to stop wasting work on the abandoned
    /// call.
    private func handleRequestTimeout(id: MCPRequestID) async {
        failPendingRequest(id: id, error: MCPError.requestTimeout)
        let cancelParams: JSONSchemaValue = .object([
            "requestId": .string(id.description),
            "reason": .string("Request timed out"),
        ])
        await sendNotificationIgnoringErrors(
            method: "notifications/cancelled",
            params: cancelParams
        )
    }

    private func registerPendingAndSend(
        id: MCPRequestID,
        request: MCPJSONRPCMessage,
        payload: Data,
        continuation: CheckedContinuation<JSONSchemaValue?, Error>
    ) async {
        pendingRequests[id] = continuation
        do {
            try await transport.send(payload, routing: routing(for: request))
            await stateHook.sessionDidSend(request)
        } catch {
            failPendingRequest(id: id, error: error)
        }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () async -> Void = {}
    ) async throws -> T {
        // Use unstructured tasks so the timeout race doesn't wait for the operation
        // task to drain. withThrowingTaskGroup waits for ALL child tasks on exit;
        // if the operation is suspended in withCheckedThrowingContinuation (awaiting
        // a server response that never arrives), Swift 6.2 does not automatically
        // resume it with CancellationError, causing an indefinite hang.
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            func claimResume() -> Bool {
                resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
            }

            let operationTask = Task {
                do {
                    let value = try await operation()
                    if claimResume() { continuation.resume(returning: value) }
                } catch {
                    if claimResume() { continuation.resume(throwing: error) }
                }
            }

            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                // The timeout won. Claim the resume slot first so the operation
                // task's own completion becomes a no-op, then cancel it, run the
                // caller's cleanup (evict the pending entry + notify the server —
                // see `handleRequestTimeout`), and finally surface the timeout.
                // Cancelling alone is not enough: the operation is suspended in a
                // continuation awaiting a server reply, which cancellation cannot
                // resume; the cleanup resumes it explicitly.
                guard claimResume() else { return }
                operationTask.cancel()
                await onTimeout()
                continuation.resume(throwing: MCPError.requestTimeout)
            }
        }
    }
}

/// Derives the `Mcp-Method`/`Mcp-Name` routing metadata for a JSON-RPC message so the
/// HTTP transport can emit the spec-mandated headers (2026-07-28). The tool name for a
/// `tools/call` request lives in `params.name`; other methods carry no `Mcp-Name`.
private func routing(for message: MCPJSONRPCMessage) -> MCPRouting? {
    switch message {
    case .request(_, let method, let params), .notification(let method, let params):
        let name = method == "tools/call" ? stringValue(objectValue(params)?["name"]) : nil
        return MCPRouting(method: method, name: name)
    case .result, .error:
        return nil
    }
}

private func objectValue(_ value: JSONSchemaValue?) -> [String: JSONSchemaValue]? {
    guard case .object(let object) = value else { return nil }
    return object
}

private func stringValue(_ value: JSONSchemaValue?) -> String? {
    guard case .string(let string) = value else { return nil }
    return string
}

private func boolValue(_ value: JSONSchemaValue?) -> Bool? {
    guard case .bool(let bool) = value else { return nil }
    return bool
}

private func stringify(_ value: JSONSchemaValue) -> String {
    switch value {
    case .null:
        return "null"
    case .bool(let value):
        return value ? "true" : "false"
    case .integer(let value):
        return String(value)
    case .number(let value):
        return String(value)
    case .string(let value):
        return value
    case .array(let values):
        return "[\(values.map(stringify).joined(separator: ","))]"
    case .object(let values):
        let pairs = values.map { "\($0):\(stringify($1))" }.sorted()
        return "{\(pairs.joined(separator: ","))}"
    }
}
