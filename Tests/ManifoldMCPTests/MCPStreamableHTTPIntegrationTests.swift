import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference
import ManifoldTestSupport

/// Integration tests for the streamable-HTTP MCP transport using MockURLProtocol.
/// These tests exercise the full session/transport stack without a real server.
final class MCPStreamableHTTPIntegrationTests: XCTestCase {
    /// Unique per-test-instance host so stubs never collide with other
    /// suites under `swift test --parallel` (AGENTS.md MockURLProtocol
    /// isolation rule — never `reset()` across suites).
    private let endpoint = URL(string: "https://mcp-\(UUID().uuidString.lowercased()).test/mcp/e2e")!

    override func setUp() {
        super.setUp()
        // The unique .test host has no real DNS entry; resolve it to a
        // public IP so the SSRF policy admits it.
        MCPSSRFPolicy._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        MockURLProtocol.unstub(url: endpoint)
        MCPSSRFPolicy._resolverForTesting = nil
        super.tearDown()
    }

    func test_streamableHTTPSessionSmoke() async throws {
        let keepAliveChunk = Data("event: ping\ndata: keepalive\n\n".utf8)
        let initializeResult = Data(
            """
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"E2E MCP","version":"1.0.0"},"capabilities":{"tools":{"listChanged":true}}}}
            """.utf8
        )
        let toolsListResult = Data(
            """
            {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"ping","description":"Echo ping","inputSchema":{"type":"object","properties":{"message":{"type":"string"}}}}]}}
            """.utf8
        )
        MockURLProtocol.stubSequence(url: endpoint, responses: [
            .asyncSSE(chunks: [keepAliveChunk, keepAliveChunk, keepAliveChunk], chunkDelay: 0.5, statusCode: 200),
            .immediate(data: initializeResult, statusCode: 200, headers: ["Content-Type": "application/json"]),
            .immediate(data: Data(), statusCode: 200, headers: ["Content-Type": "application/json"]),
            .immediate(data: toolsListResult, statusCode: 200, headers: ["Content-Type": "application/json"]),
        ])

        let descriptor = MCPServerDescriptor(
            displayName: "E2E MCP",
            transport: .streamableHTTP(endpoint: endpoint, headers: [:]),
            initializationTimeout: .seconds(2),
            dataDisclosure: "E2E smoke test server"
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)

        let codec = MCPJSONRPCCodec(maxMessageBytes: 4096, maxJSONNestingDepth: 16)
        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
            headers: [:],
            authorization: MCPNoAuthorization(),
            sseLimits: .default,
            maxMessageBytes: 4096,
            session: urlSession
        ))

        let session = MCPSession(
            descriptor: descriptor,
            transport: transport,
            codec: codec,
            requestTimeout: .seconds(2),
            maxConcurrentRequests: 4
        )

        let capabilities = try await withTimeout(.seconds(5)) {
            try await session.start()
        }
        XCTAssertEqual(capabilities.serverName, "E2E MCP")
        XCTAssertEqual(capabilities.serverVersion, "1.0.0")
        let response = try await withTimeout(.seconds(5)) {
            try await session.sendRequest(method: "tools/list", params: nil)
        }
        Task { await session.close() }
        guard case .object(let object)? = response,
              case .array(let tools)? = object["tools"],
              case .object(let firstTool) = tools.first,
              case .string(let firstToolName)? = firstTool["name"] else {
            XCTFail("Expected tools/list response with a tool named ping")
            return
        }
        XCTAssertEqual(firstToolName, "ping")
    }
}
