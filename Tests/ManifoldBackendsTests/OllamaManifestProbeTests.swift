#if Ollama
import XCTest
@testable import ManifoldBackends
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
#if Ollama
@testable import ManifoldOllama
#endif
#if CloudSaaS
@testable import ManifoldCloudSaaS
#endif
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests that ``OllamaBackend`` populates its ``ModelManifest`` from the
/// `/api/show` probe at load time. The legacy code only extracted a
/// thinking-capability boolean and hardcoded a Qwen3 marker fallback;
/// the manifest now also carries the model's real context window and the
/// auto-detected ``ThinkingMarkers``.
final class OllamaManifestProbeTests: XCTestCase {

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

    private func showResponse(
        capabilities: [String] = [],
        template: String? = nil,
        modelInfo: [String: Any]? = nil
    ) -> Data {
        var obj: [String: Any] = ["capabilities": capabilities]
        if let template { obj["template"] = template }
        if let modelInfo { obj["model_info"] = modelInfo }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Context window from /api/show

    func test_manifest_picksUpContextLengthFromCanonicalKey() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "qwen3:8b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(
                    capabilities: ["completion", "thinking"],
                    modelInfo: ["context_length": 32_768]
                ),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertEqual(manifest.contextWindow, 32_768,
                       "Ollama's /api/show context_length must drive the manifest's contextWindow")
        XCTAssertTrue(manifest.supportsThinking,
                      "capabilities ['thinking'] must be reflected on the manifest")
        XCTAssertEqual(manifest.producerKind, .lan)
    }

    func test_manifest_picksUpContextLengthFromArchPrefixedKey() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.1:8b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(
                    modelInfo: ["llama.context_length": 131_072]
                ),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertEqual(manifest.contextWindow, 131_072,
                       "Architecture-prefixed context_length keys must be honoured (llama.context_length)")
    }

    // MARK: - Thinking markers from template

    func test_manifest_capturesThinkingMarkersFromTemplate() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "qwen3:8b")

        let template = "{{ if .Thinking }}<think></think>{{ end }}{{ .Prompt }}"
        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(
                    capabilities: ["completion", "thinking"],
                    template: template,
                    modelInfo: ["context_length": 32_768]
                ),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertEqual(manifest.thinkingMarkers, .qwen3,
                       "Auto-detected thinking markers must round-trip into the manifest")
        XCTAssertTrue(manifest.supportsThinking)
    }

    // MARK: - Gemma 4 thinking backfill (#1664)

    /// Gemma 4 uses `<|turn>think\n` / `<|end_of_turn>` markers, which older
    /// Ollama releases do not advertise in `capabilities`. The probe must
    /// set `thinking = true` via the template backfill path so callers know
    /// the model is a reasoning variant even when the capabilities list is absent.
    func test_manifest_backfillsThinkingForGemma4Template() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "gemma4:12b")

        // Gemma 4 chat template — contains both marker halves but no
        // `capabilities: ["thinking"]` field, which is the pre-fix failure mode.
        let gemma4Template = """
            {%- if messages[0].role == 'system' -%}
            <|turn>system
            {{ messages[0].content }}<|end_of_turn>
            {%- endif -%}
            {%- for message in messages -%}
            <|turn>{{ message.role }}
            {{ message.content }}<|end_of_turn>
            {%- endfor -%}
            <|turn>think\n
            """
        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(
                    capabilities: ["completion"],
                    template: gemma4Template
                ),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertTrue(manifest.supportsThinking,
                      "Gemma 4 templates with <|turn>think\\n must set thinking=true even without capabilities:[thinking]")
        XCTAssertEqual(manifest.thinkingMarkers, .gemma4,
                       "Probe must surface Gemma 4 marker preset so the stream extractor routes reasoning content correctly")
    }

    // MARK: - Probe failure → conservative defaults

    func test_manifest_fallsBackOnShowProbeFailure() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "ghost:8b")

        // No stub registered for /api/show — the probe will fall through.
        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(url: showURL, response: .immediate(data: Data("not-json".utf8), statusCode: 200))
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertFalse(manifest.supportsThinking,
                       "non-JSON /api/show response must report non-thinking on the manifest")
        XCTAssertNil(manifest.thinkingMarkers,
                     "no markers detected → manifest carries nil")
    }
}
#endif
