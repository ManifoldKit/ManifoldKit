import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatTestSupport

final class MCPStreamableHTTPTransportTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        MCPURLSessionFactory.networkDisabled = false
        super.tearDown()
    }

    func test_startDispatchesSSEPayloadsAsIncomingMessages() async throws {
        let endpoint = URL(string: "https://example.com/mcp")!
        let sse = Data(
            """
            event: message
            data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}

            """.utf8
        )
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: sse, statusCode: 200))

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
            headers: [:],
            authorization: MCPNoAuthorization(),
            sseLimits: .default,
            maxMessageBytes: 2048,
            session: makeSession()
        ))

        try await transport.start()
        var iterator = transport.incomingMessages.makeAsyncIterator()
        let first = try await iterator.next()

        XCTAssertEqual(first, Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}".utf8))
        // Sabotage: removing the SSE "data:" line parser in MCPStreamableHTTPTransport.start() so it never yields data frames to incomingMessages would leave the iterator await hanging and time out the test

        await transport.close()
    }

    func test_sendPostsJSONAndYieldsResponseBody() async throws {
        let endpoint = URL(string: "https://example.com/mcp")!
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}".utf8)
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: response, statusCode: 200, headers: ["Content-Type": "application/json"]))

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
            headers: ["X-Client": "BaseChat"],
            authorization: StaticAuthorization(),
            sseLimits: .default,
            maxMessageBytes: 2048,
            session: makeSession()
        ))

        try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8))

        var iterator = transport.incomingMessages.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, response)

        let requests = MockURLProtocol.capturedRequests
        let post = try XCTUnwrap(requests.first(where: { $0.httpMethod == "POST" }))
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-Client"), "BaseChat")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        // Sabotage: removing the MCPStreamableHTTPTransport.send() call to MCPAuthorization.authorizationHeader() and never setting the Authorization header would fail the XCTAssertEqual on "Bearer test-token"

        await transport.close()
    }

    func test_startRetriesOnceAfterUnauthorized() async throws {
        let endpoint = URL(string: "https://example.com/mcp")!
        let sse = Data(
            """
            event: message
            data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}

            """.utf8
        )
        MockURLProtocol.stubSequence(url: endpoint, responses: [
            .immediate(data: Data(), statusCode: 401),
            .immediate(data: sse, statusCode: 200),
        ])
        let authorization = RetryingAuthorization()

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
            headers: [:],
            authorization: authorization,
            sseLimits: .default,
            maxMessageBytes: 2048,
            session: makeSession()
        ))

        try await transport.start()
        var iterator = transport.incomingMessages.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}".utf8))
        let unauthorizedCount = await authorization.unauthorizedCount
        XCTAssertEqual(unauthorizedCount, 1)
        // Sabotage: removing the 401-response branch in MCPStreamableHTTPTransport.start() that calls MCPAuthorization.handleUnauthorized() and retries the GET would leave unauthorizedCount at 0 and fail the XCTAssertEqual(unauthorizedCount, 1)

        await transport.close()
    }

    func test_sendRetriesOnceAfterUnauthorized() async throws {
        let endpoint = URL(string: "https://example.com/mcp")!
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}".utf8)
        MockURLProtocol.stubSequence(url: endpoint, responses: [
            .immediate(data: Data("expired".utf8), statusCode: 401),
            .immediate(data: response, statusCode: 200, headers: ["Content-Type": "application/json"]),
        ])
        let authorization = RetryingAuthorization()

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
            headers: [:],
            authorization: authorization,
            sseLimits: .default,
            maxMessageBytes: 2048,
            session: makeSession()
        ))

        try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8))
        var iterator = transport.incomingMessages.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, response)
        let unauthorizedCount = await authorization.unauthorizedCount
        XCTAssertEqual(unauthorizedCount, 1)
        // Sabotage: removing the 401-response branch in MCPStreamableHTTPTransport.send() that calls MCPAuthorization.handleUnauthorized() and retries the POST would leave unauthorizedCount at 0 and fail the XCTAssertEqual(unauthorizedCount, 1)

        await transport.close()
    }

    func test_startFailsWhenDefaultSessionBoundaryHasNetworkDisabled() async {
        MCPURLSessionFactory.networkDisabled = true

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: URL(string: "https://example.com/mcp")!,
            headers: [:],
            authorization: MCPNoAuthorization(),
            sseLimits: .default,
            maxMessageBytes: 2048
        ))

        do {
            try await transport.start()
            XCTFail("Expected networkUnavailable")
        } catch let error as MCPError {
            XCTAssertEqual(error, .networkUnavailable)
        } catch {
            XCTFail("Expected MCPError.networkUnavailable, got \(error)")
        }
    }

    func test_injectedSessionBypassesDefaultSessionBoundary() async throws {
        MCPURLSessionFactory.networkDisabled = true
        let endpoint = URL(string: "https://example.com/mcp")!
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}".utf8)
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: response, statusCode: 200, headers: ["Content-Type": "application/json"]))

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
            headers: [:],
            authorization: MCPNoAuthorization(),
            sseLimits: .default,
            maxMessageBytes: 2048,
            session: makeSession()
        ))

        try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8))

        var iterator = transport.incomingMessages.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, response)
        await transport.close()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct StaticAuthorization: MCPAuthorization {
    func authorizationHeader(for requestURL: URL) async throws -> String? {
        _ = requestURL
        return "Bearer test-token"
    }

    func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision {
        _ = statusCode
        _ = body
        return .fail(.authorizationFailed("unauthorized"))
    }
}

private actor RetryingAuthorization: MCPAuthorization {
    private(set) var unauthorizedCount: Int = 0

    func authorizationHeader(for requestURL: URL) async throws -> String? {
        _ = requestURL
        return "Bearer test-token"
    }

    func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision {
        _ = statusCode
        _ = body
        unauthorizedCount += 1
        return .retry
    }
}
