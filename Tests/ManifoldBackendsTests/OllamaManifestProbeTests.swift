import XCTest
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
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

    // MARK: - Vision capability from /api/show

    /// A model whose `/api/show` capabilities list includes `"vision"` must
    /// flip `supportsVision` on the backend's live capabilities and set the
    /// probed `isVisionModel` flag. Mirrors the thinking-detection path.
    func test_capabilities_detectsVisionFromCapabilitiesList() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "qwen2.5vl:3b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(
                    capabilities: ["completion", "vision"],
                    modelInfo: ["context_length": 32_768]
                ),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        XCTAssertFalse(backend.capabilities.supportsVision,
                       "supportsVision must default to false before any load/probe")

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        XCTAssertTrue(backend.isVisionModel,
                      "capabilities ['vision'] must set the probed isVisionModel flag")
        XCTAssertTrue(backend.capabilities.supportsVision,
                      "capabilities ['vision'] must flip supportsVision on the live capabilities")
    }

    /// A text-only model (no `"vision"` in capabilities) must leave
    /// `supportsVision == false`.
    func test_capabilities_textOnlyModelDoesNotAdvertiseVision() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.2:3b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(
                    capabilities: ["completion"],
                    modelInfo: ["context_length": 8_192]
                ),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        XCTAssertFalse(backend.isVisionModel,
                       "a model without 'vision' in capabilities must not be flagged vision-capable")
        XCTAssertFalse(backend.capabilities.supportsVision,
                       "text-only model must report supportsVision == false")
    }

    /// `unloadModel()` must reset the probed vision flag so a subsequent text
    /// model load on the same instance doesn't inherit a stale `true`.
    func test_unload_resetsVisionFlag() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "moondream:1.8b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(capabilities: ["completion", "vision"]),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isVisionModel)

        backend.unloadModel()
        XCTAssertFalse(backend.isVisionModel,
                       "unloadModel must clear the probed vision flag")
        XCTAssertFalse(backend.capabilities.supportsVision)
    }

    // MARK: - Tool capability from /api/show

    /// A model whose `/api/show` capabilities list includes `"tools"` keeps
    /// `supportsToolCalling == true` after the probe.
    func test_capabilities_detectsToolsFromCapabilitiesList() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.1:8b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(capabilities: ["completion", "tools"]),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        XCTAssertTrue(backend.capabilities.supportsToolCalling,
                      "capabilities ['tools'] must keep supportsToolCalling on the live capabilities")
    }

    /// A model whose successful probe omits `"tools"` (e.g. gemma3:4b) must
    /// withdraw the tool-calling claim so callers get a truthful pre-flight
    /// instead of a generation-time HTTP 400 ("does not support tools").
    func test_capabilities_probedModelWithoutToolsWithdrawsToolCalling() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "gemma3:4b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(capabilities: ["completion", "vision"]),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        XCTAssertTrue(backend.capabilities.supportsToolCalling,
                      "supportsToolCalling must default to true before any load/probe")

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        XCTAssertFalse(backend.capabilities.supportsToolCalling,
                       "a successful probe whose capabilities omit 'tools' must withdraw supportsToolCalling")
        XCTAssertEqual(backend.manifest?.supportsTools, false,
                       "the ModelManifest must carry the same probed value — not a stale hardcoded true")
    }

    /// A pre-April-2025 Ollama server omits the `capabilities` key entirely
    /// (`json:"capabilities,omitempty"` upstream) — that shape must keep the
    /// historical `true` default, since such servers never advertise tools
    /// either way.
    func test_capabilities_absentCapabilitiesKeyKeepsToolCallingDefault() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.1:8b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: try! JSONSerialization.data(withJSONObject: ["model_info": ["context_length": 8_192]]),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        XCTAssertTrue(backend.capabilities.supportsToolCalling,
                      "a /api/show response with no capabilities key (pre-2025 server) must keep the true default")
    }

    /// A failed probe (HTTP 500) must NOT withdraw tool calling — only a
    /// successful probe may flip the historical `true` default, so a dead
    /// probe can't disable tools for models that support them.
    func test_capabilities_probeFailureKeepsToolCallingDefault() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.1:8b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(data: Data(), statusCode: 500)
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        XCTAssertTrue(backend.capabilities.supportsToolCalling,
                      "a failed /api/show probe must leave supportsToolCalling at the true default")
    }

    /// `unloadModel()` must reset the probed tools flag so a subsequent load
    /// on the same instance starts from the `true` default again.
    func test_unload_resetsToolsFlagToDefault() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "gemma3:4b")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(capabilities: ["completion"]),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertFalse(backend.capabilities.supportsToolCalling)

        backend.unloadModel()
        XCTAssertTrue(backend.capabilities.supportsToolCalling,
                      "unloadModel must restore the pre-probe supportsToolCalling default")
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

    /// When `/api/show` reports no `context_length`, the manifest must say so.
    /// It previously substituted this backend's own `num_ctx` allocation, which
    /// describes what we will *run with*, not what the model *is* — making a
    /// failed probe indistinguishable from a model that genuinely has that
    /// window. `capabilities` still surfaces num_ctx, where the meaning is
    /// honest.
    func test_manifest_contextWindowIsNilWhenShowReportsNoContextLength() async throws {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "mystery:latest")

        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: showResponse(capabilities: ["completion"]),
                statusCode: 200
            )
        )
        addTeardownBlock { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let manifest = try XCTUnwrap(backend.manifest)
        XCTAssertNil(manifest.contextWindow,
                     "No context_length in /api/show means the model's window is unknown — not num_ctx")
        XCTAssertGreaterThan(backend.capabilities.maxContextTokens, 0,
                             "capabilities must still resolve a usable window from num_ctx despite the unknown manifest")
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
