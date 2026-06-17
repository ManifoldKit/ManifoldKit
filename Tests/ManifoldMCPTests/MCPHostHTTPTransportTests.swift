#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Network
import XCTest
@testable import ManifoldMCP
@testable import ManifoldMCPHost
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

// MARK: - MCPHostHTTPTransportTests
//
// Integration tests for the server-side streamable-HTTP / SSE transport
// (issue #1842). They bind a real loopback listener on an ephemeral port and
// drive it with `URLSession` — the same shape a streamable-HTTP MCP client
// uses: open an SSE GET stream, POST a JSON-RPC request, read the response
// back as a `data:`-framed Server-Sent Event.

@MainActor
final class MCPHostHTTPTransportTests: XCTestCase {

    // MARK: Fixture

    private func makeHost(
        sessions: [ChatSession] = []
    ) -> ManifoldMCPHost {
        let sessionStore = InMemorySessionStore(sessions: sessions)
        let messageStore = InMemoryMessageStore()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let inferenceService = InferenceService(backend: backend)
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: inferenceService
        )
        return ManifoldMCPHost(
            sessionStore: sessionStore,
            messageStore: messageStore,
            conversationRuntime: runtime
        )
    }

    // MARK: ephemeral bind

    func test_start_bindsEphemeralPort() async throws {
        // Port 0 asks the OS for an ephemeral port; the transport must bind and
        // report a concrete non-zero bound port.
        let transport = try MCPHostHTTPTransport(port: 0)
        try await transport.start()
        defer { Task { await transport.shutdown() } }
        let bound = await transport.boundPort
        XCTAssertNotNil(bound)
        XCTAssertNotEqual(bound, 0)
    }

    // MARK: end-to-end initialize over HTTP/SSE

    func test_initialize_roundTripsOverHTTPSSE() async throws {
        let host = await makeHost()
        let transport = try MCPHostHTTPTransport(port: 0)
        try await transport.start()
        guard let port = await transport.boundPort else {
            XCTFail("transport did not bind a port")
            return
        }

        let runTask = Task { try await host.run(transport: transport) }
        defer {
            runTask.cancel()
            Task { await transport.shutdown() }
        }

        // 1. Open the SSE response channel (raw socket GET). We drive raw HTTP
        //    over an `NWConnection` rather than `URLSession` because URLSession's
        //    streaming-response buffering is non-deterministic for a never-
        //    closing SSE GET; the raw client mirrors what a streamable-HTTP MCP
        //    client (or `curl -N`) does on the wire.
        let sse = RawSocketClient(port: port)
        try await sse.connect()
        try await sse.write(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n".utf8))

        // Wait for the SSE 200 header so the channel is registered server-side
        // before we POST.
        let sseHeader = try await sse.readUntilConsuming(substring: "\r\n\r\n", timeout: .seconds(3))
        XCTAssertTrue(sseHeader.contains("200 OK"), "SSE GET should return 200; got: \(sseHeader)")
        XCTAssertTrue(sseHeader.lowercased().contains("text/event-stream"))

        // 2. POST a JSON-RPC initialize request on a second socket.
        let codec = MCPJSONRPCCodec(maxMessageBytes: 512 * 1024, maxJSONNestingDepth: 32)
        let request = MCPJSONRPCMessage.request(
            id: .int(1),
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-03-26")])
        )
        let payload = try codec.encode(request)

        let post = RawSocketClient(port: port)
        try await post.connect()
        var postBytes = Data("POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
        postBytes.append(payload)
        try await post.write(postBytes)
        let postResponse = try await post.readUntilConsuming(substring: "\r\n\r\n", timeout: .seconds(3))
        XCTAssertTrue(postResponse.contains("202"), "POST should be accepted with 202; got: \(postResponse)")

        // 3. The JSON-RPC response should arrive over the SSE channel as a
        //    `data:`-framed event terminated by a blank line. The header has
        //    already been consumed, so the buffer now holds only the event.
        let event = try await sse.readUntilConsuming(substring: "\n\n", timeout: .seconds(5))
        guard let dataLine = event.split(separator: "\n").first(where: { $0.hasPrefix("data:") }) else {
            XCTFail("no data: line in SSE event: \(event)")
            return
        }
        let json = dataLine.dropFirst("data:".count).drop(while: { $0 == " " })
        let decoded = try codec.decode(Data(String(json).utf8))
        guard case .result(let id, let result) = decoded else {
            XCTFail("expected a result frame over SSE, got \(decoded)")
            return
        }
        XCTAssertEqual(id, .int(1))
        guard case .object(let r) = result,
              case .string(let version) = r["protocolVersion"] else {
            XCTFail("expected initialize result with protocolVersion")
            return
        }
        XCTAssertEqual(version, "2025-03-26")

        await sse.close()
        await post.close()
    }

    // MARK: unsupported method

    func test_unsupportedHTTPMethod_returns405() async throws {
        let transport = try MCPHostHTTPTransport(port: 0)
        try await transport.start()
        guard let port = await transport.boundPort else {
            XCTFail("transport did not bind a port")
            return
        }
        defer { Task { await transport.shutdown() } }

        let client = RawSocketClient(port: port)
        try await client.connect()
        try await client.write(Data("DELETE / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        let response = try await client.readUntilConsuming(substring: "\r\n\r\n", timeout: .seconds(3))
        XCTAssertTrue(response.contains("405"), "expected 405; got: \(response)")
        await client.close()
    }
}

// MARK: - RawSocketClient

/// A minimal loopback TCP client over `NWConnection` for driving the HTTP/SSE
/// transport deterministically in tests. Reads accumulate into a buffer that
/// `readUntil` scans for a delimiter, with a wall-clock ceiling so a missing
/// response fails fast instead of hanging CI.
private actor RawSocketClient {
    private let connection: NWConnection
    private var buffer = Data()
    private var receiving = false

    enum SocketError: Error { case timeout, closed, connectFailed(String) }

    init(port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        self.connection = NWConnection(to: endpoint, using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                    self.connection.stateUpdateHandler = nil
                case .failed(let error):
                    cont.resume(throwing: SocketError.connectFailed(error.localizedDescription))
                    self.connection.stateUpdateHandler = nil
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        startReceiving()
    }

    private func startReceiving() {
        guard receiving == false else { return }
        receiving = true
        pump()
    }

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            Task { await self.absorb(data: data, isComplete: isComplete) }
        }
    }

    private func absorb(data: Data?, isComplete: Bool) {
        if let data { buffer.append(data) }
        if isComplete == false { pump() }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Polls the receive buffer until `substring` appears, then returns the
    /// portion up to and including the delimiter and removes it from the buffer
    /// (so a subsequent read sees only later bytes). Throws `.timeout` if the
    /// delimiter never arrives.
    func readUntilConsuming(substring: String, timeout: Duration) async throws -> String {
        let needle = Data(substring.utf8)
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let range = buffer.range(of: needle) {
                let consumed = buffer[..<range.upperBound]
                let text = String(decoding: consumed, as: UTF8.self)
                buffer.removeSubrange(..<range.upperBound)
                return text
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SocketError.timeout
    }

    func close() {
        connection.cancel()
    }
}

// MARK: - In-memory stores

@MainActor
private final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private var sessions: [ChatSession]
    init(sessions: [ChatSession] = []) { self.sessions = sessions }
    func insertSession(_ session: ChatSession) async throws { sessions.append(session) }
    func updateSession(_ session: ChatSession) async throws {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else {
            throw ChatPersistenceError.sessionNotFound(session.id)
        }
        sessions[idx] = session
    }
    func deleteSession(_ sessionID: UUID) async throws { sessions.removeAll { $0.id == sessionID } }
    func fetchSessions() async throws -> [ChatSession] { sessions }
}

@MainActor
private final class InMemoryMessageStore: MessageStore, @unchecked Sendable {
    private var messages: [ChatMessage] = []
    func insertMessage(_ message: ChatMessage) async throws { messages.append(message) }
    func updateMessage(_ message: ChatMessage) async throws {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else {
            throw ChatPersistenceError.messageNotFound(message.id)
        }
        messages[idx] = message
    }
    func deleteMessage(_ messageID: UUID) async throws { messages.removeAll { $0.id == messageID } }
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        messages.filter { $0.sessionID == sessionID }
    }
    func deleteMessages(for sessionID: UUID) async throws { messages.removeAll { $0.sessionID == sessionID } }
}
#endif
