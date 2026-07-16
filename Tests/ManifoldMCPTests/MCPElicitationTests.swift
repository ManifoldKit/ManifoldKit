import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference

/// Covers #1926: server-initiated `elicitation/create` requests routed through the
/// injected `serverRequestHandler` seam on `MCPSession`, plus the
/// `MCPElicitationRequest`/`MCPElicitationResult` wire conversions that
/// `MCPClient.makeServerRequestHandler` uses to bridge to the host closure. Mirrors
/// `MCPSamplingTests` (#1925), which shares the same routing seam.
final class MCPElicitationTests: XCTestCase {
    // MARK: - Capability negotiation

    func test_initializeAdvertisesElicitationWhenHandlerConfigured() async throws {
        let (session, transport) = try await makeSession(
            withHandler: { _, _ in .success(.object(["action": .string("accept")])) },
            advertisesElicitation: true
        )
        _ = try await session.start()

        let initializeParams = await transport.sentRequestParams(forMethod: "initialize")
        guard case .object(let object)? = initializeParams,
              case .object(let capabilities)? = object["capabilities"] else {
            XCTFail("Expected initialize params with a capabilities object")
            return
        }
        XCTAssertNotNil(capabilities["elicitation"], "elicitation capability must be advertised when a handler is configured")
        // Sabotage: hardcoding clientCapabilities in MCPSession.start() to ignore
        // advertisesElicitation would make capabilities["elicitation"] nil, failing
        // this assertion.

        await session.close()
    }

    func test_initializeOmitsElicitationWhenNoHandlerConfigured() async throws {
        let (session, transport) = try await makeSession(withHandler: nil, advertisesElicitation: false)
        _ = try await session.start()

        let initializeParams = await transport.sentRequestParams(forMethod: "initialize")
        guard case .object(let object)? = initializeParams,
              case .object(let capabilities)? = object["capabilities"] else {
            XCTFail("Expected initialize params with a capabilities object")
            return
        }
        XCTAssertNil(capabilities["elicitation"], "elicitation capability must not be advertised with no handler configured")

        await session.close()
    }

    /// #1926 generalization: elicitation and sampling are advertised independently —
    /// a session configured only for elicitation must not also claim `sampling`.
    func test_initializeDoesNotAdvertiseSamplingWhenOnlyElicitationConfigured() async throws {
        let (session, transport) = try await makeSession(
            withHandler: { _, _ in .success(.object(["action": .string("accept")])) },
            advertisesElicitation: true,
            advertisesSampling: false
        )
        _ = try await session.start()

        let initializeParams = await transport.sentRequestParams(forMethod: "initialize")
        guard case .object(let object)? = initializeParams,
              case .object(let capabilities)? = object["capabilities"] else {
            XCTFail("Expected initialize params with a capabilities object")
            return
        }
        XCTAssertNotNil(capabilities["elicitation"])
        XCTAssertNil(capabilities["sampling"], "sampling must not be advertised when only elicitation is configured")

        await session.close()
    }

    // MARK: - Request dispatch

    func test_serverRequestDispatchesToHandlerAndRepliesWithResult() async throws {
        let expectedResult: JSONSchemaValue = .object([
            "action": .string("accept"),
            "content": .object(["name": .string("Rory")]),
        ])
        let (session, transport) = try await makeSession(
            withHandler: { method, _ in
                guard method == "elicitation/create" else {
                    return .failure(MCPJSONRPCErrorObject(code: -32601, message: "Method not found", data: nil))
                }
                return .success(expectedResult)
            },
            advertisesElicitation: true
        )
        _ = try await session.start()

        try await transport.injectRequest(id: .int(200), method: "elicitation/create", params: .object([
            "message": .string("What is your name?"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object(["name": .object(["type": .string("string")])]),
            ]),
        ]))

        let reply = try await transport.awaitReply(forID: .int(200))
        guard case .result(_, let result) = reply else {
            XCTFail("Expected a .result reply, got \(reply)")
            return
        }
        XCTAssertEqual(result, expectedResult)
        // Sabotage: making InternalMCPSession.handleIncoming() `return` on `.request`
        // again (dropping it instead of dispatching to handleServerRequest) would
        // leave this awaitReply call waiting until it times out and fails.

