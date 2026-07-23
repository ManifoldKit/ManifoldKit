import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldTestSupport

final class MCPStreamableHTTPTransportTests: XCTestCase {
    /// Unique per-test-instance host so stubs never collide with other
    /// suites under `swift test --parallel` (AGENTS.md MockURLProtocol
    /// isolation rule — never `reset()` across suites).
    private let endpoint = URL(string: "https://mcp-\(UUID().uuidString.lowercased()).test/mcp")!

    override func setUp() {
        super.setUp()
        // The unique .test host has no real DNS entry; resolve it to a
        // public IP so the SSRF policy admits it. The DNS-rebinding test
        // overrides this with a private-IP resolution for its own host.
        MCPSSRFPolicy._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        MockURLProtocol.unstub(url: endpoint)
        MCPSSRFPolicy._resolverForTesting = nil
        MCPURLSessionFactory.networkDisabled = false
        super.tearDown()
    }

    /// Requests this suite captured for its own unique host — the global
    /// `capturedRequests` list is process-wide and may contain entries
    /// from concurrently running suites.
    private var ownCapturedRequests: [URLRequest] {
        MockURLProtocol.capturedRequests.filter { $0.url?.host == endpoint.host }
    }

    func test_startDispatchesSSEPayloadsAsIncomingMessages() async throws {
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
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}".utf8)
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: response, statusCode: 200, headers: ["Content-Type": "application/json"]))

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
            headers: ["X-Client": "Manifold"],
            authorization: StaticAuthorization(),
            sseLimits: .default,
            maxMessageBytes: 2048,
            session: makeSession()
        ))

        try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8))

        var iterator = transport.incomingMessages.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, response)

        let post = try XCTUnwrap(ownCapturedRequests.first(where: { $0.httpMethod == "POST" }))
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-Client"), "Manifold")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        // Sabotage: removing the MCPStreamableHTTPTransport.send() call to MCPAuthorization.authorizationHeader() and never setting the Authorization header would fail the XCTAssertEqual on "Bearer test-token"

        await transport.close()
    }

    func test_startRetriesOnceAfterUnauthorized() async throws {
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

    func test_sendBlocksDNSRebindingDestinationBeforeRequest() async {
        let blockedHost = endpoint.host
        MCPSSRFPolicy._resolverForTesting = { host in
            host == blockedHost ? ["10.0.0.7"] : ["93.184.216.34"]
        }

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
            headers: [:],
            authorization: MCPNoAuthorization(),
            sseLimits: .default,
            maxMessageBytes: 2048,
            session: makeSession()
        ))

        await XCTAssertThrowsErrorAsync(
            try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8))
        ) { error in
            guard case .ssrfBlocked(let blockedURL) = error as? MCPError else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.host, endpoint.host)
        }
        XCTAssertTrue(ownCapturedRequests.isEmpty)
    }

    func test_startFailsWhenDefaultSessionBoundaryHasNetworkDisabled() async {
        MCPURLSessionFactory.networkDisabled = true

        let transport = MCPStreamableHTTPTransport(configuration: .init(
            endpoint: endpoint,
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

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        handler(error)
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
