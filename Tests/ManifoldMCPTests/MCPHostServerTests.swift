#if MCP
import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

// MARK: - ManifoldMCPHostTests

@MainActor
final class ManifoldMCPHostTests: XCTestCase {

    // MARK: Helpers

    /// Builds a minimal host backed by in-memory stores and a MockInferenceBackend.
    private func makeHost(
        sessions: [ChatSessionRecord] = [],
        messages: [ChatMessageRecord] = []
    ) -> (host: ManifoldMCPHost, sessionStore: StubSessionStore, messageStore: StubMessageStore) {
        let sessionStore = StubSessionStore(sessions: sessions)
        let messageStore = StubMessageStore(messages: messages)
        let backend = MockInferenceBackend()
        let inferenceService = InferenceService(backend: backend)
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: inferenceService
        )
        let host = ManifoldMCPHost(
            sessionStore: sessionStore,
            messageStore: messageStore,
            conversationRuntime: runtime
        )
        return (host, sessionStore, messageStore)
    }

    /// Drives a single JSON-RPC request through the host and returns the
    /// decoded response value.
    private func sendRequest(
        method: String,
        params: JSONSchemaValue?,
        to host: ManifoldMCPHost
    ) async throws -> JSONSchemaValue? {
        let transport = LoopbackHostTransport()
        let codec = MCPJSONRPCCodec(maxMessageBytes: 512 * 1024, maxJSONNestingDepth: 32)
        let id = MCPRequestID.int(1)
        let request = MCPJSONRPCMessage.request(id: id, method: method, params: params)
        let payload = try codec.encode(request)

        // Drive the host in a background task; cancel it after we get one response.
        let runTask = Task {
            try await host.run(transport: transport)
        }

        // Feed the request into the transport.
        await transport.feed(payload)

        // Collect the first response with a short deadline.
        let responseData = await transport.nextResponse(timeout: .seconds(3))
        runTask.cancel()

        guard let responseData else {
            XCTFail("No response received within deadline")
            return nil
        }

        let response = try codec.decode(responseData)
        if case .result(_, let result) = response {
            return result
        }
        if case .error(_, let errorObj) = response {
            throw TestMCPError.fromServer(code: errorObj.code, message: errorObj.message)
        }
        XCTFail("Unexpected response frame shape")
        return nil
    }

    // MARK: - Handshake

    func test_initialize_returnsCapabilitiesForMatchingProtocolVersion() async throws {
        let (host, _, _) = makeHost()
        let result = try await sendRequest(
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-03-26")]),
            to: host
        )

        guard case .object(let r) = result else {
            XCTFail("Expected object result")
            return
        }
        XCTAssertEqual(r["protocolVersion"], .string("2025-03-26"))
        guard case .object(let capabilities) = r["capabilities"] else {
            XCTFail("Expected capabilities object")
            return
        }
        XCTAssertNotNil(capabilities["tools"])
        XCTAssertNotNil(capabilities["resources"])
        // Sabotage check: if we removed the "capabilities" key from the initialize
        // response, the XCTAssertNotNil checks above would fail.
    }

    func test_initialize_rejectsUnsupportedProtocolVersion() async throws {
        let (host, _, _) = makeHost()
        let codec = MCPJSONRPCCodec(maxMessageBytes: 512 * 1024, maxJSONNestingDepth: 32)
        let transport = LoopbackHostTransport()
        let id = MCPRequestID.int(1)
        let request = MCPJSONRPCMessage.request(
            id: id,
            method: "initialize",
            params: .object(["protocolVersion": .string("1900-01-01")])
        )
        let payload = try codec.encode(request)

        let runTask = Task { try await host.run(transport: transport) }
        await transport.feed(payload)
        let responseData = await transport.nextResponse(timeout: .seconds(3))
        runTask.cancel()

        guard let responseData else {
            XCTFail("No response received")
            return
        }
        let response = try codec.decode(responseData)
        guard case .error(_, let err) = response else {
            XCTFail("Expected error frame for unsupported protocol version")
            return
        }
        XCTAssertEqual(err.code, -32600)
        // Sabotage: if we returned a success result instead of an error for
        // unknown versions, the guard-case .error would fall through and fail.
    }

    func test_unknownMethod_returnsMethodNotFoundError() async throws {
        let (host, _, _) = makeHost()
        let codec = MCPJSONRPCCodec(maxMessageBytes: 512 * 1024, maxJSONNestingDepth: 32)
        let transport = LoopbackHostTransport()
        let id = MCPRequestID.int(99)
        let request = MCPJSONRPCMessage.request(id: id, method: "no/such/method", params: nil)
        let payload = try codec.encode(request)

        let runTask = Task { try await host.run(transport: transport) }
        await transport.feed(payload)
        let responseData = await transport.nextResponse(timeout: .seconds(3))
        runTask.cancel()

        guard let responseData else {
            XCTFail("No response received")
            return
        }
        let response = try codec.decode(responseData)
        guard case .error(_, let err) = response else {
            XCTFail("Expected error response for unknown method")
            return
        }
        XCTAssertEqual(err.code, -32601)
    }

    // MARK: - resources/list

    func test_resourcesList_includesSessions() async throws {
        let session = ChatSessionRecord(id: UUID(), title: "Test Session")
        let (host, _, _) = makeHost(sessions: [session])

        let result = try await sendRequest(
            method: "resources/list",
            params: nil,
            to: host
        )

        guard case .object(let r) = result,
              case .array(let resources) = r["resources"] else {
            XCTFail("Expected resources array")
            return
        }

        let uris = resources.compactMap { resource -> String? in
            guard case .object(let obj) = resource, case .string(let uri) = obj["uri"] else { return nil }
            return uri
        }
        XCTAssertTrue(uris.contains("manifold://sessions/\(session.id.uuidString)"),
                      "Expected session URI in resources list; got \(uris)")
        // Sabotage: removing the session loop in handleResourcesList would yield an empty array.
    }

    func test_resourcesList_emptyWhenNoSessions() async throws {
        let (host, _, _) = makeHost(sessions: [])
        let result = try await sendRequest(
            method: "resources/list",
            params: nil,
            to: host
        )

        guard case .object(let r) = result,
              case .array(let resources) = r["resources"] else {
            XCTFail("Expected resources array")
            return
        }
        XCTAssertTrue(resources.isEmpty)
    }

    // MARK: - resources/read

    func test_resourcesRead_returnsMessagesForSession() async throws {
        let sessionID = UUID()
        let session = ChatSessionRecord(id: sessionID, title: "My Session")
        let message = ChatMessageRecord(
            id: UUID(), role: .user, content: "Hello world",
            timestamp: Date(), sessionID: sessionID
        )
        let (host, _, _) = makeHost(sessions: [session], messages: [message])

        let result = try await sendRequest(
            method: "resources/read",
            params: .object(["uri": .string("manifold://sessions/\(sessionID.uuidString)")]),
            to: host
        )

        guard case .object(let r) = result,
              case .array(let contents) = r["contents"],
              case .object(let contentObj) = contents.first,
              case .string(let text) = contentObj["text"] else {
            XCTFail("Expected contents array with text")
            return
        }
        XCTAssertTrue(text.contains("Hello world"), "Message content should appear in resource text")
        // Sabotage: if we returned messages=[] in readSessionResource, this assertion would fail.
    }

    func test_resourcesRead_returnsNotFoundForMissingSession() async throws {
        let (host, _, _) = makeHost(sessions: [])
        let codec = MCPJSONRPCCodec(maxMessageBytes: 512 * 1024, maxJSONNestingDepth: 32)
        let transport = LoopbackHostTransport()
        let request = MCPJSONRPCMessage.request(
            id: .int(1),
            method: "resources/read",
            params: .object(["uri": .string("manifold://sessions/\(UUID().uuidString)")])
        )
        let payload = try codec.encode(request)

        let runTask = Task { try await host.run(transport: transport) }
        await transport.feed(payload)
        let responseData = await transport.nextResponse(timeout: .seconds(3))
        runTask.cancel()

        guard let responseData else { XCTFail("No response"); return }
        let response = try codec.decode(responseData)
        guard case .error(_, let err) = response else {
            XCTFail("Expected error for missing session")
            return
        }
        XCTAssertEqual(err.code, -32001)
    }

    // MARK: - tools/list

    func test_toolsList_includesListSessionsAndSendMessage() async throws {
        let (host, _, _) = makeHost()
        let result = try await sendRequest(method: "tools/list", params: nil, to: host)

        guard case .object(let r) = result,
              case .array(let tools) = r["tools"] else {
            XCTFail("Expected tools array")
            return
        }
        let names = tools.compactMap { tool -> String? in
            guard case .object(let obj) = tool, case .string(let name) = obj["name"] else { return nil }
            return name
        }
        XCTAssertTrue(names.contains("list_sessions"), "Expected list_sessions tool")
        XCTAssertTrue(names.contains("send_message"), "Expected send_message tool")
        XCTAssertFalse(names.contains("search_documents"), "search_documents should be absent without RAGService")
        // Sabotage: removing tool entries from handleToolsList would cause these assertions to fail.
    }

    // MARK: - tools/call: list_sessions

    func test_toolCall_listSessions_returnsSessions() async throws {
        let session = ChatSessionRecord(id: UUID(), title: "Alpha Session")
        let (host, _, _) = makeHost(sessions: [session])

        let result = try await sendRequest(
            method: "tools/call",
            params: .object([
                "name": .string("list_sessions"),
                "arguments": .object([:]),
            ]),
            to: host
        )

        guard case .object(let r) = result,
              case .array(let content) = r["content"],
              case .object(let item) = content.first,
              case .string(let text) = item["text"] else {
            XCTFail("Expected content array with text item")
            return
        }
        XCTAssertTrue(text.contains(session.id.uuidString), "Response should contain session ID")
        XCTAssertTrue(text.contains("Alpha Session"), "Response should contain session title")
        // Sabotage: clearing the sessions array in the stub would make this check fail.
    }

    func test_toolCall_unknownTool_returnsError() async throws {
        let (host, _, _) = makeHost()
        let codec = MCPJSONRPCCodec(maxMessageBytes: 512 * 1024, maxJSONNestingDepth: 32)
        let transport = LoopbackHostTransport()
        let request = MCPJSONRPCMessage.request(
            id: .int(1),
            method: "tools/call",
            params: .object(["name": .string("does_not_exist"), "arguments": .object([:])])
        )
        let payload = try codec.encode(request)

        let runTask = Task { try await host.run(transport: transport) }
        await transport.feed(payload)
        let responseData = await transport.nextResponse(timeout: .seconds(3))
        runTask.cancel()

        guard let responseData else { XCTFail("No response"); return }
        let response = try codec.decode(responseData)
        guard case .error(_, let err) = response else {
            XCTFail("Expected error for unknown tool")
            return
        }
        XCTAssertEqual(err.code, -32002)
    }
}

