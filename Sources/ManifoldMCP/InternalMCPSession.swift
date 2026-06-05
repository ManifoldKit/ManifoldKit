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

internal actor MCPSession {
    private let descriptor: MCPServerDescriptor
    private let transport: any MCPTransport
    private let codec: MCPJSONRPCCodec
    private let requestTimeout: Duration
    private let maxConcurrentRequests: Int
    private let stateHook: any MCPSessionStateHook

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
        stateHook: any MCPSessionStateHook = MCPNoopSessionStateHook()
    ) {
        self.descriptor = descriptor
        self.transport = transport
        self.codec = codec
        self.requestTimeout = requestTimeout
        self.maxConcurrentRequests = maxConcurrentRequests
        self.stateHook = stateHook
    }

    func start() async throws -> MCPCapabilities {
        guard state == .idle else {
            throw MCPError.transportFailure("Session already started")
        }

        state = .connecting
        await stateHook.sessionDidTransition(.connecting)
        try await transport.start()
        startReceiveLoop()

        let initializeParams: JSONSchemaValue = .object([
            "protocolVersion": .string("2025-03-26"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(ManifoldConfiguration.shared.appName),
                "version": .string("1.0.0"),
            ]),
        ])

        let response = try await sendRequest(method: "initialize", params: initializeParams)
        let capabilities = try parseInitializeResponse(response)
        try await sendNotification(method: "notifications/initialized", params: nil)

        state = .ready
        await stateHook.sessionDidTransition(.ready)
        return capabilities
    }

    func sendRequest(method: String, params: JSONSchemaValue?) async throws -> JSONSchemaValue? {
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
            try await withTimeout(requestTimeout, onTimeout: { [self] in
                // Remove the pending slot and resume its continuation so the operation
                // task completes and the concurrency slot is freed. Without this the
                // slot leaks permanently — a server that accepts but never answers the
                // request ID would exhaust maxConcurrentRequests after enough timeouts.
                let cancelParams: JSONSchemaValue = .object([
                    "requestId": .string(id.description),
                    "reason": .string("Request timeout"),
                ])
                await sendNotificationIgnoringErrors(method: "notifications/cancelled", params: cancelParams)
                await timeoutPendingRequest(id: id)
            }) { [self] in
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
        try await transport.send(payload)
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
            try await transport.send(payload)
        } catch {
            Log.inference.error("MCPSession: failed to send notification '\(method, privacy: .public)': \(error, privacy: .private)")
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
        case .request, .notification:
            return
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

    // async bridge so @Sendable closures outside the actor can call into the isolated
    // failPendingRequest without violating Swift 6 synchronous-actor-method rules.
    private func timeoutPendingRequest(id: MCPRequestID) async {
        failPendingRequest(id: id, error: MCPError.requestTimeout)
    }

    private func registerPendingAndSend(
        id: MCPRequestID,
        request: MCPJSONRPCMessage,
        payload: Data,
        continuation: CheckedContinuation<JSONSchemaValue?, Error>
    ) async {
        pendingRequests[id] = continuation
        do {
            try await transport.send(payload)
            await stateHook.sessionDidSend(request)
        } catch {
            failPendingRequest(id: id, error: error)
        }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        onTimeout: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Use unstructured tasks so the timeout race doesn't wait for the operation
        // task to drain. withThrowingTaskGroup waits for ALL child tasks on exit;
        // if the operation is suspended in withCheckedThrowingContinuation (awaiting
        // a server response that never arrives), Swift 6.2 does not automatically
        // resume it with CancellationError, causing an indefinite hang.
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            func tryResume(_ body: @Sendable () -> Void) {
                let shouldResume = resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                if shouldResume { body() }
            }

            let opTask = Task {
                do {
                    let value = try await operation()
                    tryResume { continuation.resume(returning: value) }
                } catch {
                    tryResume { continuation.resume(throwing: error) }
                }
            }

            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return  // sleep was cancelled — operation completed first
                }
                // Cancel the operation task and run the timeout callback before resuming
                // the outer continuation. The callback is responsible for evicting the
                // pending-request entry and resuming its inner continuation so the
                // operation task can unblock and the concurrency slot is freed.
                opTask.cancel()
                if let onTimeout { await onTimeout() }
                tryResume { continuation.resume(throwing: MCPError.requestTimeout) }
            }
        }
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
