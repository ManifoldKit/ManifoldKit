import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference

final class MCPSessionTests: XCTestCase {
    func test_startNegotiatesInitializeAndSendsInitializedNotification() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Session Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSessionTransport(codec: codec)

        await transport.setRequestHandler { id, method, _ in
            guard method == "initialize" else { return nil }
            return .result(id: id, result: .object([
                "protocolVersion": .string("2025-03-26"),
                "serverInfo": .object([
                    "name": .string("Demo MCP"),
                    "version": .string("1.2.3"),
                ]),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(false)]),
                    "resources": .object([:]),
                ]),
            ]))
        }

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .seconds(2),
            maxConcurrentRequests: 4
        )

        let capabilities = try await session.start()
        XCTAssertEqual(capabilities.serverName, "Demo MCP")
        XCTAssertEqual(capabilities.serverVersion, "1.2.3")
        XCTAssertFalse(capabilities.supportsToolListChanged)
        XCTAssertTrue(capabilities.supportsResources)

        let sent = await transport.sentMessages()
        XCTAssertTrue(sent.contains { message in
            if case .request(_, let method, _) = message {
                return method == "initialize"
            }
            return false
        })
        XCTAssertTrue(sent.contains { message in
            if case .notification(let method, _) = message {
                return method == "notifications/initialized"
            }
            return false
        })
        // Sabotage: removing the MCPSession.start() call that sends "notifications/initialized" after receiving the initialize result would cause the sent.contains notification check to fail

        await session.close()
    }

    func test_sendRequestResolvesPendingResponse() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Session Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSessionTransport(codec: codec)
        await transport.setRequestHandler { id, method, _ in
            switch method {
            case "initialize":
                return .result(id: id, result: .object([
                    "protocolVersion": .string("2025-03-26"),
                    "serverInfo": .object(["name": .string("Demo"), "version": .string("1")]),
                    "capabilities": .object([:]),
                ]))
            case "tools/list":
                return .result(id: id, result: .object([
                    "tools": .array([.object(["name": .string("search")])]),
                ]))
            default:
                return nil
            }
        }

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .seconds(2),
            maxConcurrentRequests: 4
        )

        _ = try await session.start()
        let response = try await session.sendRequest(method: "tools/list", params: nil)

        guard case .object(let object)? = response,
              case .array(let tools)? = object["tools"] else {
            XCTFail("Expected tools list result")
            return
        }

        XCTAssertEqual(tools.count, 1)
        // Sabotage: changing MCPSession.handleIncoming() to never remove the pending-request continuation from pendingRequests would leave the response undelivered and hang this await, timing out the test

        await session.close()
    }

    func test_sendRequestThreadsMcpRoutingHeadersForToolCall() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Routing Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSessionTransport(codec: codec)
        await transport.setRequestHandler { id, method, _ in
            switch method {
            case "initialize":
                return .result(id: id, result: .object([
                    "protocolVersion": .string("2025-03-26"),
                    "serverInfo": .object(["name": .string("Demo"), "version": .string("1")]),
                    "capabilities": .object([:]),
                ]))
            case "tools/call":
                return .result(id: id, result: .object(["content": .array([])]))
            default:
                return nil
            }
        }

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .seconds(2),
            maxConcurrentRequests: 4
        )

        _ = try await session.start()
        _ = try await session.sendRequest(
            method: "tools/call",
            params: .object(["name": .string("search"), "arguments": .object([:])])
        )

        let routing = await transport.sentRoutingMetadata()
        // The first send is the `initialized` notification from start(); the tools/call
        // request is the one carrying a tool name.
        let toolCallRouting = routing.compactMap { $0 }.first { $0.method == "tools/call" }
        XCTAssertEqual(toolCallRouting?.method, "tools/call", "Mcp-Method must carry the JSON-RPC method")
        XCTAssertEqual(toolCallRouting?.name, "search", "Mcp-Name must carry the tools/call tool name")

        // A non-tools/call method carries a method but no name.
        let initializeRouting = routing.compactMap { $0 }.first { $0.method == "initialize" }
        XCTAssertEqual(initializeRouting?.method, "initialize")
        XCTAssertNil(initializeRouting?.name, "Mcp-Name must be absent for methods without an invocation target")
        // Sabotage: dropping `routing:` from the transport.send call in MCPSession.registerPendingAndSend (passing the no-routing default) makes toolCallRouting nil, failing the method/name assertions above.

        await session.close()
    }

    func test_sendRequestPropagatesJSONRPCError() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Session Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSessionTransport(codec: codec)
        await transport.setRequestHandler { id, method, _ in
            switch method {
            case "initialize":
                return .result(id: id, result: .object([
                    "protocolVersion": .string("2025-03-26"),
                    "serverInfo": .object(["name": .string("Demo"), "version": .string("1")]),
                    "capabilities": .object([:]),
                ]))
            case "tools/list":
                return .error(
                    id: id,
                    error: MCPJSONRPCErrorObject(
                        code: -32001,
                        message: "upstream failed",
                        data: .object(["retryable": .bool(false)])
                    )
                )
            default:
                return nil
            }
        }

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .seconds(2),
            maxConcurrentRequests: 4
        )

        _ = try await session.start()

        do {
            _ = try await session.sendRequest(method: "tools/list", params: nil)
            XCTFail("Expected protocolError")
        } catch let error as MCPError {
            XCTAssertEqual(error, .protocolError(code: -32001, message: "upstream failed", data: "{retryable:false}"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // Sabotage: changing MCPSession.handleIncoming() to resume the pending continuation with .success instead of .failure when a JSON-RPC error response is received would skip the catch block and hit XCTFail("Expected protocolError")

        await session.close()
    }

    func test_startThrowsUnsupportedProtocolVersion() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Session Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSessionTransport(codec: codec)
        await transport.setRequestHandler { id, method, _ in
            guard method == "initialize" else { return nil }
            return .result(id: id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "serverInfo": .object(["name": .string("Demo"), "version": .string("1")]),
                "capabilities": .object([:]),
            ]))
        }

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .seconds(2),
            maxConcurrentRequests: 4
        )

        do {
            _ = try await session.start()
            XCTFail("Expected unsupportedProtocolVersion")
        } catch let error as MCPError {
            XCTAssertEqual(error, .unsupportedProtocolVersion(server: "2024-11-05", client: "2025-03-26"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // Sabotage: removing the protocolVersion equality check in MCPSession.start() that compares the server's reported version against "2025-03-26" would allow the unsupported "2024-11-05" version through without throwing, reaching XCTFail("Expected unsupportedProtocolVersion")

        await session.close()
    }

    // #1622: a request whose id is never answered must, on timeout, evict its
    // pending entry (reclaiming the concurrency slot) and send
    // notifications/cancelled. Previously the timeout resumed the outer
    // continuation but leaked both the inner continuation and the slot, so after
    // `maxConcurrentRequests` such events every sendRequest threw
    // "Exceeded max concurrent" until reconnect.
    func test_sendRequestTimeoutReleasesSlotAndNotifiesCancelled() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Session Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSessionTransport(codec: codec)
        await transport.setRequestHandler { id, method, _ in
            switch method {
            case "initialize":
                return .result(id: id, result: .object([
                    "protocolVersion": .string("2025-03-26"),
                    "serverInfo": .object(["name": .string("Demo"), "version": .string("1")]),
                    "capabilities": .object([:]),
                ]))
            default:
                // Never answer tools/list — force the timeout path.
                return nil
            }
        }

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .milliseconds(150),
            maxConcurrentRequests: 1
        )
        _ = try await session.start()

        do {
            _ = try await session.sendRequest(method: "tools/list", params: nil)
            XCTFail("Expected requestTimeout")
        } catch let error as MCPError {
            XCTAssertEqual(error, .requestTimeout)
        }

        // The slot must have been reclaimed. With maxConcurrentRequests == 1, a
        // leaked slot would make this throw .transportFailure instead of timing
        // out again.
        do {
            _ = try await session.sendRequest(method: "tools/list", params: nil)
            XCTFail("Expected requestTimeout on the second request")
        } catch let error as MCPError {
            XCTAssertEqual(error, .requestTimeout,
                           "Pending slot leaked: second request hit max-concurrency instead of timing out")
        }

        let sent = await transport.sentMessages()
        XCTAssertTrue(sent.contains { message in
            if case .notification(let method, _) = message {
                return method == "notifications/cancelled"
            }
            return false
        }, "Timeout path must send notifications/cancelled so the server stops working on the abandoned call")
        // Sabotage: removing the failPendingRequest(id:) call in handleRequestTimeout would leak the slot, making the second request throw .transportFailure and failing the equality assertion above.

        await session.close()
    }

    // The initialize handshake must be bounded by `descriptor.initializationTimeout`,
    // not the session's steady-state `requestTimeout`. A server that starts its
    // transport but never answers `initialize` should fail fast on the short
    // initialization budget even when the request timeout is long.
    func test_startBoundsInitializeByInitializationTimeout() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Init Timeout",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            initializationTimeout: .milliseconds(150),
            dataDisclosure: "test"
        )

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSessionTransport(codec: codec)
        // Never answer initialize — force the initialization-timeout path.
        await transport.setRequestHandler { _, _, _ in nil }

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .seconds(10),
            maxConcurrentRequests: 4
        )

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await session.start()
            XCTFail("Expected requestTimeout from the initialize handshake")
        } catch let error as MCPError {
            XCTAssertEqual(error, .requestTimeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let elapsed = clock.now - started

        // The 150ms initialization budget must win, not the 10s request timeout.
        // A generous 3s ceiling keeps CI stable while still proving the wrong
        // timeout (10s) was not used.
        XCTAssertLessThan(
            elapsed, .seconds(3),
            "initialize must time out on initializationTimeout (150ms), not requestTimeout (10s)"
        )
        // Sabotage: reverting MCPSession.start() to pass no `timeout:` to the initialize
        // sendRequest (falling back to requestTimeout) makes this take ~10s, blowing the
        // 3s ceiling above.

        await session.close()
    }

    func test_sendRequestEnforcesMaxConcurrentRequests() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Session Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSessionTransport(codec: codec)
        await transport.setRequestHandler { id, method, _ in
            switch method {
            case "initialize":
                return .result(id: id, result: .object([
                    "protocolVersion": .string("2025-03-26"),
                    "serverInfo": .object(["name": .string("Demo"), "version": .string("1")]),
                    "capabilities": .object([:]),
                ]))
            case "tools/list":
                return nil
            default:
                return nil
            }
        }

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .milliseconds(200),
            maxConcurrentRequests: 1
        )
        _ = try await session.start()

        let firstRequest = Task {
            try await session.sendRequest(method: "tools/list", params: nil)
        }
        try await Task.sleep(for: .milliseconds(50))

        do {
            _ = try await session.sendRequest(method: "tools/list", params: nil)
            XCTFail("Expected max-concurrency transport failure")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportFailure("Exceeded max concurrent MCP requests"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // Sabotage: removing the concurrency semaphore guard in MCPSession.sendRequest() so it never checks maxConcurrentRequests would allow the second request to proceed instead of throwing .transportFailure("Exceeded max concurrent MCP requests"), reaching XCTFail("Expected max-concurrency transport failure")

        firstRequest.cancel()
        await session.close()
    }
}

