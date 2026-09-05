import Foundation
import XCTest
@testable import ManifoldMCP
@testable import ManifoldMCPHost
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport

// MARK: - ManifoldMCPHostTests

@MainActor
final class ManifoldMCPHostTests: XCTestCase {

    // MARK: Helpers

    /// Builds a minimal host backed by in-memory stores and a MockInferenceBackend.
    private func makeHost(
        sessions: [ChatSession] = [],
        messages: [ChatMessage] = []
    ) -> (host: ManifoldMCPHost, sessionStore: StubSessionStore, messageStore: StubMessageStore) {
        let fixture = makeRuntimeHost(sessions: sessions, messages: messages)
        return (fixture.host, fixture.sessionStore, fixture.messageStore)
    }

    private func makeRuntimeHost(
        sessions: [ChatSession] = [],
        messages: [ChatMessage] = [],
        tokensToYield: [String] = ["Hello", " world"],
        streamError: Error? = nil
    ) -> (
        host: ManifoldMCPHost,
        runtime: ConversationRuntime,
        sessionStore: StubSessionStore,
        messageStore: StubMessageStore
    ) {
        let sessionStore = StubSessionStore(sessions: sessions)
        let messageStore = StubMessageStore(messages: messages)
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = tokensToYield
        backend.shouldThrowInsideStream = streamError
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
        return (host, runtime, sessionStore, messageStore)
    }