        await session.close()
    }

    func test_serverRequestRepliesWithErrorWhenHandlerFails() async throws {
        let (session, transport) = try await makeSession(
            withHandler: { _, _ in
                .failure(MCPJSONRPCErrorObject(code: -32800, message: "Request cancelled", data: nil))
            },
            advertisesElicitation: true
        )
        _ = try await session.start()

        try await transport.injectRequest(id: .int(201), method: "elicitation/create", params: nil)

        let reply = try await transport.awaitReply(forID: .int(201))
        guard case .error(_, let error) = reply else {
            XCTFail("Expected a .error reply, got \(reply)")
            return
        }
        XCTAssertEqual(error.code, -32800)
        XCTAssertEqual(error.message, "Request cancelled")

        await session.close()
    }

    func test_serverRequestRepliesMethodNotFoundWithNoHandlerConfigured() async throws {
        let (session, transport) = try await makeSession(withHandler: nil, advertisesElicitation: false)
        _ = try await session.start()

        try await transport.injectRequest(id: .int(202), method: "elicitation/create", params: nil)

        let reply = try await transport.awaitReply(forID: .int(202))
        guard case .error(_, let error) = reply else {
            XCTFail("Expected a .error reply, got \(reply)")
            return
        }
        XCTAssertEqual(error.code, -32601)
        // Sabotage: replying with .success instead of a JSON-RPC error when
        // serverRequestHandler is nil would turn this into a .result case, failing
        // the guard above.

        await session.close()
    }

    // MARK: - Action round-trips (accept / decline / cancel)

    func test_acceptActionRoundTripsWithContent() async throws {
        try await assertActionRoundTrip(
            action: .accept,
            content: .object(["age": .number(42)])
        )
    }

    func test_declineActionRoundTripsWithoutContent() async throws {
        try await assertActionRoundTrip(action: .decline, content: nil)
    }

    func test_cancelActionRoundTripsWithoutContent() async throws {
        try await assertActionRoundTrip(action: .cancel, content: nil)
    }

    private func assertActionRoundTrip(
        action: MCPElicitationResult.Action,
        content: JSONSchemaValue?
    ) async throws {
        let (session, transport) = try await makeSession(
            withHandler: { method, params in
                guard method == "elicitation/create" else {
                    return .failure(MCPJSONRPCErrorObject(code: -32601, message: "Method not found", data: nil))
                }
                do {
                    let request = try MCPElicitationRequest(params: params)
                    XCTAssertEqual(request.message, "Confirm?")
                    let result = MCPElicitationResult(action: action, content: content)
                    return .success(result.jsonRPCResult)
                } catch {
                    return .failure(MCPJSONRPCErrorObject(code: -32602, message: "\(error)", data: nil))
                }
            },
            advertisesElicitation: true
        )
        _ = try await session.start()

        let requestID = MCPRequestID.int(300 + action.rawValue.count)
        try await transport.injectRequest(id: requestID, method: "elicitation/create", params: .object([
            "message": .string("Confirm?"),
            "requestedSchema": .object(["type": .string("object")]),
        ]))

        let reply = try await transport.awaitReply(forID: requestID)
        guard case .result(_, let result) = reply,
              case .object(let object) = result else {
            XCTFail("Expected a .result reply with an object, got \(reply)")
            return
        }
        XCTAssertEqual(object["action"], .string(action.rawValue))
        if let content {
            XCTAssertEqual(object["content"], content)
        } else {
            XCTAssertNil(object["content"])
        }

        await session.close()
    }

    // MARK: - MCPElicitationRequest / MCPElicitationResult wire conversion

    func test_elicitationRequestParsesMessageAndSchema() throws {
        let params: JSONSchemaValue = .object([
            "message": .string("What city do you live in?"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object(["city": .object(["type": .string("string")])]),
            ]),
        ])

        let request = try MCPElicitationRequest(params: params)
        XCTAssertEqual(request.message, "What city do you live in?")
        guard case .object(let schemaObject) = request.requestedSchema else {
            XCTFail("Expected object schema")
            return
        }
        XCTAssertEqual(schemaObject["type"], .string("object"))
    }

    func test_elicitationRequestThrowsOnMissingMessage() {
        XCTAssertThrowsError(try MCPElicitationRequest(params: .object([
            "requestedSchema": .object(["type": .string("object")]),
        ])))
    }

    func test_elicitationRequestThrowsOnMissingSchema() {
        XCTAssertThrowsError(try MCPElicitationRequest(params: .object([
            "message": .string("hi"),
        ])))
    }

    func test_elicitationRequestThrowsOnNonObjectParams() {
        XCTAssertThrowsError(try MCPElicitationRequest(params: .string("nope")))
    }

    func test_elicitationResultEncodesAcceptWithContent() {
        let result = MCPElicitationResult(action: .accept, content: .object(["ok": .bool(true)]))
        guard case .object(let object) = result.jsonRPCResult else {
            XCTFail("Expected object result")
            return
        }
        XCTAssertEqual(object["action"], .string("accept"))
        XCTAssertEqual(object["content"], .object(["ok": .bool(true)]))
    }

    func test_elicitationResultEncodesDeclineWithoutContentKey() {
        let result = MCPElicitationResult(action: .decline)
        guard case .object(let object) = result.jsonRPCResult else {
            XCTFail("Expected object result")
            return
        }
        XCTAssertEqual(object["action"], .string("decline"))
        XCTAssertNil(object["content"], "declined results must omit 'content' entirely, not send null")
    }

    // MARK: - Test support

    private func makeSession(
        withHandler handler: MCPServerRequestHandler?,
        advertisesElicitation: Bool,
        advertisesSampling: Bool = false
    ) async throws -> (MCPSession, MockElicitationTransport) {
        let descriptor = MCPServerDescriptor(
            displayName: "Elicitation Test",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )
        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 8)
        let transport = MockElicitationTransport(codec: codec)
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
            serverRequestHandler: handler,
            advertisesSampling: advertisesSampling,
            advertisesElicitation: advertisesElicitation
        )
        return (session, transport)
    }
}

/// A fake `MCPTransport` that auto-answers `initialize` and lets tests inject arbitrary
/// server-initiated `.request` frames directly into `incomingMessages`, then read back
/// whatever the session sent in response. Mirrors `MockSamplingTransport`.
private actor MockElicitationTransport: MCPTransport {
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
