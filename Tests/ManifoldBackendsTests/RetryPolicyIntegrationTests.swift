import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldFoundation
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

/// Integration tests verifying that `withExponentialBackoff` retries rate-limited
/// requests end-to-end through a real `URLSession` + `MockURLProtocol` stack.
///
/// Unlike the unit tests for `withExponentialBackoff` (which test timing math in
/// isolation), these tests wire a cloud backend to `MockURLProtocol` and confirm
/// the full retry loop — HTTP 429 → `CloudBackendError.rateLimited` → backoff →
/// re-request → eventual success or exhaustion.
final class RetryPolicyIntegrationTests: XCTestCase {

    private var session: URLSession!
    private var backend: OpenAIBackend!
    private var baseURL: URL!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        baseURL = URL(string: "https://retry-\(UUID().uuidString).test")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        backend = OpenAIBackend(urlSession: session)
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "test-model")
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        backend = nil
        session = nil
        super.tearDown()
    }

    // MARK: - Transient 429 then success

    /// Two 429 responses followed by a 200 with valid SSE data.
    /// The backend should retry through the 429s and yield tokens from the final response.
    func test_retries429ThenSucceeds() async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")

        // First two requests: 429 with Retry-After header.
        // Third request: 200 with a valid SSE stream.
        let successChunk = Data("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n".utf8)

        MockURLProtocol.stubSequence(url: completionsURL, responses: [
            .immediate(data: Data(), statusCode: 429, headers: ["Retry-After": "0.01"]),
            .immediate(data: Data(), statusCode: 429, headers: ["Retry-After": "0.01"]),
            .sse(chunks: [successChunk], statusCode: 200),
        ])

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        XCTAssertEqual(tokens, ["hello"], "Should receive token after retrying past 429s")

        // Verify three requests were made: 2 retries + 1 success.
        let requestCount = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == baseURL.host
        }.count
        XCTAssertEqual(requestCount, 3, "Expected 2 retried requests + 1 successful request")
    }

    // MARK: - Exhausted retries

    /// All attempts return 429. The backend should exhaust retries and throw rateLimited.
    func test_exhaustsRetriesAndThrows() async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")

        // Default maxRetries is 3, so 4 attempts total (initial + 3 retries).
        // Use short Retry-After to keep test fast.
        MockURLProtocol.stubSequence(url: completionsURL, responses: [
            .immediate(data: Data(), statusCode: 429, headers: ["Retry-After": "0.01"]),
            .immediate(data: Data(), statusCode: 429, headers: ["Retry-After": "0.01"]),
            .immediate(data: Data(), statusCode: 429, headers: ["Retry-After": "0.01"]),
            .immediate(data: Data(), statusCode: 429, headers: ["Retry-After": "0.01"]),
        ])

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        do {
            for try await _ in stream.events { }
            XCTFail("Should have thrown after exhausting retries")
        } catch {
            guard let error = extractCloudError(error) else { XCTFail("Expected CloudBackendError, got \(error)"); return }
            guard case .rateLimited = error else {
                XCTFail("Expected rateLimited error, got \(error)")
                return
            }
        }

        // All 4 attempts should have been made (initial + 3 retries).
        let requestCount = MockURLProtocol.capturedRequests.filter {
            $0.url?.host == baseURL.host
        }.count
        XCTAssertEqual(requestCount, 4, "Expected initial attempt + 3 retries = 4 total requests")
    }

    // MARK: - Non-retryable errors propagate immediately

    /// A 401 should not be retried — it should propagate as authenticationFailed immediately.
    func test_nonRetryableErrorDoesNotRetry() async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")

        MockURLProtocol.stub(url: completionsURL, response: .immediate(
            data: Data(), statusCode: 401
        ))

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        do {
            for try await _ in stream.events { }
            XCTFail("Should have thrown authenticationFailed")
        } catch {
            guard let error = extractCloudError(error) else { XCTFail("Expected CloudBackendError, got \(error)"); return }
            guard case .authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got \(error)")
                return
            }
        }

        // Only one request — no retries for auth errors.
        XCTAssertEqual(
            MockURLProtocol.capturedRequests.filter { $0.url?.host == baseURL.host }.count, 1,
            "Non-retryable errors must not trigger retries")
    }

    // MARK: - Retry-After header respected

    /// Verifies that backoff timing approximately matches the Retry-After header value.
    func test_retryAfterHeaderInfluencesTiming() async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        let successChunk = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8)

        // One 429 with a 0.1s Retry-After, then success.
        MockURLProtocol.stubSequence(url: completionsURL, responses: [
            .immediate(data: Data(), statusCode: 429, headers: ["Retry-After": "0.1"]),
            .sse(chunks: [successChunk], statusCode: 200),
        ])

        let stream = try backend.generate(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let start = ContinuousClock.now
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(tokens, ["ok"])
        // The Retry-After is 0.1s. Allow a generous range to avoid flakiness,
        // but ensure the delay actually happened (not instant).
        XCTAssertGreaterThan(elapsed, .milliseconds(50),
                             "Backoff delay should be at least ~100ms from Retry-After header")
        XCTAssertLessThan(elapsed, .seconds(5),
                          "Retry should complete well under 5s for a 0.1s Retry-After")
    }
}
