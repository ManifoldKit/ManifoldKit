import XCTest
@testable import ManifoldCloudCore
@testable import ManifoldCloudSaaS
import ManifoldInference
import ManifoldTestSupport

/// Unit tests for the first-party cloud reranker (`CloudReranker`, #1920).
///
/// Stubs the hosted `/rerank` endpoint with `MockURLProtocol` so no live
/// network call is made. Per the suite isolation convention, every stub URL
/// uses a UUID-based `.test` host — never `MockURLProtocol.reset()` across
/// suites (its `canInit(with:)` is global state).
final class CloudRerankerTests: XCTestCase {

    private var endpoint: URL!
    private var session: URLSession!

    private var previousResolver: ((String) async -> [String]?)?

    override func setUp() {
        super.setUp()
        endpoint = URL(string: "https://rerank-\(UUID().uuidString).test/v2/rerank")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        // pinnedData runs DNSRebindingGuard before MockURLProtocol; stub a
        // public IP so pre-flight passes without touching the real resolver.
        previousResolver = DNSRebindingGuard._resolverForTesting
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = previousResolver
        previousResolver = nil
        if let endpoint {
            MockURLProtocol.unstub(url: endpoint)
        }
        endpoint = nil
        session = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeHit(text: String, score: Float) -> VectorSearchHit {
        VectorSearchHit(
            chunk: DocumentChunk(documentID: UUID(), text: text, chunkIndex: 0),
            documentTitle: "doc",
            score: score
        )
    }

    private func reranker(apiKey: String = "test-key") -> CloudReranker {
        CloudReranker(apiKey: apiKey, baseURL: endpoint, model: "rerank-test", urlSession: session)
    }

    private func rerankResponse(_ pairs: [(index: Int, score: Float)]) -> Data {
        let results = pairs.map { "{\"index\":\($0.index),\"relevance_score\":\($0.score)}" }
        let json = "{\"results\":[\(results.joined(separator: ","))]}"
        return Data(json.utf8)
    }

    // MARK: - Tests

    /// The reranker maps API relevance scores back onto each hit and reorders
    /// by descending relevance — even when the API order INVERTS the first-stage
    /// cosine order.
    func test_rerank_mapsApiScoresAndReorders() async throws {
        // First-stage cosine order: A (0.9) > B (0.5) > C (0.1).
        let candidates = [
            makeHit(text: "alpha", score: 0.9),
            makeHit(text: "bravo", score: 0.5),
            makeHit(text: "charlie", score: 0.1),
        ]

        // API INVERTS the order: C is most relevant, then B, then A.
        MockURLProtocol.stub(
            url: endpoint,
            response: .immediate(
                data: rerankResponse([
                    (index: 2, score: 0.95),
                    (index: 1, score: 0.60),
                    (index: 0, score: 0.05),
                ]),
                statusCode: 200
            )
        )

        let result = try await reranker().rerank(query: "q", candidates: candidates, limit: 3)

        XCTAssertEqual(result.map(\.chunk.text), ["charlie", "bravo", "alpha"],
                       "Output order must follow the API relevance scores, not the cosine order")
        XCTAssertEqual(result.map(\.score), [0.95, 0.60, 0.05],
                       "Each hit must carry the API-returned relevance score")
    }

    /// `limit` truncates after the API-driven reorder.
    func test_rerank_respectsLimit() async throws {
        let candidates = [
            makeHit(text: "alpha", score: 0.9),
            makeHit(text: "bravo", score: 0.5),
            makeHit(text: "charlie", score: 0.1),
        ]
        MockURLProtocol.stub(
            url: endpoint,
            response: .immediate(
                data: rerankResponse([
                    (index: 2, score: 0.95),
                    (index: 1, score: 0.60),
                    (index: 0, score: 0.05),
                ]),
                statusCode: 200
            )
        )

        let result = try await reranker().rerank(query: "q", candidates: candidates, limit: 2)
        XCTAssertEqual(result.map(\.chunk.text), ["charlie", "bravo"])
    }

    /// An HTTP error surfaces as a throw — `RAGService`'s existing graceful
    /// fallback then preserves the first-stage order (not re-tested here).
    func test_rerank_throwsOnHttpError() async throws {
        let candidates = [makeHit(text: "alpha", score: 0.9)]
        MockURLProtocol.stub(
            url: endpoint,
            response: .immediate(data: Data("{\"error\":\"boom\"}".utf8), statusCode: 500)
        )

        do {
            _ = try await reranker().rerank(query: "q", candidates: candidates, limit: 1)
            XCTFail("Expected rerank to throw on HTTP 500")
        } catch {
            // Surface as a structured error; any throw satisfies the contract.
            XCTAssertNotNil(error)
        }
    }

    /// An empty API key leaves the reranker not ready, keeping `RAGService` on
    /// its pre-rerank retrieval path.
    func test_isReady_falseWithoutKey() {
        XCTAssertFalse(reranker(apiKey: "").isReady)
        XCTAssertTrue(reranker(apiKey: "sk-present").isReady)
    }
}
