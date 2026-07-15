import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference

/// Covers #1925: server-initiated `sampling/createMessage` requests routed through
/// the injected `serverRequestHandler` seam on `MCPSession`, plus the
/// `MCPSamplingRequest`/`MCPSamplingResult` wire conversions that
/// `MCPClient.makeServerRequestHandler` uses to bridge to the host closure.
final class MCPSamplingTests: XCTestCase {
    // MARK: - Capability negotiation

    func test_initializeAdvertisesSamplingWhenHandlerConfigured() async throws {
        let (session, transport) = try await makeSession(withHandler: { _, _ in .success(.object([:])) })
        _ = try await session.start()

        let initializeParams = await transport.sentRequestParams(forMethod: "initialize")
        guard case .object(let object)? = initializeParams,
              case .object(let capabilities)? = object["capabilities"] else {
            XCTFail("Expected initialize params with a capabilities object")
            return
        }
        XCTAssertNotNil(capabilities["sampling"], "sampling capability must be advertised when a handler is configured")
        // Sabotage: hardcoding clientCapabilities to .object([:]) regardless of serverRequestHandler
        // in MCPSession.start() would make capabilities["sampling"] nil, failing this assertion.

        await session.close()
    }

    func test_initializeOmitsSamplingWhenNoHandlerConfigured() async throws {
        let (session, transport) = try await makeSession(withHandler: nil)
        _ = try await session.start()

        let initializeParams = await transport.sentRequestParams(forMethod: "initialize")
        guard case .object(let object)? = initializeParams,
              case .object(let capabilities)? = object["capabilities"] else {
            XCTFail("Expected initialize params with a capabilities object")
            return
        }
        XCTAssertNil(capabilities["sampling"], "sampling capability must not be advertised with no handler configured")

        await session.close()
    }

    // MARK: - Request dispatch

    func test_serverRequestDispatchesToHandlerAndRepliesWithResult() async throws {
        let expectedResult: JSONSchemaValue = .object([
            "role": .string("assistant"),
            "content": .object(["type": .string("text"), "text": .string("hi")]),
            "model": .string("test-model"),
        ])
        let (session, transport) = try await makeSession(withHandler: { method, _ in
            guard method == "sampling/createMessage" else {
                return .failure(MCPJSONRPCErrorObject(code: -32601, message: "Method not found", data: nil))
            }
            return .success(expectedResult)
        })
        _ = try await session.start()

        try await transport.injectRequest(id: .int(100), method: "sampling/createMessage", params: .object([
            "messages": .array([
                .object(["role": .string("user"), "content": .object(["type": .string("text"), "text": .string("hello")])]),
            ]),
        ]))

        let reply = try await transport.awaitReply(forID: .int(100))
        guard case .result(_, let result) = reply else {
            XCTFail("Expected a .result reply, got \(reply)")
            return
        }
        XCTAssertEqual(result, expectedResult)
        // Sabotage: making InternalMCPSession.handleIncoming() `return` on `.request` again
        // (dropping it instead of dispatching to handleServerRequest) would leave this
        // awaitReply call waiting until it times out and fails.

        await session.close()
    }

    func test_serverRequestRepliesWithErrorWhenHandlerFails() async throws {
        let (session, transport) = try await makeSession(withHandler: { _, _ in
            .failure(MCPJSONRPCErrorObject(code: -32800, message: "Request cancelled", data: nil))
        })
        _ = try await session.start()

        try await transport.injectRequest(id: .int(101), method: "sampling/createMessage", params: nil)

        let reply = try await transport.awaitReply(forID: .int(101))
        guard case .error(_, let error) = reply else {
            XCTFail("Expected a .error reply, got \(reply)")
            return
        }
        XCTAssertEqual(error.code, -32800)
        XCTAssertEqual(error.message, "Request cancelled")

        await session.close()
    }

    func test_serverRequestRepliesMethodNotFoundWithNoHandlerConfigured() async throws {
        let (session, transport) = try await makeSession(withHandler: nil)
        _ = try await session.start()

        try await transport.injectRequest(id: .int(102), method: "sampling/createMessage", params: nil)

        let reply = try await transport.awaitReply(forID: .int(102))
        guard case .error(_, let error) = reply else {
            XCTFail("Expected a .error reply, got \(reply)")
            return
        }
        XCTAssertEqual(error.code, -32601)
        // Sabotage: replying with .success instead of a JSON-RPC error when serverRequestHandler
        // is nil would turn this into a .result case, failing the guard above.

        await session.close()
    }

