import XCTest
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// HTTP-level coverage for ``DefaultWebSearchRuntime`` — the concrete
/// ``WebSearchRuntime`` that performs the OpenAI-Chat-Completions-shaped search
/// call moved out of `WebSearchToolSource` during the runtime-boundary refactor.
///
/// Uses `MockURLProtocol` with a UUID-based hostname per test (CLAUDE.md
/// isolation rule — never `MockURLProtocol.reset()` across suites) so stub
/// state never leaks between tests or suites.
@MainActor
final class DefaultWebSearchRuntimeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // `DefaultWebSearchRuntime.search` routes through
        // `ConnectAddressPinningDelegate.pinnedData`, which now runs
        // `DNSRebindingGuard.validate(url:)` as a pre-flight (this PR). The
        // fake `*.test` hostnames these tests stub via `MockURLProtocol` don't
        // resolve on a real resolver, so the guard would block every request
        // before it reaches the mock. Inject a deterministic public address,
        // matching the pattern used by `OpenAIBackendTests`/`ClaudeBackendTests`.
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        super.tearDown()
    }

    // MARK: - Test token provider

    private struct StaticTokenProvider: TokenProvider {
        let value: String
        func token() async throws -> String { value }
    }

    private struct ThrowingTokenProvider: TokenProvider {
        struct Boom: Error {}
        func token() async throws -> String { throw Boom() }
    }

    // MARK: - Helpers

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Unique base URL per test so stubs never collide with sibling suites.
    private func uniqueBaseURL() -> String {
        "https://websearch-\(UUID().uuidString).test/v1"
    }

    private func chatCompletionsURL(for baseURL: String) -> URL {
        URL(string: "\(baseURL)/chat/completions")!
    }

    // MARK: - Tests

    func test_search_happyPath_returnsAssistantContent() async throws {
        let baseURL = uniqueBaseURL()
        let endpoint = chatCompletionsURL(for: baseURL)
        defer { MockURLProtocol.unstub(url: endpoint) }

        let responseBody = """
        {"choices": [{"message": {"content": "Search result text."}}]}
        """.data(using: .utf8)!
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: responseBody, statusCode: 200))

        let runtime = DefaultWebSearchRuntime(
            baseURL: baseURL,
            tokenProvider: StaticTokenProvider(value: "secret-token"),
            session: makeMockSession()
        )

        let result = try await runtime.search(query: "what is the weather")
        XCTAssertEqual(result, "Search result text.")

        // The request must carry the bearer token, the model, and the
        // search_parameters payload moved verbatim from WebSearchToolSource.
        let captured = try XCTUnwrap(
            MockURLProtocol.capturedRequests.last(where: { $0.url == endpoint }),
            "no captured request to the search endpoint"
        )
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        let body = try XCTUnwrap(captured.httpBody ?? captured.bodyStreamData())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "grok-4.3")
        let searchParams = try XCTUnwrap(json["search_parameters"] as? [String: Any])
        XCTAssertEqual(searchParams["mode"] as? String, "on")
    }

    func test_search_nonOK_throwsHTTPFailure() async throws {
        let baseURL = uniqueBaseURL()
        let endpoint = chatCompletionsURL(for: baseURL)
        defer { MockURLProtocol.unstub(url: endpoint) }

        MockURLProtocol.stub(url: endpoint, response: .immediate(data: Data(), statusCode: 503))

        let runtime = DefaultWebSearchRuntime(
            baseURL: baseURL,
            tokenProvider: StaticTokenProvider(value: "t"),
            session: makeMockSession()
        )

        do {
            _ = try await runtime.search(query: "q")
            XCTFail("Expected HTTP failure to throw")
        } catch let error as WebSearchRuntimeError {
            XCTAssertEqual(error, .httpFailure(status: 503))
        }
    }

    func test_search_malformedResponse_returnsNoResults() async throws {
        let baseURL = uniqueBaseURL()
        let endpoint = chatCompletionsURL(for: baseURL)
        defer { MockURLProtocol.unstub(url: endpoint) }

        // Valid JSON but missing the choices/message/content path — the
        // audit-approved `try?` decoding degrades to "No results".
        let body = #"{"unexpected": true}"#.data(using: .utf8)!
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: body, statusCode: 200))

        let runtime = DefaultWebSearchRuntime(
            baseURL: baseURL,
            tokenProvider: StaticTokenProvider(value: "t"),
            session: makeMockSession()
        )

        let result = try await runtime.search(query: "q")
        XCTAssertEqual(result, "No results")
    }

    func test_search_invalidBaseURL_throwsInvalidBaseURL() async {
        // A base URL that cannot compose into a valid endpoint URL.
        let runtime = DefaultWebSearchRuntime(
            baseURL: "http://\u{7f}bad host",
            tokenProvider: StaticTokenProvider(value: "t"),
            session: makeMockSession()
        )

        do {
            _ = try await runtime.search(query: "q")
            XCTFail("Expected invalidBaseURL to throw")
        } catch let error as WebSearchRuntimeError {
            guard case .invalidBaseURL = error else {
                return XCTFail("Expected .invalidBaseURL, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_search_tokenProviderThrows_propagates() async {
        let baseURL = uniqueBaseURL()
        let runtime = DefaultWebSearchRuntime(
            baseURL: baseURL,
            tokenProvider: ThrowingTokenProvider(),
            session: makeMockSession()
        )

        do {
            _ = try await runtime.search(query: "q")
            XCTFail("Expected token provider error to propagate")
        } catch is ThrowingTokenProvider.Boom {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - URLRequest body helper

private extension URLRequest {
    /// Drains an `httpBodyStream` to `Data` for request-body assertions.
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        var data = Data()
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}
