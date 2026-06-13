import Foundation
import ManifoldInference

/// An ``EmbeddingBackend`` that computes embeddings through a local Ollama
/// server's `/api/embed` endpoint.
///
/// This is the embedding path used by the Glass Box research-session demo and
/// its live integration test (#1575). The default model is `nomic-embed-text`,
/// which is commonly available on a developer's local Ollama install. No model
/// download or file handling is involved — `loadModel(from:)` is a no-op
/// because Ollama owns the weights — so the backend reports itself loaded as
/// soon as it is constructed.
///
/// It lives in `ManifoldTestSupport` rather than a shipped backend family
/// because it exists to wire demo/test scenarios against a real retrieval
/// stack; production hosts use the on-device `LlamaEmbeddingBackend` (companion
/// package) or supply their own conformance.
///
/// - Note: `dimensions` is discovered lazily from the first successful embed
///   call (nomic-embed-text returns 768-dim vectors) and defaults to `768`
///   until then.
public final class OllamaEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {

    /// Default embedding model. Present on this project's local Ollama host.
    public static let defaultModel = "nomic-embed-text"

    private let baseURL: URL
    private let modelName: String
    private let session: URLSession

    private let lock = NSLock()
    private var _dimensions: Int = 768

    public var isModelLoaded: Bool { true }

    public var dimensions: Int {
        lock.withLock { _dimensions }
    }

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        modelName: String = OllamaEmbeddingBackend.defaultModel,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.session = session
    }

    /// No-op: Ollama hosts the weights, so there is no local file to load.
    public func loadModel(from url: URL) async throws {}

    public func unloadModel() {}

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let endpoint = baseURL.appendingPathComponent("api/embed")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            EmbedRequest(model: modelName, input: texts)
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingError.encodingFailed(underlying: error)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EmbeddingError.encodingFailed(
                underlying: NSError(
                    domain: "OllamaEmbeddingBackend",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: "Ollama /api/embed returned HTTP \(code)"]
                )
            )
        }

        let decoded: EmbedResponse
        do {
            decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        } catch {
            throw EmbeddingError.encodingFailed(underlying: error)
        }

        if let first = decoded.embeddings.first {
            lock.withLock { _dimensions = first.count }
        }
        return decoded.embeddings
    }

    // MARK: - Wire types

    private struct EmbedRequest: Encodable {
        let model: String
        let input: [String]
    }

    private struct EmbedResponse: Decodable {
        let embeddings: [[Float]]
    }
}