    // MARK: - MCPSamplingRequest / MCPSamplingResult wire conversion

    func test_samplingRequestParsesMessagesAndOptionalFields() throws {
        let params: JSONSchemaValue = .object([
            "messages": .array([
                .object(["role": .string("user"), "content": .object(["type": .string("text"), "text": .string("hi")])]),
            ]),
            "systemPrompt": .string("be terse"),
            "maxTokens": .integer(256),
            "temperature": .number(0.5),
            "stopSequences": .array([.string("STOP")]),
            "modelPreferences": .object([
                "hints": .array([.object(["name": .string("claude-3")])]),
                "speedPriority": .number(0.9),
            ]),
        ])

        let request = try MCPSamplingRequest(params: params)
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages[0].role, .user)
        XCTAssertEqual(request.messages[0].content, .text("hi"))
        XCTAssertEqual(request.systemPrompt, "be terse")
        XCTAssertEqual(request.maxTokens, 256)
        XCTAssertEqual(request.temperature, 0.5)
        XCTAssertEqual(request.stopSequences, ["STOP"])
        XCTAssertEqual(request.modelPreferences?.hintNames, ["claude-3"])
        XCTAssertEqual(request.modelPreferences?.speedPriority, 0.9)
    }

    func test_samplingRequestThrowsOnMissingMessages() {
        XCTAssertThrowsError(try MCPSamplingRequest(params: .object([:])))
    }

    func test_samplingResultEncodesToExpectedJSONRPCShape() {
        let result = MCPSamplingResult(
            role: .assistant,
            content: .text("done"),
            model: "test-model",
            stopReason: "endTurn"
        )
        guard case .object(let object) = result.jsonRPCResult else {
            XCTFail("Expected object result")
            return
        }
        XCTAssertEqual(object["role"], .string("assistant"))
        XCTAssertEqual(object["model"], .string("test-model"))
        XCTAssertEqual(object["stopReason"], .string("endTurn"))
        XCTAssertEqual(object["content"], .object(["type": .string("text"), "text": .string("done")]))
    }

    // MARK: - Test support

    private func makeSession(
        withHandler handler: MCPServerRequestHandler?
    ) async throws -> (MCPSession, MockSamplingTransport) {
        let descriptor = MCPServerDescriptor(
            displayName: "Sampling Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )
        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockSamplingTransport(codec: codec)
        await transport.setInitializeResult(.object([
            "protocolVersion": .string("2025-03-26"),
            "serverInfo": .object(["name": .string("Demo"), "version": .string("1")]),
            "capabilities": .object([:]),
        ]))

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .seconds(2),
            maxConcurrentRequests: 4,
            serverRequestHandler: handler
        )
        return (session, transport)
    }
}

/// A fake `MCPTransport` that auto-answers `initialize` and lets tests inject arbitrary
/// server-initiated `.request` frames directly into `incomingMessages`, then read back
/// whatever the session sent in response.
private actor MockSamplingTransport: MCPTransport {
    nonisolated let incomingMessages: AsyncThrowingStream<Data, Error>

    private let codec: MCPJSONRPCCodec
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var initializeResult: JSONSchemaValue?
    private var sent: [MCPJSONRPCMessage] = []

    init(codec: MCPJSONRPCCodec) {
        self.codec = codec
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.incomingMessages = AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func setInitializeResult(_ result: JSONSchemaValue) {
        initializeResult = result
    }

    func start() async throws {}

    func send(_ payload: Data, routing: MCPRouting?) async throws {
        let message = try codec.decode(payload)
        sent.append(message)

        if case .request(let id, "initialize", _) = message, let initializeResult {
            continuation.yield(try codec.encode(.result(id: id, result: initializeResult)))
        }
    }

    func close() async {
        continuation.finish()
    }

    /// Pushes a server-initiated request frame directly into the session's receive loop.
    func injectRequest(id: MCPRequestID, method: String, params: JSONSchemaValue?) throws {
        let frame = MCPJSONRPCMessage.request(id: id, method: method, params: params)
        continuation.yield(try codec.encode(frame))
    }

    func sentRequestParams(forMethod method: String) -> JSONSchemaValue? {
        for message in sent {
            if case .request(_, method, let params) = message {
                return params
            }
        }
        return nil
    }

    func awaitReply(forID id: MCPRequestID) async throws -> MCPJSONRPCMessage {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            for message in sent {
                switch message {
                case .result(let replyID, _) where replyID == id:
                    return message
                case .error(let replyID, _) where replyID == id:
                    return message
                default:
                    continue
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MCPError.requestTimeout
    }
}