    /// Drives a single JSON-RPC request through the host and returns the
    /// decoded response value.
    private func sendRequest(
        method: String,
        params: JSONSchemaValue?,
        to host: ManifoldMCPHost,
        maxMessageBytes: Int = 512 * 1024
    ) async throws -> JSONSchemaValue? {
        let transport = LoopbackHostTransport()
        let codec = MCPJSONRPCCodec(maxMessageBytes: maxMessageBytes, maxJSONNestingDepth: 32)
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

    func test_initialize_negotiatesVersionWhenClientVersionDiffers() async throws {
        // MCP spec §2.1: the server SHOULD respond with its supported version
        // rather than rejecting, allowing the client to decide whether to proceed.
        let (host, _, _) = makeHost()
        let result = try await sendRequest(
            method: "initialize",
            params: .object(["protocolVersion": .string("1900-01-01")]),
            to: host
        )

        guard case .object(let r) = result else {
            XCTFail("Expected object result for version negotiation")
            return
        }
        // Server must respond with its own supported version, not the client's.
        XCTAssertEqual(r["protocolVersion"], .string("2025-03-26"))
        // Sabotage: if we returned an error frame here, sendRequest would throw
        // TestMCPError and the guard-case .object would never be reached.
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
        let session = ChatSession(id: UUID(), title: "Test Session")
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
        let session = ChatSession(id: sessionID, title: "My Session")
        let message = ChatMessage(
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

    /// The MCP transcript resource is a complete-history consumer, not a UI
    /// page. Drive it through the real SwiftData provider with more records
    /// than the former fetch ceiling and assert the wire transcript preserves
    /// every record's identity, content, and chronological order.
    func test_resourcesRead_realSwiftDataTranscriptContainsCompleteHistoryBeyondFormerCeiling() async throws {
        let stack = try InMemoryPersistenceHarness.make()
        XCTAssertTrue(InMemoryPersistenceHarness.isInMemoryStore(stack.container))

        let session = ChatSession(title: "Long MCP transcript")
        try await stack.provider.insertSession(session)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let expectedMessages = (0...10_000).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "history-message-\(index)",
                timestamp: timestamp.addingTimeInterval(Double(index)),
                sessionID: session.id
            )
        }
        try await stack.provider.performMessageMutations(expectedMessages.map(MessageStoreMutation.insert))

        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let runtime = ConversationRuntime(
            messageStore: stack.provider,
            sessionStore: stack.provider,
            inferenceService: InferenceService(backend: backend)
        )
        let host = ManifoldMCPHost(
            sessionStore: stack.provider,
            messageStore: stack.provider,
            conversationRuntime: runtime
        )

        let result = try await sendRequest(
            method: "resources/read",
            params: .object(["uri": .string("manifold://sessions/\(session.id.uuidString)")]),
            to: host,
            maxMessageBytes: 8 * 1024 * 1024
        )

        guard case .object(let response) = result,
              case .array(let contents) = response["contents"],
              case .object(let resource) = contents.first,
              case .string(let text) = resource["text"] else {
            return XCTFail("Expected the session transcript resource")
        }
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual((object["messageCount"] as? NSNumber)?.intValue, expectedMessages.count)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, expectedMessages.count)

        let receivedIDs = messages.compactMap { $0["id"] as? String }
        XCTAssertEqual(receivedIDs.count, expectedMessages.count, "Every transcript row must encode its id")
        XCTAssertEqual(receivedIDs, expectedMessages.map { $0.id.uuidString })

        let receivedContent = messages.compactMap { $0["content"] as? String }
        XCTAssertEqual(receivedContent.count, expectedMessages.count, "Every transcript row must encode its content")
        XCTAssertEqual(receivedContent, expectedMessages.map(\.content))

        // Sabotage: restoring a bounded complete-history fetch truncates the
        // resource and makes both full-array assertions fail.
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
        let session = ChatSession(id: UUID(), title: "Alpha Session")
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

    func test_toolCall_sendMessage_returnsOutcomeTextWithoutStealingRuntimeEvents() async throws {
        let sessionID = UUID()
        let session = ChatSession(id: sessionID, title: "MCP Session")
        let fixture = makeRuntimeHost(
            sessions: [session],
            tokensToYield: ["MCP", " reply"]
        )
        let host = fixture.host
        let runtime = fixture.runtime

        let observedFinalText = Task { () -> String? in
            for await event in runtime.events {
                if case .afterGeneration(_, let finalText) = event {
                    return finalText
                }
            }
            return nil
        }
        defer { observedFinalText.cancel() }

        let result = try await sendRequest(
            method: "tools/call",
            params: .object([
                "name": .string("send_message"),
                "arguments": .object([
                    "session_id": .string(sessionID.uuidString),
                    "text": .string("Hello over MCP"),
                ]),
            ]),
            to: host
        )

        guard case .object(let response) = result,
              case .array(let content) = response["content"],
              case .object(let first) = content.first,
              case .string(let responseText) = first["text"] else {
            XCTFail("Expected MCP content text")
            observedFinalText.cancel()
            return
        }

        XCTAssertEqual(responseText, "MCP reply")
        let finalText = await observedFinalText.value
        XCTAssertEqual(finalText, "MCP reply")
        XCTAssertEqual(response["isError"], .bool(false))
    }

    func test_toolCall_sendMessage_reportsStreamFailureViaIsError() async throws {
        struct StreamBoom: Error, LocalizedError {
            var errorDescription: String? { "stream exploded" }
        }
        let sessionID = UUID()
        let session = ChatSession(id: sessionID, title: "MCP Session")
        let fixture = makeRuntimeHost(sessions: [session], streamError: StreamBoom())

        let result = try await sendRequest(
            method: "tools/call",
            params: .object([
                "name": .string("send_message"),
                "arguments": .object([
                    "session_id": .string(sessionID.uuidString),
                    "text": .string("Hello over MCP"),
                ]),
            ]),
            to: fixture.host
        )

        guard case .object(let response) = result,
              case .array(let content) = response["content"],
              case .object(let first) = content.first,
              case .string(let responseText) = first["text"] else {
            XCTFail("Expected MCP content text")
            return
        }

        // The documented MCP signaling mechanism for tool failure is
        // isError: true — a failed turn must not be shaped like a success.
        XCTAssertEqual(response["isError"], .bool(true))
        XCTAssertTrue(responseText.contains("send_message failed"), "failure text should identify the failing tool; got: \(responseText)")
    }

    func test_toolCall_listSessions_reportsStoreFailureViaIsError() async throws {
        struct StoreBoom: Error, LocalizedError {
            var errorDescription: String? { "session store exploded" }
        }
        let fixture = makeRuntimeHost()
        fixture.sessionStore.fetchError = StoreBoom()

        let result = try await sendRequest(
            method: "tools/call",
            params: .object([
                "name": .string("list_sessions"),
                "arguments": .object([:]),
            ]),
            to: fixture.host
        )

        guard case .object(let response) = result,
              case .array(let content) = response["content"],
              case .object(let first) = content.first,
              case .string(let responseText) = first["text"] else {
            XCTFail("Expected MCP content text")
            return
        }
        XCTAssertEqual(response["isError"], .bool(true))
        XCTAssertTrue(responseText.contains("list_sessions failed"), "failure text should identify the failing tool; got: \(responseText)")
    }

    func test_toolCall_searchDocuments_reportsRetrievalFailureViaIsError() async throws {
        let sessionStore = StubSessionStore()
        let messageStore = StubMessageStore()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: InferenceService(backend: backend)
        )
        // No embedding backend → RAGService's dense stage goes straight to the
        // vector store's keyword search, which this stub makes throw.
        let ragService = RAGService(
            documentStore: StubDocumentStore(),
            vectorStore: ThrowingVectorStore()
        )
        let host = ManifoldMCPHost(
            sessionStore: sessionStore,
            messageStore: messageStore,
            conversationRuntime: runtime,
            ragService: ragService
        )

        let result = try await sendRequest(
            method: "tools/call",
            params: .object([
                "name": .string("search_documents"),
                "arguments": .object(["query": .string("anything")]),
            ]),
            to: host
        )

        guard case .object(let response) = result,
              case .array(let content) = response["content"],
              case .object(let first) = content.first,
              case .string(let responseText) = first["text"] else {
            XCTFail("Expected MCP content text")
            return
        }
        XCTAssertEqual(response["isError"], .bool(true))
        XCTAssertTrue(responseText.contains("search_documents failed"), "failure text should identify the failing tool; got: \(responseText)")
    }