private actor MockSessionTransport: MCPTransport {
    nonisolated let incomingMessages: AsyncThrowingStream<Data, Error>

    private let codec: MCPJSONRPCCodec
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var handler: (@Sendable (MCPRequestID, String, JSONSchemaValue?) -> MCPJSONRPCMessage?)?
    private var sent: [MCPJSONRPCMessage] = []
    private var sentRouting: [MCPRouting?] = []

    init(codec: MCPJSONRPCCodec) {
        self.codec = codec
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.incomingMessages = AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func setRequestHandler(_ handler: @escaping @Sendable (MCPRequestID, String, JSONSchemaValue?) -> MCPJSONRPCMessage?) {
        self.handler = handler
    }

    func start() async throws {}

    func send(_ payload: Data, routing: MCPRouting?) async throws {
        let message = try codec.decode(payload)
        sent.append(message)
        sentRouting.append(routing)

        guard case .request(let id, let method, let params) = message,
              let handler else {
            return
        }

        if let response = handler(id, method, params) {
            continuation.yield(try codec.encode(response))
        }
    }

    func close() async {
        continuation.finish()
    }

    func sentMessages() -> [MCPJSONRPCMessage] {
        sent
    }

    func sentRoutingMetadata() -> [MCPRouting?] {
        sentRouting
    }
}