// MARK: - Test helpers

/// Simple in-memory SessionStore for test purposes.
@MainActor
private final class StubSessionStore: SessionStore, @unchecked Sendable {
    private var sessions: [ChatSessionRecord]

    init(sessions: [ChatSessionRecord] = []) {
        self.sessions = sessions
    }

    func insertSession(_ session: ChatSessionRecord) async throws { sessions.append(session) }
    func updateSession(_ session: ChatSessionRecord) async throws {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else {
            throw ChatPersistenceError.sessionNotFound(session.id)
        }
        sessions[idx] = session
    }
    func deleteSession(_ sessionID: UUID) async throws {
        sessions.removeAll { $0.id == sessionID }
    }
    func fetchSessions() async throws -> [ChatSessionRecord] { sessions }
}

/// Simple in-memory MessageStore for test purposes.
@MainActor
private final class StubMessageStore: MessageStore, @unchecked Sendable {
    private var messages: [ChatMessageRecord]

    init(messages: [ChatMessageRecord] = []) {
        self.messages = messages
    }

    func insertMessage(_ message: ChatMessageRecord) async throws { messages.append(message) }
    func updateMessage(_ message: ChatMessageRecord) async throws {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else {
            throw ChatPersistenceError.messageNotFound(message.id)
        }
        messages[idx] = message
    }
    func deleteMessage(_ messageID: UUID) async throws {
        messages.removeAll { $0.id == messageID }
    }
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
        messages.filter { $0.sessionID == sessionID }
    }
    func deleteMessages(for sessionID: UUID) async throws {
        messages.removeAll { $0.sessionID == sessionID }
    }
}

