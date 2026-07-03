import Foundation
import ManifoldInference
import ManifoldMCP
import ManifoldRuntime
import os

// MARK: - ManifoldMCPHost

/// An MCP **server** that exposes a running ManifoldKit app's conversation
/// history, RAG document corpus, and turn-sending capability to external MCP
/// clients (Claude Desktop, other agents, CI tooling).
///
/// ## Opt-in by design
///
/// `ManifoldMCPHost` does not start automatically. Host apps wire it up
/// explicitly — typically inside an `@main` entry point or app delegate —
/// after the persistence stack is ready:
///
/// ```swift
/// let host = ManifoldMCPHost(
///     sessionStore: bootstrap.sessionStore,
///     messageStore: bootstrap.messageStore,
///     conversationRuntime: runtime,
///     ragService: ragService,   // optional
///     serverName: "MyApp MCP Host"
/// )
/// let transport = MCPHostStdioTransport()
/// try await host.run(transport: transport)
/// ```
///
/// ## Supported MCP methods
///
/// **Handshake**
/// - `initialize` → returns capabilities including `tools` and `resources`
/// - `notifications/initialized` (client notification, acknowledged silently)
///
/// **Resources**
/// - `resources/list` → conversation sessions + RAG documents
/// - `resources/read` → message list for a session, or document metadata
///
/// **Tools**
/// - `tools/list` → `list_sessions`, `send_message`, `search_documents`
/// - `tools/call` → dispatches to the named tool implementation
///
/// ## HTTP/SSE transport
///
/// For Claude Desktop's streamable-HTTP configuration and remote MCP clients
/// that cannot launch the host as a subprocess, use ``MCPHostHTTPTransport``
/// instead of ``MCPHostStdioTransport`` (#1842):
///
/// ```swift
/// let transport = try MCPHostHTTPTransport(port: 8765)
/// try await transport.start()
/// try await host.run(transport: transport)
/// ```
///
/// stdio remains the default for local single-client use.
///
/// ## Concurrency
///
/// `ManifoldMCPHost` is an `actor` so every incoming request is serialised.
/// Heavy work (session fetches, generation) hops off-actor via `await`.
/// The `run(transport:)` call blocks until the transport closes.
public actor ManifoldMCPHost {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// MCP protocol version advertised in the initialize response.
        public var protocolVersion: String
        /// Human-readable server name returned in `serverInfo`.
        public var serverName: String
        /// Semantic version returned in `serverInfo`.
        public var serverVersion: String
        /// Hard cap on bytes accepted in a single incoming message. Defends
        /// against clients that send unexpectedly large payloads.
        public var maxMessageBytes: Int
        /// Maximum JSON nesting depth accepted from clients.
        public var maxJSONNestingDepth: Int

        public init(
            protocolVersion: String = "2025-03-26",
            serverName: String = "ManifoldKit MCP Host",
            serverVersion: String = "1.0.0",
            maxMessageBytes: Int = 4 * 1024 * 1024,
            maxJSONNestingDepth: Int = 32
        ) {
            self.protocolVersion = protocolVersion
            self.serverName = serverName
            self.serverVersion = serverVersion
            self.maxMessageBytes = maxMessageBytes
            self.maxJSONNestingDepth = maxJSONNestingDepth
        }
    }

    // MARK: - Dependencies

    private let sessionStore: any SessionStore
    private let messageStore: any MessageStore
    private let conversationRuntime: ConversationRuntime
    private let ragService: RAGService?
    private let configuration: Configuration

    // MARK: - Init

    /// - Parameters:
    ///   - serverName: Human-readable server name. When explicitly supplied
    ///     (non-`nil`), it takes precedence over `configuration.serverName`
    ///     — it overwrites that one field on the given configuration rather
    ///     than being silently discarded. Leave it `nil` (the default) to
    ///     use `configuration.serverName` (or `Configuration`'s own default,
    ///     `"ManifoldKit MCP Host"`, when `configuration` is also `nil`).
    ///   - configuration: Full configuration bundle (message-size caps, JSON
    ///     nesting depth, protocol/server version, etc). Defaults to
    ///     `Configuration()` when omitted.
    public init(
        sessionStore: any SessionStore,
        messageStore: any MessageStore,
        conversationRuntime: ConversationRuntime,
        ragService: RAGService? = nil,
        serverName: String? = nil,
        configuration: Configuration? = nil
    ) {
        self.sessionStore = sessionStore
        self.messageStore = messageStore
        self.conversationRuntime = conversationRuntime
        self.ragService = ragService
        var config = configuration ?? Configuration()
        if let serverName {
            config.serverName = serverName
        }
        self.configuration = config
    }

    // MARK: - Run loop

    /// Begins serving MCP requests over `transport`. Returns when the transport
    /// closes or the task is cancelled.
    ///
    /// This method blocks the caller for the lifetime of the transport
    /// connection. Wrap it in a `Task { }` when you need concurrent work to
    /// proceed while the server is running.
    public func run(transport: any MCPHostTransport) async throws {
        let codec = MCPJSONRPCCodec(
            maxMessageBytes: configuration.maxMessageBytes,
            maxJSONNestingDepth: configuration.maxJSONNestingDepth
        )

        do {
            for try await payload in transport.incomingMessages {
                if Task.isCancelled { break }
                let message: MCPJSONRPCMessage
                do {
                    message = try codec.decode(payload)
                } catch {
                    Log.inference.warning("ManifoldMCPHost: failed to decode incoming message: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                await handleMessage(message, transport: transport, codec: codec)
            }
        } catch is CancellationError {
            // Normal shutdown via task cancellation.
        } catch {
            Log.inference.warning("ManifoldMCPHost: transport error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Message dispatch

    private func handleMessage(
        _ message: MCPJSONRPCMessage,
        transport: any MCPHostTransport,
        codec: MCPJSONRPCCodec
    ) async {
        switch message {
        case .request(let id, let method, let params):
            await handleRequest(id: id, method: method, params: params, transport: transport, codec: codec)
        case .notification(let method, _):
            // `notifications/initialized` is the only notification clients send today;
            // the rest are ignored — the server has no outstanding requests to cancel.
            if method != "notifications/initialized" {
                Log.inference.debug("ManifoldMCPHost: ignoring notification '\(method, privacy: .public)'")
            }
        case .result, .error:
            // Unexpected — the host only receives server-initiated results when
            // it is acting as a client. Log and move on.
            Log.inference.warning("ManifoldMCPHost: received unexpected result/error frame from client")
        }
    }

    private func handleRequest(
        id: MCPRequestID,
        method: String,
        params: JSONSchemaValue?,
        transport: any MCPHostTransport,
        codec: MCPJSONRPCCodec
    ) async {
        let result: MCPJSONRPCMessage
        do {
            let responseValue = try await dispatch(method: method, params: params)
            result = .result(id: id, result: responseValue)
        } catch let mcpError as MCPHostError {
            result = .error(id: id, error: MCPJSONRPCErrorObject(
                code: mcpError.jsonRPCCode,
                message: mcpError.localizedDescription,
                data: nil
            ))
        } catch {
            result = .error(id: id, error: MCPJSONRPCErrorObject(
                code: -32603,
                message: "Internal error: \(error.localizedDescription)",
                data: nil
            ))
        }

        do {
            let payload = try codec.encode(result)
            try await transport.send(payload)
        } catch {
            Log.inference.error("ManifoldMCPHost: failed to send response for '\(method, privacy: .public)': \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Method dispatch

    private func dispatch(method: String, params: JSONSchemaValue?) async throws -> JSONSchemaValue? {
        switch method {
        case "initialize":
            return try await handleInitialize(params: params)
        case "resources/list":
            return try await handleResourcesList()
        case "resources/read":
            return try await handleResourcesRead(params: params)
        case "tools/list":
            return handleToolsList()
        case "tools/call":
            return try await handleToolsCall(params: params)
        default:
            throw MCPHostError.methodNotFound(method)
        }
    }

    // MARK: - initialize

    private func handleInitialize(params: JSONSchemaValue?) async throws -> JSONSchemaValue? {
        guard case .object(let p) = params,
              case .string(let clientVersion) = p["protocolVersion"] else {
            throw MCPHostError.invalidParams("initialize requires a protocolVersion field")
        }
        // MCP spec §2.1: if the client version does not match, respond with
        // the server's supported version rather than rejecting outright. The
        // client then decides whether to proceed or disconnect.
        if clientVersion != configuration.protocolVersion {
            let serverVersion = configuration.protocolVersion
            Log.inference.info(
                "ManifoldMCPHost: client requested version '\(clientVersion, privacy: .public)'; responding with '\(serverVersion, privacy: .public)'"
            )
        }

        return .object([
            "protocolVersion": .string(configuration.protocolVersion),
            "serverInfo": .object([
                "name": .string(configuration.serverName),
                "version": .string(configuration.serverVersion),
            ]),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
                "resources": .object([:]),
            ]),
        ])
    }

    // MARK: - resources/list

    private func handleResourcesList() async throws -> JSONSchemaValue? {
        var resources: [JSONSchemaValue] = []

        // Conversation sessions
        let sessions = try await sessionStore.fetchSessions()
        for session in sessions {
            resources.append(.object([
                "uri": .string("manifold://sessions/\(session.id.uuidString)"),
                "name": .string(session.title),
                "description": .string("Conversation session"),
                "mimeType": .string("application/json"),
            ]))
        }

        // RAG documents (when a RAGService is present)
        if let ragService {
            let documents = try await ragService.fetchDocuments()
            for doc in documents {
                resources.append(.object([
                    "uri": .string("manifold://documents/\(doc.id.uuidString)"),
                    "name": .string(doc.title),
                    "description": .string("RAG document (\(doc.fileType), \(doc.chunkCount) chunks)"),
                    "mimeType": .string("application/json"),
                ]))
            }
        }

        return .object(["resources": .array(resources)])
    }

    // MARK: - resources/read

    private func handleResourcesRead(params: JSONSchemaValue?) async throws -> JSONSchemaValue? {
        guard case .object(let p) = params,
              case .string(let uri) = p["uri"] else {
            throw MCPHostError.invalidParams("resources/read requires a 'uri' field")
        }

        if uri.hasPrefix("manifold://sessions/") {
            return try await readSessionResource(uri: uri)
        } else if uri.hasPrefix("manifold://documents/") {
            return try await readDocumentResource(uri: uri)
        } else {
            throw MCPHostError.resourceNotFound(uri)
        }
    }

    private func readSessionResource(uri: String) async throws -> JSONSchemaValue? {
        let idString = String(uri.dropFirst("manifold://sessions/".count))
        guard let sessionID = UUID(uuidString: idString) else {
            throw MCPHostError.invalidParams("Invalid session UUID in URI: \(uri)")
        }

        let sessions = try await sessionStore.fetchSessions()
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            throw MCPHostError.resourceNotFound(uri)
        }

        let messages = try await messageStore.fetchMessages(for: sessionID)
        let iso = ISO8601DateFormatter()
        let messageValues: [JSONSchemaValue] = messages.map { msg in
            .object([
                "id": .string(msg.id.uuidString),
                "role": .string(msg.role.rawValue),
                "content": .string(msg.content),
                "timestamp": .string(iso.string(from: msg.timestamp)),
            ])
        }

        let content: JSONSchemaValue = .object([
            "sessionID": .string(session.id.uuidString),
            "title": .string(session.title),
            "createdAt": .string(iso.string(from: session.createdAt)),
            "updatedAt": .string(iso.string(from: session.updatedAt)),
            "messageCount": .number(Double(messages.count)),
            "messages": .array(messageValues),
        ])

        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string("application/json"),
                    "text": .string(jsonStringify(content)),
                ])
            ])
        ])
    }

    private func readDocumentResource(uri: String) async throws -> JSONSchemaValue? {
        guard let ragService else {
            throw MCPHostError.resourceNotFound(uri)
        }
        let idString = String(uri.dropFirst("manifold://documents/".count))
        guard let documentID = UUID(uuidString: idString) else {
            throw MCPHostError.invalidParams("Invalid document UUID in URI: \(uri)")
        }

        let documents = try await ragService.fetchDocuments()
        guard let doc = documents.first(where: { $0.id == documentID }) else {
            throw MCPHostError.resourceNotFound(uri)
        }

        let iso = ISO8601DateFormatter()
        let content: JSONSchemaValue = .object([
            "id": .string(doc.id.uuidString),
            "title": .string(doc.title),
            "fileType": .string(doc.fileType),
            "chunkCount": .number(Double(doc.chunkCount)),
            "indexedAt": .string(iso.string(from: doc.indexedAt)),
            "sourceURL": .string(doc.sourceURL.absoluteString),
        ])

        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string("application/json"),
                    "text": .string(jsonStringify(content)),
                ])
            ])
        ])
    }

    // MARK: - tools/list

    private func handleToolsList() -> JSONSchemaValue? {
        var tools: [JSONSchemaValue] = [
            .object([
                "name": .string("list_sessions"),
                "description": .string("Lists all conversation sessions in the app."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([]),
                ]),
            ]),
            .object([
                "name": .string("send_message"),
                "description": .string("Sends a user message to a conversation session and returns the assistant reply."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the target session."),
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("The user message to send."),
                        ]),
                    ]),
                    "required": .array([.string("session_id"), .string("text")]),
                ]),
            ]),
        ]

        if ragService != nil {
            tools.append(.object([
                "name": .string("search_documents"),
                "description": .string("Searches the RAG document corpus and returns the most relevant passages."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("The search query."),
                        ]),
                        "limit": .object([
                            "type": .string("number"),
                            "description": .string("Maximum number of passages to return (default: 5)."),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
            ]))
        }

        return .object(["tools": .array(tools)])
    }

    // MARK: - tools/call

    private func handleToolsCall(params: JSONSchemaValue?) async throws -> JSONSchemaValue? {
        guard case .object(let p) = params,
              case .string(let name) = p["name"] else {
            throw MCPHostError.invalidParams("tools/call requires a 'name' field")
        }

        let args: [String: JSONSchemaValue]
        if case .object(let a) = p["arguments"] {
            args = a
        } else {
            args = [:]
        }

        switch name {
        case "list_sessions":
            return try await toolListSessions()
        case "send_message":
            return try await toolSendMessage(args: args)
        case "search_documents":
            return try await toolSearchDocuments(args: args)
        default:
            throw MCPHostError.toolNotFound(name)
        }
    }

    // MARK: Tool: list_sessions

    private func toolListSessions() async throws -> JSONSchemaValue? {
        // Fetch failures are reported in-band via `isError` (per the MCP tool
        // result convention) rather than as a JSON-RPC protocol error, so a
        // client/LLM can see and potentially recover from a store failure
        // instead of the request simply failing opaquely.
        do {
            let sessions = try await sessionStore.fetchSessions()
            let list: [JSONSchemaValue] = sessions.map { session in
                .object([
                    "id": .string(session.id.uuidString),
                    "title": .string(session.title),
                    "updatedAt": .string(ISO8601DateFormatter().string(from: session.updatedAt)),
                ])
            }
            let text = jsonStringify(.array(list))
            return .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(text)])
                ]),
                "isError": .bool(false),
            ])
        } catch {
            Log.inference.warning("ManifoldMCPHost: list_sessions failed: \(error.localizedDescription, privacy: .public)")
            return .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string("list_sessions failed: \(error.localizedDescription)")])
                ]),
                "isError": .bool(true),
            ])
        }
    }

    // MARK: Tool: send_message

    private func toolSendMessage(args: [String: JSONSchemaValue]) async throws -> JSONSchemaValue? {
        guard case .string(let sessionIDString) = args["session_id"],
              let sessionID = UUID(uuidString: sessionIDString) else {
            throw MCPHostError.invalidParams("send_message requires a valid 'session_id' UUID")
        }
        guard case .string(let text) = args["text"], !text.isEmpty else {
            throw MCPHostError.invalidParams("send_message requires a non-empty 'text' field")
        }

        let input = TurnInput(
            sessionID: sessionID,
            kind: .send(text: text),
            config: TurnConfig()
        )

        let turn = try await conversationRuntime.processTurnWithOutcome(input)
        let replyText: String
        let isError: Bool
        if let turn {
            if let outcome = await collectOutcome(from: turn, timeout: .seconds(120)) {
                if let error = outcome.error {
                    replyText = "send_message failed: \(error.localizedDescription)"
                    isError = true
                } else if outcome.reason == .cancelled {
                    replyText = "send_message was cancelled before it produced a reply."
                    isError = true
                } else {
                    replyText = outcome.finalText.isEmpty ? "(no response)" : outcome.finalText
                    isError = false
                }
            } else {
                // Timed out waiting for a terminal outcome — the turn is still
                // running server-side; cancel it so it doesn't leak.
                await conversationRuntime.cancel(turn.streamHandle)
                replyText = "send_message timed out waiting for a reply after 120s."
                isError = true
            }
        } else {
            replyText = "send_message could not start a turn for this session."
            isError = true
        }

        return .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(replyText)])
            ]),
            "isError": .bool(isError),
        ])
    }

    private func collectOutcome(
        from turn: ConversationTurnHandle,
        timeout: Duration
    ) async -> ConversationTurnOutcome? {
        await withTaskGroup(of: ConversationTurnOutcome?.self) { group in
            group.addTask {
                await turn.outcome
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return nil
                } catch {
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Tool: search_documents

    private func toolSearchDocuments(args: [String: JSONSchemaValue]) async throws -> JSONSchemaValue? {
        guard let ragService else {
            throw MCPHostError.toolNotFound("search_documents")
        }
        guard case .string(let query) = args["query"], !query.isEmpty else {
            throw MCPHostError.invalidParams("search_documents requires a non-empty 'query' field")
        }

        let limit: Int
        if case .number(let l) = args["limit"], l > 0 {
            limit = Int(l)
        } else {
            limit = 5
        }

        do {
            let result = try await ragService.retrieve(query: query, limit: limit)
            let passages = result.citations.map { citation in
                "[\(citation.documentTitle)]\n\(citation.snippet)"
            }.joined(separator: "\n\n---\n\n")

            let responseText = passages.isEmpty ? "No relevant passages found." : passages
            return .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(responseText)])
                ]),
                "isError": .bool(false),
            ])
        } catch {
            Log.inference.warning("ManifoldMCPHost: search_documents failed: \(error.localizedDescription, privacy: .public)")
            return .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string("search_documents failed: \(error.localizedDescription)")])
                ]),
                "isError": .bool(true),
            ])
        }
    }

    // MARK: - JSON helpers

    private func jsonStringify(_ value: JSONSchemaValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let v):
            return v ? "true" : "false"
        case .integer(let v):
            return String(v)
        case .number(let v):
            return String(v)
        case .string(let v):
            // JSON string escaping per RFC 8259 §7. Must escape backslash, double-quote,
            // and all C0 control characters (U+0000–U+001F). The named escapes (\n, \r,
            // \t) are preferred where they exist; the rest use \uXXXX.
            var escaped = ""
            escaped.reserveCapacity(v.utf16.count)
            for scalar in v.unicodeScalars {
                switch scalar.value {
                case 0x5C: escaped += "\\\\"     // backslash
                case 0x22: escaped += "\\\""     // double-quote
                case 0x0A: escaped += "\\n"      // newline
                case 0x0D: escaped += "\\r"      // carriage return
                case 0x09: escaped += "\\t"      // tab
                case 0x00...0x1F:                // remaining C0 control characters
                    escaped += String(format: "\\u%04x", scalar.value)
                default:
                    escaped += String(scalar)
                }
            }
            return "\"\(escaped)\""
        case .array(let values):
            return "[\(values.map(jsonStringify).joined(separator: ","))]"
        case .object(let pairs):
            let entries = pairs.sorted { $0.key < $1.key }.map {
                "\(jsonStringify(.string($0.key))):\(jsonStringify($0.value))"
            }
            return "{\(entries.joined(separator: ","))}"
        }
    }
}

