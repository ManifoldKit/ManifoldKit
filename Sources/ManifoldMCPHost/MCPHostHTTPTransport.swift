#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import ManifoldInference
import Network
import os

/// Server-side **streamable-HTTP / SSE** transport for ``ManifoldMCPHost``
/// (issue #1842).
///
/// This is the transport shape Claude Desktop's *streamable-HTTP*
/// configuration and remote MCP clients use, and the server-side mirror of the
/// client transport in `ManifoldMCP` (`MCPStreamableHTTPTransport`). Where the
/// client opens an SSE stream and POSTs JSON-RPC requests, this transport plays
/// the other half:
///
/// - A client **GET** with `Accept: text/event-stream` opens a long-lived SSE
///   response channel. Server-originated JSON-RPC responses are written to it
///   as `data:`-framed Server-Sent Events.
/// - A client **POST** carries a JSON-RPC request body. The body is decoded by
///   ``ManifoldMCPHost`` exactly as it would be over stdio; the matching
///   response is delivered over the open SSE channel.
///
/// Instantiate, `start()`, then hand to ``ManifoldMCPHost/run(transport:)``:
///
/// ```swift
/// let transport = try MCPHostHTTPTransport(port: 8765)
/// try await transport.start()
/// try await host.run(transport: transport)
/// ```
///
/// ## Scope & limitations
///
/// - macOS only (not available on iOS or Catalyst), like the stdio transport.
/// - Binds `127.0.0.1` by default — loopback only. This is a local-first
///   surface; do not expose it to untrusted networks without front-loading
///   TLS + authentication (e.g. via a reverse proxy).
/// - The stdio transport remains the default for local single-client use; this
///   transport exists for streamable-HTTP clients that cannot launch the host
///   as a subprocess.
public actor MCPHostHTTPTransport: MCPHostTransport {

    // MARK: MCPHostTransport

    public nonisolated let incomingMessages: AsyncThrowingStream<Data, Error>

    // MARK: Private

    private let port: NWEndpoint.Port
    private let maxMessageBytes: Int
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    private var listener: NWListener?
    /// Open SSE response channels keyed by a per-connection id. A server
    /// response is fanned out to every open channel; a streamable-HTTP client
    /// keeps exactly one open, so in practice this is single-entry.
    private var sseChannels: [ObjectIdentifier: NWConnection] = [:]
    private var didStart = false

    // MARK: Init

    /// Creates a loopback HTTP/SSE transport.
    ///
    /// The listener always binds `127.0.0.1` (loopback only) via
    /// `NWParameters.requiredInterfaceType = .loopback`. Network.framework
    /// enforces this at the OS level — the transport is not reachable from
    /// other hosts regardless of the machine's network configuration.
    ///
    /// - Parameters:
    ///   - port: TCP port to bind. `0` binds an OS-assigned ephemeral port
    ///     (read back via ``boundPort``).
    ///   - maxMessageBytes: Hard cap on a single inbound request body.
    public init(
        port: UInt16,
        maxMessageBytes: Int = 4 * 1024 * 1024
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPHostTransportError.invalidPort(port)
        }
        self.port = nwPort
        self.maxMessageBytes = maxMessageBytes
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        self.incomingMessages = stream
        self.continuation = continuation
    }

    // MARK: Lifecycle

    /// Begins listening for connections. Idempotent — a second call is a no-op.
    public func start() async throws {
        guard didStart == false else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback-only by default. The bind host narrows the interface; this
        // flag additionally refuses connections routed in from other hosts.
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw MCPHostTransportError.listenFailed(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }

        // Surface a bind failure synchronously rather than letting the caller
        // believe the server is up.
        let ready = ReadyBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.resolve(.success(()))
            case .failed(let error):
                ready.resolve(.failure(MCPHostTransportError.listenFailed(error.localizedDescription)))
            case .cancelled:
                ready.resolve(.failure(MCPHostTransportError.listenFailed("listener cancelled")))
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        self.didStart = true

        do {
            try await ready.wait()
        } catch {
            self.shutdown()
            throw error
        }
    }

    /// The port the listener is actually bound to. Useful for tests that bind
    /// an ephemeral port (`port: 0`).
    public var boundPort: UInt16? {
        listener?.port?.rawValue
    }

    /// Tears down the listener, all open SSE channels, and finishes the stream.
    public func shutdown() {
        for (_, connection) in sseChannels {
            connection.cancel()
        }
        sseChannels.removeAll()
        listener?.cancel()
        listener = nil
        continuation.finish()
    }

    // MARK: MCPHostTransport.send

    /// Writes a JSON-RPC response payload to every open SSE channel as a
    /// `data:`-framed Server-Sent Event.
    ///
    /// Actor isolation serialises concurrent sends so writes to a channel never
    /// interleave across concurrent MCP responses.
    public func send(_ payload: Data) async throws {
        guard sseChannels.isEmpty == false else {
            // No open SSE stream — the streamable-HTTP client has not yet
            // (or has stopped) listening. Drop rather than buffer unbounded.
            Log.inference.debug("MCPHostHTTPTransport: dropping response — no open SSE channel")
            return
        }
        let frame = Self.sseFrame(payload)
        for (id, connection) in sseChannels {
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { await self?.removeChannel(id) }
                    Log.inference.debug("MCPHostHTTPTransport: SSE write failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection, accumulated: Data())
    }

    /// Reads bytes until a complete HTTP request (headers + any declared body)
    /// is buffered, then dispatches it.
    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            Task {
                await self.handleReceived(
                    data: data,
                    isComplete: isComplete,
                    error: error,
                    connection: connection,
                    accumulated: accumulated
                )
            }
        }
    }

    private func handleReceived(
        data: Data?,
        isComplete: Bool,
        error: NWError?,
        connection: NWConnection,
        accumulated: Data
    ) {
        if error != nil {
            connection.cancel()
            return
        }

        var buffer = accumulated
        if let data {
            buffer.append(data)
        }

        if buffer.count > maxMessageBytes {
            respondAndClose(connection, status: "413 Payload Too Large", body: "request too large")
            return
        }

        switch HTTPRequest.parse(buffer) {
        case .incomplete:
            if isComplete {
                // Client closed before sending a full request.
                connection.cancel()
                return
            }
            receiveRequest(on: connection, accumulated: buffer)
        case .invalid:
            respondAndClose(connection, status: "400 Bad Request", body: "malformed HTTP request")
        case .complete(let request):
            dispatch(request, on: connection)
        }
    }

    private func dispatch(_ request: HTTPRequest, on connection: NWConnection) {
        switch request.method {
        case "GET":
            openSSEChannel(on: connection)
        case "POST":
            handlePOST(request, on: connection)
        case "OPTIONS":
            // CORS / capability preflight — answer permissively for local use.
            respondAndClose(connection, status: "204 No Content", body: "")
        default:
            respondAndClose(connection, status: "405 Method Not Allowed", body: "unsupported method")
        }
    }

    private func openSSEChannel(on connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        let id = ObjectIdentifier(connection)
        sseChannels[id] = connection

        // Drop the channel when the peer closes.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { await self?.removeChannel(id) }
            default:
                break
            }
        }
        // Keep reading so the OS surfaces a peer FIN as a state change rather
        // than silently stalling; any body of a GET is ignored.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in }
    }

    private func handlePOST(_ request: HTTPRequest, on connection: NWConnection) {
        let body = request.body
        if body.count > maxMessageBytes {
            respondAndClose(connection, status: "413 Payload Too Large", body: "request too large")
            return
        }
        // Hand the JSON-RPC payload to the host's run loop. The matching
        // response is written back over the open SSE channel by `send(_:)`.
        continuation.yield(body)

        // Per the streamable-HTTP spec a POST may be answered with 202 Accepted
        // when the response is delivered out-of-band over the SSE stream.
        respondAndClose(connection, status: "202 Accepted", body: "")
    }

    private func removeChannel(_ id: ObjectIdentifier) {
        if let connection = sseChannels.removeValue(forKey: id) {
            connection.cancel()
        }
    }

    // MARK: HTTP helpers

    private func respondAndClose(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Frames a JSON-RPC payload as a single SSE event.
    ///
    /// SSE requires `data:` per line and a blank line to terminate the event.
    /// JSON-RPC payloads are single-line JSON, so one `data:` line suffices;
    /// embedded newlines (none expected from the codec) are split defensively.
    private static func sseFrame(_ payload: Data) -> Data {
        let text = String(decoding: payload, as: UTF8.self)
        var event = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            event += "data: \(line)\n"
        }
        event += "\n"
        return Data(event.utf8)
    }
}

