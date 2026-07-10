import Foundation
import ManifoldContract
import ManifoldCloudCore

/// A first-party cloud cross-encoder reranker conforming to ``Reranker``.
///
/// `CloudReranker` is the cloud counterpart to the on-device `LlamaReranker`
/// (from `ManifoldLlama`): it POSTs the query and the widened candidate set to
/// a hosted `/rerank` endpoint, maps the returned relevance scores back onto
/// each ``VectorSearchHit/score``, and returns the top `limit` hits in
/// descending relevance order. It plugs into the shipped ``Reranker`` seam
/// without any change to `RAGService` — the retriever already widens its
/// candidate pool and calls `rerank(query:candidates:limit:)` with graceful
/// fallback when the call throws.
///
/// One class covers both supported providers because the Cohere and Jina
/// `/rerank` request and response shapes are identical at the level we use:
/// the request is `{model, query, documents}` and the response is
/// `{results: [{index, relevance_score}]}`. Construct via the ``cohere`` /
/// ``jina`` presets, or pass an explicit `baseURL` + `model` for a compatible
/// endpoint.
///
/// ```swift
/// let reranker = CloudReranker.cohere(apiKey: cohereKey)
/// let rag = RAGConfiguration(
///     embeddingBackend: myEmbeddingBackend,
///     reranker: reranker
/// )
/// ```
///
/// - Note: API key handling mirrors the SaaS backends: the reranker reports
///   ``isReady`` as `false` while the key is empty, which keeps `RAGService`
///   on its pre-rerank path (no candidate widening, no network call).
public struct CloudReranker: Reranker {
    /// The hosted `/rerank` endpoint.
    private let baseURL: URL
    /// The provider rerank model identifier (e.g. `rerank-english-v3.0`).
    private let model: String
    private let apiKey: String
    private let urlSession: URLSession

    /// Cohere's recommended default rerank model.
    public static let cohereDefaultModel = "rerank-english-v3.0"
    /// Jina's recommended default rerank model.
    public static let jinaDefaultModel = "jina-reranker-v2-base-multilingual"

    /// Creates a cloud reranker for any Cohere-compatible `/rerank` endpoint.
    ///
    /// Prefer the ``cohere(apiKey:model:urlSession:)`` / ``jina(apiKey:model:urlSession:)``
    /// presets; this initializer is the escape hatch for self-hosted or
    /// alternative compatible endpoints.
    ///
    /// - Parameters:
    ///   - apiKey: The provider API key. An empty key leaves ``isReady`` `false`.
    ///   - baseURL: The full `/rerank` endpoint URL.
    ///   - model: The rerank model identifier.
    ///   - urlSession: The session to use. Pass `nil` for the shared pinned
    ///     session (`URLSessionProvider.pinned`); tests inject a `MockURLProtocol`
    ///     session here.
    public init(
        apiKey: String,
        baseURL: URL,
        model: String,
        urlSession: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.urlSession = urlSession ?? URLSessionProvider.pinned
    }

    /// Cohere `/rerank` preset (`https://api.cohere.com/v2/rerank`).
    public static func cohere(
        apiKey: String,
        model: String = cohereDefaultModel,
        urlSession: URLSession? = nil
    ) -> CloudReranker {
        CloudReranker(
            apiKey: apiKey,
            // Force-unwrap is safe: this is a compile-time constant literal URL.
            baseURL: URL(string: "https://api.cohere.com/v2/rerank")!,
            model: model,
            urlSession: urlSession
        )
    }

    /// Jina `/rerank` preset (`https://api.jina.ai/v1/rerank`).
    public static func jina(
        apiKey: String,
        model: String = jinaDefaultModel,
        urlSession: URLSession? = nil
    ) -> CloudReranker {
        CloudReranker(
            apiKey: apiKey,
            // Force-unwrap is safe: this is a compile-time constant literal URL.
            baseURL: URL(string: "https://api.jina.ai/v1/rerank")!,
            model: model,
            urlSession: urlSession
        )
    }

    /// `false` while the API key is empty, matching the SaaS backends' key
    /// handling. `RAGService` then keeps its pre-rerank retrieval path.
    public var isReady: Bool { !apiKey.isEmpty }

    public func rerank(
        query: String,
        candidates: [VectorSearchHit],
        limit: Int
    ) async throws -> [VectorSearchHit] {
        guard !candidates.isEmpty else { return [] }

        let documents = candidates.map(\.chunk.text)
        let requestBody = RerankRequest(model: model, query: query, documents: documents)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            Log.network.error("CloudReranker request encoding failed: \(error.localizedDescription, privacy: .public)")
            throw CloudBackendError.parseError("CloudReranker failed to encode request: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            // Route through pinnedData so DNS rebinding pre-flight, the
            // credentialed-host pin gate (H1), and connect-time IP pinning
            // all apply — same envelope as Ollama list/probe and web search.
            (data, response) = try await ConnectAddressPinningDelegate.pinnedData(
                for: request,
                on: urlSession
            )
        } catch let error as CloudBackendError {
            throw error
        } catch {
            Log.network.error("CloudReranker request failed: \(error.localizedDescription, privacy: .public)")
            throw CloudBackendError.networkError(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            Log.network.error("CloudReranker received a non-HTTP response")
            throw CloudBackendError.parseError("CloudReranker received a non-HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            Log.network.error("CloudReranker HTTP \(http.statusCode, privacy: .public)")
            throw CloudBackendError.serverError(statusCode: http.statusCode, message: body)
        }

        let decoded: RerankResponse
        do {
            decoded = try JSONDecoder().decode(RerankResponse.self, from: data)
        } catch {
            Log.network.error("CloudReranker response decoding failed: \(error.localizedDescription, privacy: .public)")
            throw CloudBackendError.parseError("CloudReranker failed to decode response: \(error.localizedDescription)")
        }

        // Map each returned (index, relevance_score) pair back onto its source
        // hit, rebuilding the hit with the cross-encoder score so downstream
        // citations surface the reranked relevance. Out-of-range indices are
        // skipped defensively rather than trapping.
        let reranked: [VectorSearchHit] = decoded.results.compactMap { result in
            guard candidates.indices.contains(result.index) else { return nil }
            let source = candidates[result.index]
            return VectorSearchHit(
                chunk: source.chunk,
                documentTitle: source.documentTitle,
                score: result.relevanceScore
            )
        }

        return Array(
            reranked
                .sorted { $0.score > $1.score }
                .prefix(limit)
        )
    }
}

// MARK: - Wire types

/// Cohere/Jina `/rerank` request payload (`{model, query, documents}`).
private struct RerankRequest: Encodable {
    let model: String
    let query: String
    let documents: [String]
}

/// Cohere/Jina `/rerank` response payload (`{results: [{index, relevance_score}]}`).
private struct RerankResponse: Decodable {
    struct Result: Decodable {
        let index: Int
        let relevanceScore: Float

        enum CodingKeys: String, CodingKey {
            case index
            case relevanceScore = "relevance_score"
        }
    }

    let results: [Result]
}