/// Error emitted by the test helper when the server returns a JSON-RPC error frame.
private enum TestMCPError: Error {
    case fromServer(code: Int, message: String)
}

// MARK: - LoopbackHostTransport

/// In-memory MCPHostTransport for unit tests.
/// Feed payloads in via `feed(_:)` and collect responses via `nextResponse(timeout:)`.
private actor LoopbackHostTransport: MCPHostTransport {
    nonisolated let incomingMessages: AsyncThrowingStream<Data, Error>
    private let inContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private var responseContinuationsTagged: [(UUID, CheckedContinuation<Data?, Never>)] = []
    private var bufferedResponses: [Data] = []

    init() {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        self.incomingMessages = stream
        self.inContinuation = continuation
    }

    /// Deliver a payload to the host as if the remote client sent it.
    func feed(_ payload: Data) {
        inContinuation.yield(payload)
    }

    /// Write a response frame (called by the host actor).
    func send(_ payload: Data) async throws {
        if let (id, waiter) = responseContinuationsTagged.first {
            responseContinuationsTagged.removeFirst()
            _ = id
            waiter.resume(returning: payload)
        } else {
            bufferedResponses.append(payload)
        }
    }

    /// Waits up to `timeout` for a response from the host. Returns `nil` on timeout.
    func nextResponse(timeout: Duration) async -> Data? {
        if !bufferedResponses.isEmpty {
            return bufferedResponses.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            let waiterID = UUID()
            responseContinuationsTagged.append((waiterID, continuation))
            Task { [self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self.resolveWaiterIfPending(id: waiterID, with: nil)
            }
        }
    }

    private func resolveWaiterIfPending(id: UUID, with value: Data?) {
        guard let idx = responseContinuationsTagged.firstIndex(where: { $0.0 == id }) else {
            return // already resolved by send(_:)
        }
        let (_, continuation) = responseContinuationsTagged.remove(at: idx)
        continuation.resume(returning: value)
    }
}
#endif