// MARK: - ReadyBox

/// Bridges the listener's callback-driven `.ready`/`.failed` state into a
/// single `async` await. `@unchecked Sendable` is safe: the lock serialises the
/// one-shot resolve against the one waiter.
private final class ReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func resolve(_ value: Result<Void, Error>) {
        lock.lock()
        if result == nil {
            result = value
            let pending = continuation
            continuation = nil
            lock.unlock()
            if let pending {
                pending.resume(with: value)
            }
        } else {
            lock.unlock()
        }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(with: result)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}

// MARK: - HTTPRequest

/// Minimal HTTP/1.1 request parser: method, headers, and a `Content-Length`-
/// declared body. Sufficient for the JSON-RPC POST / SSE GET shapes this
/// transport serves; it is not a general-purpose HTTP server.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    private static let headerDelimiter = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data) -> ParseResult {
        guard let delimiterRange = buffer.range(of: headerDelimiter) else {
            return .incomplete
        }
        let headerData = buffer[..<delimiterRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .invalid
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = delimiterRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)

        let contentLength: Int
        if let raw = headers["content-length"], let value = Int(raw), value >= 0 {
            contentLength = value
        } else {
            contentLength = 0
        }

        guard available >= contentLength else {
            return .incomplete
        }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])

        return .complete(HTTPRequest(
            method: requestParts[0].uppercased(),
            path: requestParts[1],
            headers: headers,
            body: body
        ))
    }
}
#endif
