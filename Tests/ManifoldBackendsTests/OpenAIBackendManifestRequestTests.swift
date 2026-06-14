import XCTest
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Asserts that ``OpenAIBackend`` consults its manifest before serialising
/// the optional sampling parameters (`seed`, presence/frequency penalties,
/// `top_k`) on the wire. Reasoning models (`o1` family) reject `seed`
/// outright with HTTP 400 — the manifest gate is the load-bearing fix.
final class OpenAIBackendManifestRequestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        super.tearDown()
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Returns the JSON body sent on the most recent generate-call to
    /// `chatCompletionsURL`.
    private func capturedRequestJSON(for chatCompletionsURL: URL) throws -> [String: Any] {
        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatCompletionsURL })
        let request = try XCTUnwrap(captured, "no captured request to OpenAI completions endpoint")
        let body = try extractBody(from: request)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any],
            "request body did not parse as JSON object"
        )
    }

    private func extractBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        if let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) }
            }
            stream.close()
            return data
        }
        XCTFail("Request has neither httpBody nor httpBodyStream")
        return Data()
    }

    private func sseDoneChunk() -> Data {
        Data("data: [DONE]\n\n".utf8)
    }

    // MARK: - seed

    func test_gpt4oModel_emitsSeed_whenManifestSupportsIt() async throws {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)
        let baseURL = URL(string: "https://openai-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "gpt-4o")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(url: completionsURL, response: .sse(chunks: [sseDoneChunk()], statusCode: 200))
        addTeardownBlock { MockURLProtocol.unstub(url: completionsURL) }

        var config = GenerationConfig()
        config.seed = 42

        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { /* drain */ }

        let json = try capturedRequestJSON(for: completionsURL)
        XCTAssertEqual(json["seed"] as? Int, 42,
                       "gpt-4o accepts seed via the manifest; the wire body must include it")
    }

    func test_o1ReasoningModel_omitsSeed_whenManifestRejectsIt() async throws {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)
        let baseURL = URL(string: "https://openai-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "o1-mini")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(url: completionsURL, response: .sse(chunks: [sseDoneChunk()], statusCode: 200))
        addTeardownBlock { MockURLProtocol.unstub(url: completionsURL) }

        var config = GenerationConfig()
        config.seed = 42

        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { /* drain */ }

        let json = try capturedRequestJSON(for: completionsURL)
        XCTAssertNil(json["seed"],
                     "o1-mini rejects seed (HTTP 400) — the manifest gate must omit it from the wire body")
    }

    // MARK: - presence / frequency penalties

    func test_gpt4oModel_emitsPresenceAndFrequencyPenalties_whenManifestSupportsThem() async throws {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)
        let baseURL = URL(string: "https://openai-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "gpt-4o")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(url: completionsURL, response: .sse(chunks: [sseDoneChunk()], statusCode: 200))
        addTeardownBlock { MockURLProtocol.unstub(url: completionsURL) }

        var config = GenerationConfig()
        config.presencePenalty = 0.5
        config.frequencyPenalty = 0.25

        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { /* drain */ }

        let json = try capturedRequestJSON(for: completionsURL)
        let presence = try XCTUnwrap(json["presence_penalty"] as? Double, "presence_penalty must be present for chat models")
        let frequency = try XCTUnwrap(json["frequency_penalty"] as? Double, "frequency_penalty must be present for chat models")
        XCTAssertEqual(presence, 0.5, accuracy: 1e-6)
        XCTAssertEqual(frequency, 0.25, accuracy: 1e-6)
    }

    func test_o1ReasoningModel_omitsPenalties_whenManifestRejectsThem() async throws {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)
        let baseURL = URL(string: "https://openai-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "o1")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(url: completionsURL, response: .sse(chunks: [sseDoneChunk()], statusCode: 200))
        addTeardownBlock { MockURLProtocol.unstub(url: completionsURL) }

        var config = GenerationConfig()
        config.presencePenalty = 0.5
        config.frequencyPenalty = 0.25

        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { /* drain */ }

        let json = try capturedRequestJSON(for: completionsURL)
        XCTAssertNil(json["presence_penalty"],
                     "o1 reasoning models reject presence_penalty — manifest must omit it")
        XCTAssertNil(json["frequency_penalty"],
                     "o1 reasoning models reject frequency_penalty — manifest must omit it")
    }
}
