#if MCP
import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatInference

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

    func send(_ payload: Data) async throws {
        let message = try codec.decode(payload)
        sent.append(message)

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
}
#endif
