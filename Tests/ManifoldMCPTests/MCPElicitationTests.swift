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
                    let request = try MCPElicitationRequest(serverID: UUID(), params: params)
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

        let request = try MCPElicitationRequest(serverID: UUID(), params: params)
        XCTAssertEqual(request.message, "What city do you live in?")
        guard case .object(let schemaObject) = request.requestedSchema else {
            XCTFail("Expected object schema")
            return
        }
        XCTAssertEqual(schemaObject["type"], .string("object"))
    }

    func test_elicitationRequestThrowsOnMissingMessage() {
        XCTAssertThrowsError(try MCPElicitationRequest(serverID: UUID(), params: .object([
            "requestedSchema": .object(["type": .string("object")]),
        ])))
    }

    func test_elicitationRequestThrowsOnMissingSchema() {
        XCTAssertThrowsError(try MCPElicitationRequest(serverID: UUID(), params: .object([
            "message": .string("hi"),
        ])))
    }

    func test_elicitationRequestThrowsOnNonObjectParams() {
        XCTAssertThrowsError(try MCPElicitationRequest(serverID: UUID(), params: .string("nope")))
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

    // MARK: - Codable decode-compat (#2284 review finding)

    /// `MCPServerDescriptor` is `Codable`, and `allowsSampling` (#1925/#2274) plus
    /// `allowsElicitation` (this PR) previously had defaults only on the memberwise
    /// `init` parameter, not the stored property — so the compiler-synthesized
    /// `init(from:)` hard-required both keys, and a persisted pre-upgrade JSON blob
    /// missing them would fail to decode outright. The fix is the inline `= false`
    /// property defaults PLUS `MCPServerDescriptor`'s hand-written `init(from:)`
    /// (`MCPTypes.swift`), which decodes both keys via `decodeIfPresent(...) ?? false`.
    /// Swift's *compiler-synthesized* `Decodable` does NOT do this — a synthesized
    /// `init(from:)` still throws `DecodingError.keyNotFound` for a defaulted stored
    /// property whose key is absent; the tolerance here comes entirely from the
    /// custom decoder, not from the property-level default (verified empirically,
    /// #2284 review finding 5).
    func test_serverDescriptorDecodesPersistedJSONMissingAllowsKeys() throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Persisted",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test",
            allowsSampling: true,
            allowsElicitation: true
        )
        let data = try JSONEncoder().encode(descriptor)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected a JSON object")
            return
        }
        // Simulate a pre-#1925/#1926 persisted blob: neither opt-in key exists on disk.
        object.removeValue(forKey: "allowsSampling")
        object.removeValue(forKey: "allowsElicitation")
        let strippedData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(MCPServerDescriptor.self, from: strippedData)
        XCTAssertEqual(decoded.allowsSampling, false, "missing 'allowsSampling' key must decode to the safe default, not fail")
        XCTAssertEqual(decoded.allowsElicitation, false, "missing 'allowsElicitation' key must decode to the safe default, not fail")
        // Sabotage: removing the inline `= false` defaults from allowsSampling/allowsElicitation
        // in MCPTypes.swift (reverting to bare `public var allowsSampling: Bool`) would make
        // the synthesized Decodable initializer hard-require both keys, and this decode call
        // would throw `DecodingError.keyNotFound` instead of returning safe defaults.
    }

    // MARK: - MCPClient consent gate (#2284 review finding 2)

    /// Every test above constructs `MCPSession` directly via `makeSession(...)`, hand-passing
    /// `advertisesElicitation:`/`serverRequestHandler:` — that never exercises the actual gate
    /// `MCPClient.connect()` computes. `MCPClient.elicitationEnabled(for:configuration:)`
    /// (`MCPClient.swift`) was extracted from the inline
    /// `descriptor.allowsElicitation && configuration.elicitationHandler != nil` expression
    /// specifically so it is unit-testable — see #2284 review finding 2: "proven sabotage:
    /// delete `allowsElicitation &&` from that line → all other tests still pass."
    ///
    /// This calls the REAL function `connect()` invokes — not a hand-copied re-implementation
    /// of the boolean.
    func test_clientGateBlocksElicitationWhenDescriptorOptsOut() throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Untrusted Server",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test",
            allowsElicitation: false
        )
        let configuration = MCPClientConfiguration(
            elicitationHandler: { _ in MCPElicitationResult(action: .accept) }
        )

        let enabled = MCPClient.elicitationEnabled(for: descriptor, configuration: configuration)

        XCTAssertFalse(enabled, "A server that hasn't set allowsElicitation must never be gated open, even with a host handler configured")
        // Sabotage (reported literally in the #2284 review): deleting `descriptor.allowsElicitation &&`
        // from `MCPClient.elicitationEnabled(for:configuration:)` — leaving only
        // `configuration.elicitationHandler != nil` — makes `enabled` true here despite
        // `allowsElicitation: false`, failing this assertion. This is the exact function
        // `connect()` calls; no other test in this file called it before this one.
    }

    func test_clientGateAllowsElicitationOnlyWhenBothDescriptorAndHandlerOptIn() throws {
        let allowingDescriptor = MCPServerDescriptor(
            displayName: "Trusted Server",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test",
            allowsElicitation: true
        )
        let refusingConfiguration = MCPClientConfiguration() // elicitationHandler defaults to nil
        XCTAssertFalse(
            MCPClient.elicitationEnabled(for: allowingDescriptor, configuration: refusingConfiguration),
            "allowsElicitation: true alone must not open the gate without a host handler configured"
        )

        let acceptingConfiguration = MCPClientConfiguration(
            elicitationHandler: { _ in MCPElicitationResult(action: .accept) }
        )
        XCTAssertTrue(
            MCPClient.elicitationEnabled(for: allowingDescriptor, configuration: acceptingConfiguration),
            "Both allowsElicitation: true AND a configured handler must open the gate"
        )
    }

    /// Ties `MCPClient`'s real gate function to the end-to-end dispatch outcome `MCPSession`
    /// produces, closing the loop the two tests above start: proves the boolean
    /// `elicitationEnabled(for:configuration:)` computes is exactly what determines whether a
    /// server request gets a live prompt vs. "method not found" — using the same `makeSession`
    /// harness (mock transport, no live network/subprocess) as every other test in this file.
    func test_serverRequestHonorsClientGateOutcome_whenDescriptorOptsOut() async throws {
        let descriptor = MCPServerDescriptor(
            displayName: "Untrusted Server",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test",
            allowsElicitation: false
        )
        let configuration = MCPClientConfiguration(
            elicitationHandler: { _ in
                XCTFail("elicitationHandler must never be invoked when the client gate is closed")
                return MCPElicitationResult(action: .accept)
            }
        )
        let enabled = MCPClient.elicitationEnabled(for: descriptor, configuration: configuration)
        XCTAssertFalse(enabled)

        // `enabled == false` is exactly what makes `MCPClient.connect()` pass
        // `serverRequestHandler: nil` to `MCPSession` (see `makeServerRequestHandler`'s
        // `guard samplingEnabled || elicitationEnabled else { return nil }`) — reproduce that
        // wiring here via `withHandler: nil` / `advertisesElicitation: enabled`.
        let (session, transport) = try await makeSession(withHandler: nil, advertisesElicitation: enabled)
        _ = try await session.start()

        try await transport.injectRequest(id: .int(400), method: "elicitation/create", params: .object([
            "message": .string("Corporate VPN session expired — re-enter your password"),
            "requestedSchema": .object(["type": .string("object")]),
        ]))

        let reply = try await transport.awaitReply(forID: .int(400))
        guard case .error(_, let error) = reply else {
            XCTFail("Expected a .error reply (method not found), got \(reply)")
            return
        }
        XCTAssertEqual(error.code, -32601, "A gate-closed server must get 'method not found', never a live prompt")
        // Sabotage: same as above — deleting `descriptor.allowsElicitation &&` from
        // `MCPClient.elicitationEnabled(for:configuration:)` flips `enabled` to `true`, which
        // flips `advertisesElicitation`/`withHandler` here and turns this into a live `.result`
        // reply instead of a `-32601` error.

        await session.close()
    }

    // MARK: - Schema validation (#2284 review must-fix 1)

    /// `isSupportedSchema` is the #1926 headline safety behavior — it is what stops an
    /// arbitrarily-nested or non-primitive `requestedSchema` from ever reaching the
    /// host's form renderer. Before this test it had ZERO coverage (referenced only from
    /// production), so the reviewer's sabotage — flipping the function body to `return
    /// true` — left the whole suite green. This test fails under that sabotage.
    func test_isSupportedSchemaAcceptsFlatPrimitivesRejectsEverythingElse() {
        // Accepts: a flat object of the four spec-permitted primitive types.
        XCTAssertTrue(MCPElicitationRequest.isSupportedSchema(.object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "age": .object(["type": .string("integer")]),
                "score": .object(["type": .string("number")]),
                "active": .object(["type": .string("boolean")]),
            ]),
        ])))
        // Accepts: an object with no `properties` key at all (an empty flat form).
        XCTAssertTrue(MCPElicitationRequest.isSupportedSchema(.object(["type": .string("object")])))

        // Rejects: the schema isn't even an object.
        XCTAssertFalse(MCPElicitationRequest.isSupportedSchema(.string("object")))
        // Rejects: missing the top-level `type: "object"`.
        XCTAssertFalse(MCPElicitationRequest.isSupportedSchema(.object(["properties": .object([:])])))
        // Rejects: a nested object property (the shape #1926 auto-declines).
        XCTAssertFalse(MCPElicitationRequest.isSupportedSchema(.object([
            "type": .string("object"),
            "properties": .object(["nested": .object(["type": .string("object")])]),
        ])))
        // Rejects: an array-typed property.
        XCTAssertFalse(MCPElicitationRequest.isSupportedSchema(.object([
            "type": .string("object"),
            "properties": .object(["tags": .object(["type": .string("array")])]),
        ])))
        // Rejects: a property whose schema isn't an object (so it has no `type`).
        XCTAssertFalse(MCPElicitationRequest.isSupportedSchema(.object([
            "type": .string("object"),
            "properties": .object(["bad": .string("nope")]),
        ])))
    }

    /// Drives the REAL request-handler closure `MCPClient.connect()` wires (via the
    /// now-`internal` `makeServerRequestHandler`, mirroring the `elicitationEnabled`
    /// seam) — proving the `isSupportedSchema` guard is LIVE, not just correct in
    /// isolation. An unsupported (nested) schema must be auto-declined WITHOUT ever
    /// invoking the host handler. Sabotage: deleting the `guard isSupportedSchema…
    /// else { return .decline }` line from `makeServerRequestHandler` forwards the
    /// nested schema to `elicitationHandler`, tripping its `XCTFail` and flipping the
    /// asserted action from `decline` to `accept`.
    func test_makeServerRequestHandlerAutoDeclinesUnsupportedSchema() async {
        let descriptor = MCPServerDescriptor(
            displayName: "Trusted Server",
            transport: .streamableHTTP(endpoint: URL(string: "https://example.com/mcp")!, headers: [:]),
            dataDisclosure: "test",
            allowsElicitation: true
        )
        let configuration = MCPClientConfiguration(
            elicitationHandler: { _ in
                XCTFail("host handler must never be invoked for an unsupported schema — it must be auto-declined first")
                return MCPElicitationResult(action: .accept)
            }
        )
        let client = MCPClient(configuration: configuration)
        guard let handler = await client.makeServerRequestHandler(
            for: descriptor,
            samplingEnabled: false,
            elicitationEnabled: true
        ) else {
            XCTFail("expected a live server-request handler when elicitation is enabled")
            return
        }

        let unsupportedSchema: JSONSchemaValue = .object([
            "message": .string("Fill in the nested form"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object(["nested": .object(["type": .string("object")])]),
            ]),
        ])
        let result = await handler("elicitation/create", unsupportedSchema)

        guard case .success(let payload) = result, case .object(let object) = payload else {
            XCTFail("expected a successful auto-decline result, got \(result)")
            return
        }
        XCTAssertEqual(object["action"], .string("decline"), "an unsupported schema must be auto-declined")
        XCTAssertNil(object["content"], "a decline carries no content")
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