    // MARK: - Init: serverName × configuration precedence

    func test_init_explicitServerNameOverridesConfigurationServerName() async throws {
        let sessionStore = StubSessionStore()
        let messageStore = StubMessageStore()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: InferenceService(backend: backend)
        )
        // Pre-fix, a non-nil configuration silently discarded serverName.
        let host = ManifoldMCPHost(
            sessionStore: sessionStore,
            messageStore: messageStore,
            conversationRuntime: runtime,
            serverName: "My App",
            configuration: .init(maxMessageBytes: 8_000_000)
        )

        let result = try await sendRequest(
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-03-26")]),
            to: host
        )

        guard case .object(let r) = result,
              case .object(let serverInfo) = r["serverInfo"],
              case .string(let name) = serverInfo["name"] else {
            XCTFail("Expected serverInfo.name in initialize result")
            return
        }
        XCTAssertEqual(name, "My App")
    }

    func test_init_configurationServerNameUsedWhenServerNameOmitted() async throws {
        let sessionStore = StubSessionStore()
        let messageStore = StubMessageStore()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let runtime = ConversationRuntime(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: InferenceService(backend: backend)
        )
        var configuration = ManifoldMCPHost.Configuration()
        configuration.serverName = "Configured Name"
        let host = ManifoldMCPHost(
            sessionStore: sessionStore,
            messageStore: messageStore,
            conversationRuntime: runtime,
            configuration: configuration
        )

        let result = try await sendRequest(
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-03-26")]),
            to: host
        )

        guard case .object(let r) = result,
              case .object(let serverInfo) = r["serverInfo"],
              case .string(let name) = serverInfo["name"] else {
            XCTFail("Expected serverInfo.name in initialize result")
            return
        }
        XCTAssertEqual(name, "Configured Name")
    }
}

// MARK: - Test helpers

/// Simple in-memory SessionStore for test purposes.
/// @MainActor serialises all mutations; @unchecked Sendable is valid because
/// the class is globally-actor-isolated and the protocol requires @MainActor.
@MainActor
private final class StubSessionStore: SessionStore, @unchecked Sendable {
    private var sessions: [ChatSession]
    /// When set, `fetchSessions` throws instead of returning — exercises the
    /// host's tool-level failure reporting (`isError: true`).
    var fetchError: Error?

    init(sessions: [ChatSession] = []) {
        self.sessions = sessions
    }

    func insertSession(_ session: ChatSession) async throws { sessions.append(session) }
    func updateSession(_ session: ChatSession) async throws {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else {
            throw ChatPersistenceError.sessionNotFound(session.id)
        }
        sessions[idx] = session
    }
    func deleteSession(_ sessionID: UUID) async throws {
        sessions.removeAll { $0.id == sessionID }
    }
    func fetchSessions() async throws -> [ChatSession] {
        if let fetchError { throw fetchError }
        return sessions
    }
}

/// Simple in-memory MessageStore for test purposes.
/// @MainActor serialises all mutations; @unchecked Sendable is valid because
/// the class is globally-actor-isolated and the protocol requires @MainActor.
@MainActor
private final class StubMessageStore: MessageStore, @unchecked Sendable {
    private var messages: [ChatMessage]

    init(messages: [ChatMessage] = []) {
        self.messages = messages
    }

    func insertMessage(_ message: ChatMessage) async throws { messages.append(message) }
    func updateMessage(_ message: ChatMessage) async throws {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else {
            throw ChatPersistenceError.messageNotFound(message.id)
        }
        messages[idx] = message
    }
    func deleteMessage(_ messageID: UUID) async throws {
        messages.removeAll { $0.id == messageID }
    }
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        messages.filter { $0.sessionID == sessionID }
    }
    func deleteMessages(for sessionID: UUID) async throws {
        messages.removeAll { $0.sessionID == sessionID }
    }
}

/// Minimal DocumentStore for the search_documents failure-path test.
@MainActor
private final class StubDocumentStore: DocumentStore, @unchecked Sendable {
    func insertDocument(_ record: DocumentRecord) async throws {}
    func fetchDocuments() async throws -> [DocumentRecord] { [] }
    func fetchDocument(id: UUID) async throws -> DocumentRecord? { nil }
    func deleteDocument(id: UUID) async throws {}
}

/// VectorStore whose search paths always throw — drives RAGService.retrieve
/// into its failure path so the host's in-band isError reporting is exercised.
private struct ThrowingVectorStore: VectorStore {
    struct VectorBoom: Error, LocalizedError {
        var errorDescription: String? { "vector store exploded" }
    }
    func insert(chunks: [DocumentChunk], documentTitle: String, embeddings: [[Float]]) async throws {}
    func search(embedding: [Float], limit: Int) async throws -> [VectorSearchHit] { throw VectorBoom() }
    func keywordSearch(query: String, limit: Int) async throws -> [VectorSearchHit] { throw VectorBoom() }
    func delete(documentID: UUID) async throws {}
    func deleteAll() async throws {}
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