// MARK: - MCPHostError

/// Errors thrown by ``ManifoldMCPHost`` request handlers.
public enum MCPHostError: Error, LocalizedError, Sendable {
    case methodNotFound(String)
    case invalidParams(String)
    case resourceNotFound(String)
    case toolNotFound(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .methodNotFound(let method):
            return "Method not found: \(method)"
        case .invalidParams(let detail):
            return "Invalid params: \(detail)"
        case .resourceNotFound(let uri):
            return "Resource not found: \(uri)"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .internalError(let detail):
            return "Internal error: \(detail)"
        }
    }

    /// JSON-RPC error code per the MCP / JSON-RPC 2.0 spec.
    var jsonRPCCode: Int {
        switch self {
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .resourceNotFound: return -32001
        case .toolNotFound: return -32002
        case .internalError: return -32603
        }
    }
}

// MARK: - MCPHostTransport protocol

/// Transport abstraction for the server side of an MCP connection.
///
/// The server reads incoming JSON-RPC frames from `incomingMessages` and
/// writes response frames via `send(_:)`. Two built-in implementations exist
/// (both macOS only): ``MCPHostStdioTransport`` for local subprocess clients
/// and ``MCPHostHTTPTransport`` for streamable-HTTP / SSE clients (#1842).
public protocol MCPHostTransport: Sendable {
    /// Inbound frames from the remote MCP client.
    var incomingMessages: AsyncThrowingStream<Data, Error> { get }
    /// Send a single JSON-RPC frame to the remote client.
    func send(_ payload: Data) async throws
}
