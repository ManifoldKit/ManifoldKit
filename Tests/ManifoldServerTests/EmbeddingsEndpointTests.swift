#if Server
@testable import ManifoldServer
import ManifoldInference
import ManifoldTestSupport
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import XCTest

final class EmbeddingsEndpointTests: XCTestCase {

    // MARK: - Happy-path: single-string input

    func testSingleStringInputReturnsOneEmbedding() async throws {
        let provider = FakeEmbeddingProvider(vectors: [[0.1, 0.2, 0.3]])
        let app = ServerApp(backendProvider: provider).makeApplication()

        try await app.test(.router) { client in
            let body = try requestBody(EmbedRequest(model: "test-embed", input: .string("hello")))
            try await client.execute(uri: "/v1/embeddings", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Embeddings response must be JSON"
                )
                let embedResponse = try JSONDecoder().decode(EmbedResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(embedResponse.object, "list")
                XCTAssertEqual(embedResponse.model, "test-embed")
                XCTAssertEqual(embedResponse.data.count, 1)
                XCTAssertEqual(embedResponse.data[0].object, "embedding")
                XCTAssertEqual(embedResponse.data[0].index, 0)
                XCTAssertEqual(embedResponse.data[0].embedding, [0.1, 0.2, 0.3])
                // SABOTAGE: change data.count assertion to 2 to verify the test catches regressions
            }
        }
    }

    // MARK: - Happy-path: array input

    func testArrayInputReturnsOneEmbeddingPerText() async throws {
        let vectors: [[Float]] = [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]
        let provider = FakeEmbeddingProvider(vectors: vectors)
        let app = ServerApp(backendProvider: provider).makeApplication()

        try await app.test(.router) { client in
            let body = try requestBody(EmbedRequest(model: "test-embed", input: .strings(["a", "b", "c"])))
            try await client.execute(uri: "/v1/embeddings", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
                let embedResponse = try JSONDecoder().decode(EmbedResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(embedResponse.data.count, 3)
                XCTAssertEqual(embedResponse.data.map(\.index), [0, 1, 2])
                XCTAssertEqual(embedResponse.data[0].embedding, [0.1, 0.2])
                XCTAssertEqual(embedResponse.data[1].embedding, [0.3, 0.4])
                XCTAssertEqual(embedResponse.data[2].embedding, [0.5, 0.6])
                // SABOTAGE: swap assertion to embedResponse.data[0].embedding == [0.3, 0.4] to
                // verify ordering is asserted
            }
        }
    }

    // MARK: - Usage field

    func testUsageFieldIsPresent() async throws {
        let provider = FakeEmbeddingProvider(vectors: [[1.0]])
        let app = ServerApp(backendProvider: provider).makeApplication()

        try await app.test(.router) { client in
            // 20 chars ÷ 4 = 5 tokens
            let body = try requestBody(EmbedRequest(model: "m", input: .string("12345678901234567890")))
            try await client.execute(uri: "/v1/embeddings", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
                let embedResponse = try JSONDecoder().decode(EmbedResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(embedResponse.usage.promptTokens, 5)
                XCTAssertEqual(embedResponse.usage.totalTokens, 5)
            }
        }
    }

    // MARK: - 503 when no embedding backend

    func testNoEmbeddingBackendReturns503() async throws {
        // FakeBackendProvider only vends an InferenceBackend; it returns nil for embeddingBackend.
        let provider = NoEmbeddingProvider()
        let app = ServerApp(backendProvider: provider).makeApplication()

        try await app.test(.router) { client in
            let body = try requestBody(EmbedRequest(model: "any", input: .string("hi")))
            try await client.execute(uri: "/v1/embeddings", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "503 error must be JSON"
                )
                let envelope = try JSONDecoder().decode(ChatCompletionErrorEnvelope.self, from: Data(buffer: response.body))
                XCTAssertFalse(envelope.error.message.isEmpty)
                // SABOTAGE: change assertion to .ok to verify the test catches the 503 path
            }
        }
    }

    // MARK: - 400 for malformed body

    func testMalformedBodyReturns400OrError() async throws {
        let provider = NoEmbeddingProvider()
        let app = ServerApp(backendProvider: provider).makeApplication()

        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let malformedBody = ByteBuffer(string: "not json at all")
            try await client.execute(
                uri: "/v1/embeddings",
                method: .post,
                headers: headers,
                body: malformedBody
            ) { response in
                XCTAssertNotEqual(response.status, .ok)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Malformed-body error must be JSON"
                )
                XCTAssertNoThrow(
                    try JSONDecoder().decode(
                        ChatCompletionErrorEnvelope.self,
                        from: Data(buffer: response.body)
                    ),
                    "Malformed-body error must decode as ChatCompletionErrorEnvelope"
                )
            }
        }
    }

    // MARK: - Auth is enforced

    func testEmbeddingsEndpointRequiresBearerAuth() async throws {
        let provider = FakeEmbeddingProvider(vectors: [[0.1]])
        let server = ServerApp(
            configuration: ServerConfiguration(apiKey: "secret"),
            backendProvider: provider
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            let body = try requestBody(EmbedRequest(model: "m", input: .string("hi")))
            try await client.execute(uri: "/v1/embeddings", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }

            var headers = HTTPFields()
            headers[.authorization] = "Bearer secret"
            try await client.execute(uri: "/v1/embeddings", method: .post, headers: headers, body: body) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }
}

// MARK: - Test doubles

private func requestBody(_ request: EmbedRequest) throws -> ByteBuffer {
    ByteBuffer(bytes: try JSONEncoder().encode(request))
}

/// A `ServerBackendProvider` that vends a fixed set of vectors from a
/// `MockEmbeddingBackend`. Used for happy-path embedding tests.
private struct FakeEmbeddingProvider: ServerBackendProvider {
    let vectors: [[Float]]

    func listModels() async throws -> [String] { ["test-embed"] }

    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        MockInferenceBackend()
    }

    func embeddingBackend(for request: ServerBackendRequest) async -> (any EmbeddingBackend)? {
        MockEmbeddingBackend(vectors: vectors)
    }
}

/// A `ServerBackendProvider` that never vends an embedding backend, to exercise
/// the 503 path.
private struct NoEmbeddingProvider: ServerBackendProvider {
    func listModels() async throws -> [String] { [] }

    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        throw ServerError.backendUnavailable("inference not configured")
    }

    func embeddingBackend(for request: ServerBackendRequest) async -> (any EmbeddingBackend)? {
        nil
    }
}

/// Minimal `EmbeddingBackend` stub that returns a pre-configured set of
/// vectors. Each call to `embed` returns the next batch of `texts.count`
/// vectors from the fixture in order.
private final class MockEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    let vectors: [[Float]]
    var isModelLoaded: Bool { true }
    var dimensions: Int { vectors.first?.count ?? 0 }

    init(vectors: [[Float]]) {
        self.vectors = vectors
    }

    func loadModel(from url: URL) async throws {}

    func embed(_ texts: [String]) async throws -> [[Float]] {
        // Return as many vectors as there are texts; cycle if fewer vectors
        // than texts were provided (defensive — tests always match counts).
        guard !vectors.isEmpty else { return texts.map { _ in [] } }
        return texts.enumerated().map { index, _ in vectors[index % vectors.count] }
    }

    func unloadModel() {}
}

#endif
