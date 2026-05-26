#if CloudSaaS
import XCTest
import SwiftData
@testable import ManifoldBackends
@testable import ManifoldCloudCore
// ChatViewModel and SessionManagerViewModel live in ManifoldUI; testable import
// is needed to exercise the endpoint selection → load → generate pipeline that
// wires cloud backends through InferenceService.
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration tests for the cloud endpoint selection and generation pipeline.
///
/// Covers: endpoint selection → load → isModelLoaded, streaming generation via
/// MockURLProtocol, local ↔ cloud mutual exclusivity, session persistence of
/// the selected endpoint, and error paths (invalid URL, missing API key,
/// network failure).
///
/// All tests use MockURLProtocol with UUID-scoped hostnames so they run safely
/// in CI with no real network and no cross-suite stub collisions.
@MainActor
final class CloudEndpointSelectionIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var localBackend: MockInferenceBackend!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var cloudSession: URLSession!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }

        container = try makeInMemoryContainer()
        context = container.mainContext

        localBackend = MockInferenceBackend()
        cloudSession = Self.makeMockURLSession()

        let service = InferenceService()
        let localRef = localBackend!
        let cloudSessionRef = cloudSession!
        service.registerBackendFactory { _ in localRef }
        service.registerCloudBackendFactory { _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSessionRef)
        }

        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        vm = nil
        sessionManager = nil
        cloudSession = nil
        localBackend = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static func makeMockURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeLocalModel(name: String = "Local GGUF") -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).gguf",
            url: URL(fileURLWithPath: "/dev/null"),
            fileSize: 400_000_000,
            modelType: .gguf
        )
    }

    @discardableResult
    private func makeSession(title: String = "Test") async throws -> ChatSessionRecord {
        let session = try await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    private func persistEndpoint(_ record: APIEndpointRecord) throws {
        let endpoint = APIEndpoint(
            name: record.name,
            provider: record.provider,
            baseURL: record.baseURL,
            modelName: record.modelName
        )
        endpoint.id = record.id
        endpoint.createdAt = record.createdAt
        endpoint.isEnabled = record.isEnabled
        context.insert(endpoint)
        try context.save()
    }

    /// Builds SSE data chunks in the OpenAI format.
    private static func sseChunks(_ tokens: [String]) -> [Data] {
        var chunks = tokens.map { token in
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(token)\"}}]}\n\n".utf8)
        }
        chunks.append(Data("data: [DONE]\n\n".utf8))
        return chunks
    }

    /// Creates a fresh ChatViewModel wired to a custom cloud backend factory.
    private func makeViewModel(cloudFactory: @escaping CloudBackendFactory) -> ChatViewModel {
        let service = InferenceService()
        service.registerCloudBackendFactory(cloudFactory)
        let viewModel = ChatViewModel(inferenceService: service)
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        viewModel.configure(persistence: persistence)
        return viewModel
    }

    // MARK: - Select → Load → isModelLoaded

    func test_selectedEndpointAndLoadSelectedEndpoint_setsIsModelLoaded() async throws {
        let endpoint = APIEndpointRecord(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )
        try persistEndpoint(endpoint)

        vm.selectedEndpoint = endpoint
        await vm.loadSelectedEndpoint()

        XCTAssertEqual(vm.selectedEndpoint?.id, endpoint.id)
        XCTAssertTrue(vm.isModelLoaded)
        XCTAssertNil(vm.errorMessage)

        // Sabotage: without calling loadCloudEndpoint, isModelLoaded should be false.
        let freshVM = makeViewModel { [cloudSession] _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
        }
        freshVM.selectedEndpoint = endpoint
        XCTAssertFalse(freshVM.isModelLoaded, "Without load, isModelLoaded must be false")
    }

    // MARK: - Streaming Generation via MockURLProtocol

    func test_sendMessage_streamsCloudResponseViaMockURLProtocol() async throws {
        // UUID hostname isolates this stub from concurrently-running suites.
        // https:// is required for non-localhost endpoints per endpoint validation.
        let uniqueHost = UUID().uuidString + ".invalid"

        try await makeSession(title: "Cloud Chat")
        let endpoint = APIEndpointRecord(
            name: "Local LM Studio",
            provider: .lmStudio,
            baseURL: "https://\(uniqueHost):1234",
            modelName: "local-model"
        )
        try persistEndpoint(endpoint)

        let baseURL = try XCTUnwrap(URL(string: endpoint.baseURL))
        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(
            url: completionsURL,
            response: .sse(chunks: Self.sseChunks(["Hello", " cloud"]), statusCode: 200)
        )
        defer { MockURLProtocol.unstub(url: completionsURL) }

        vm.selectedEndpoint = endpoint
        await vm.loadCloudEndpoint(endpoint)
        XCTAssertTrue(vm.isModelLoaded)

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2)
        let user = try XCTUnwrap(vm.messages.first)
        let assistant = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.content, "Hello cloud")

        // Verify the mock actually intercepted the request.
        XCTAssertTrue(
            MockURLProtocol.capturedRequests.contains {
                $0.url?.absoluteString.hasPrefix(completionsURL.absoluteString) == true
            }
        )

        // Sabotage: without the SSE stub, sending should not produce an assistant message
        // with "Hello cloud" content.
        MockURLProtocol.unstub(url: completionsURL)
        let freshVM = makeViewModel { [cloudSession] _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
        }
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        freshVM.configure(persistence: persistence)
        try await makeSession(title: "Sabotage Chat")
        freshVM.selectedEndpoint = endpoint
        await freshVM.loadCloudEndpoint(endpoint)
        freshVM.inputText = "Hi"
        await freshVM.sendMessage()
        let sabotageAssistant = freshVM.messages.last
        XCTAssertNotEqual(
            sabotageAssistant?.content, "Hello cloud",
            "Without SSE stub, assistant should not produce the stubbed response"
        )
    }

    // MARK: - Mutual Exclusivity: local ↔ cloud

    func test_modelAndEndpointSelection_areMutuallyExclusive() {
        let localModel = makeLocalModel()
        let endpoint = APIEndpointRecord(
            name: "Cloud Endpoint",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )

        // Setting endpoint after model clears the model.
        vm.selectedModel = localModel
        vm.selectedEndpoint = endpoint
        XCTAssertNil(vm.selectedModel, "Setting endpoint should clear selectedModel")
        XCTAssertEqual(vm.selectedEndpoint?.id, endpoint.id)

        // Setting model after endpoint clears the endpoint.
        vm.selectedModel = localModel
        XCTAssertNil(vm.selectedEndpoint, "Setting model should clear selectedEndpoint")
        XCTAssertEqual(vm.selectedModel?.id, localModel.id)

        // Sabotage: setting model to nil should NOT auto-set endpoint.
        vm.selectedModel = nil
        XCTAssertNil(vm.selectedEndpoint, "Clearing model should not restore endpoint")
    }

    // MARK: - Session Persistence

    func test_sessionRestoresSelectedEndpoint() async throws {
        let endpointA = APIEndpointRecord(
            name: "Endpoint A",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )
        let endpointB = APIEndpointRecord(
            name: "Endpoint B",
            provider: .lmStudio,
            baseURL: "http://localhost:1234",
            modelName: "local-model"
        )
        try persistEndpoint(endpointA)
        try persistEndpoint(endpointB)
        vm.setAvailableEndpoints([endpointA, endpointB])

        // Session A selects endpoint A.
        try await makeSession(title: "Session A")
        vm.selectedEndpoint = endpointA
        try await vm.saveSettingsToSession()

        // Session B selects endpoint B.
        let sessionB = try await sessionManager.createSession(title: "Session B")
        sessionManager.activeSession = sessionB
        await vm.switchToSession(sessionB)
        vm.selectedEndpoint = endpointB
        try await vm.saveSettingsToSession()

        // Reload and switch back to session A — endpoint A should restore.
        await sessionManager.loadSessions()
        let freshA = try XCTUnwrap(sessionManager.sessions.first { $0.title == "Session A" })
        sessionManager.activeSession = freshA
        await vm.switchToSession(freshA)

        XCTAssertEqual(vm.selectedEndpoint?.id, endpointA.id)

        // Sabotage: remove endpoint A from available endpoints and verify
        // the session restore clears the selection gracefully.
        vm.setAvailableEndpoints([endpointB])
        await sessionManager.loadSessions()
        let freshA2 = try XCTUnwrap(sessionManager.sessions.first { $0.title == "Session A" })
        await vm.switchToSession(freshA2)
        XCTAssertNil(vm.selectedEndpoint, "Endpoint not restored when removed from available endpoints")
    }

    // MARK: - Switching local → cloud and back preserves session state

    func test_switchingLocalToCloudAndBack_preservesSessionState() async throws {
        let localModel = makeLocalModel()
        let endpoint = APIEndpointRecord(
            name: "Cloud Endpoint",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )
        try persistEndpoint(endpoint)
        vm.setAvailableEndpoints([endpoint])

        try await makeSession(title: "Switch Test")

        // Start with local model.
        vm.selectedModel = localModel
        await vm.loadSelectedModel()
        XCTAssertTrue(vm.isModelLoaded)
        XCTAssertNotNil(vm.selectedModel)
        XCTAssertNil(vm.selectedEndpoint)
        try await vm.saveSettingsToSession()

        // Switch to cloud endpoint.
        vm.selectedEndpoint = endpoint
        await vm.loadCloudEndpoint(endpoint)
        XCTAssertTrue(vm.isModelLoaded)
        XCTAssertNil(vm.selectedModel, "Local model should be cleared when cloud endpoint is selected")
        XCTAssertNotNil(vm.selectedEndpoint)
        try await vm.saveSettingsToSession()

        // Reload and verify cloud endpoint was persisted.
        await sessionManager.loadSessions()
        let freshSession = try XCTUnwrap(sessionManager.sessions.first { $0.title == "Switch Test" })
        await vm.switchToSession(freshSession)
        XCTAssertEqual(vm.selectedEndpoint?.id, endpoint.id)
        XCTAssertNil(vm.selectedModel)

        // Sabotage: switching back to the local model and saving should clear
        // the cloud endpoint from the session.
        vm.selectedModel = localModel
        XCTAssertNil(vm.selectedEndpoint, "Selecting local model should clear cloud endpoint")
        try await vm.saveSettingsToSession()
        await sessionManager.loadSessions()
        let freshSession2 = try XCTUnwrap(sessionManager.sessions.first { $0.title == "Switch Test" })
        await vm.switchToSession(freshSession2)
        XCTAssertNil(vm.selectedEndpoint, "After saving with local model, endpoint should not restore")
    }

    // MARK: - Error Paths

    func test_loadCloudEndpoint_invalidURL_surfacesError() async throws {
        let invalidEndpoint = APIEndpointRecord(
            name: "Bad URL",
            provider: .custom,
            baseURL: "http://foo\0bar",
            modelName: "model"
        )

        await vm.loadCloudEndpoint(invalidEndpoint)

        let errorMsg = try XCTUnwrap(vm.errorMessage)
        XCTAssertTrue(
            errorMsg.localizedCaseInsensitiveContains("invalid")
            || errorMsg.localizedCaseInsensitiveContains("url")
            || errorMsg.localizedCaseInsensitiveContains("connect"),
            "Error should mention invalid URL, got: \(errorMsg)"
        )
        XCTAssertFalse(vm.isModelLoaded)

        // Sabotage: a valid URL should not produce an invalid-URL error.
        let validEndpoint = APIEndpointRecord(
            name: "Valid URL",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "model"
        )
        let freshVM = makeViewModel { [cloudSession] _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
        }
        await freshVM.loadCloudEndpoint(validEndpoint)
        XCTAssertNil(freshVM.errorMessage, "Valid URL should not produce an error")
    }

    func test_loadCloudEndpoint_missingAPIKey_surfacesError() async throws {
        let claudeVM = makeViewModel { _ in
            ConfiguringClaudeCloudBackend(urlSession: Self.makeMockURLSession())
        }
        let claudeEndpoint = APIEndpointRecord(
            name: "Claude Endpoint",
            provider: .claude,
            baseURL: "https://api.anthropic.com",
            modelName: "claude-sonnet-4-20250514"
        )
        // Ensure no key is stored.
        try? KeychainService.delete(account: claudeEndpoint.keychainAccount)

        await claudeVM.loadCloudEndpoint(claudeEndpoint)

        let errorMsg = try XCTUnwrap(claudeVM.errorMessage)
        XCTAssertTrue(
            errorMsg.localizedCaseInsensitiveContains("api key")
            || errorMsg.localizedCaseInsensitiveContains("key"),
            "Error should mention missing API key, got: \(errorMsg)"
        )
        XCTAssertFalse(claudeVM.isModelLoaded)

        // Sabotage: an Ollama endpoint (no API key required) should load without
        // a missing-key error.
        let ollamaVM = makeViewModel { [cloudSession] _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
        }
        let ollamaEndpoint = APIEndpointRecord(
            name: "Ollama (no key)",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )
        await ollamaVM.loadCloudEndpoint(ollamaEndpoint)
        XCTAssertNil(ollamaVM.errorMessage, "Ollama endpoint should not require an API key")
    }

    func test_loadCloudEndpoint_networkError_surfacesError() async throws {
        let uniqueHost = UUID().uuidString + ".invalid"
        let probingSession = Self.makeMockURLSession()
        let networkVM = makeViewModel { _ in
            ConfiguringOpenAICloudBackend(
                urlSession: probingSession,
                probeOnLoad: true
            )
        }
        // https:// is required for non-localhost endpoints per endpoint validation.
        let networkEndpoint = APIEndpointRecord(
            name: "Flaky Endpoint",
            provider: .ollama,
            baseURL: "https://\(uniqueHost):11434",
            modelName: "llama3.2"
        )
        let networkBaseURL = try XCTUnwrap(URL(string: networkEndpoint.baseURL))
        let networkCompletionsURL = networkBaseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(
            url: networkCompletionsURL,
            response: .error(URLError(.networkConnectionLost))
        )
        defer { MockURLProtocol.unstub(url: networkCompletionsURL) }

        await networkVM.loadCloudEndpoint(networkEndpoint)

        let errorMsg = try XCTUnwrap(networkVM.errorMessage)
        XCTAssertFalse(errorMsg.isEmpty, "Error message should not be empty")
        XCTAssertFalse(networkVM.isModelLoaded)

        // Sabotage: with a successful stub, loading should succeed.
        MockURLProtocol.unstub(url: networkCompletionsURL)
        MockURLProtocol.stub(
            url: networkCompletionsURL,
            response: .sse(chunks: Self.sseChunks(["ok"]), statusCode: 200)
        )
        let successVM = makeViewModel { _ in
            ConfiguringOpenAICloudBackend(
                urlSession: probingSession,
                probeOnLoad: true
            )
        }
        await successVM.loadCloudEndpoint(networkEndpoint)
        XCTAssertTrue(successVM.isModelLoaded, "With successful stub, loading should succeed")
        MockURLProtocol.unstub(url: networkCompletionsURL)
    }

    // MARK: - SSRF / Endpoint Validation

    func test_loadCloudEndpoint_privateIPv4_surfacesError() async {
        let privateURLs = [
            "https://192.168.1.100",
            "https://10.0.0.1",
            "https://172.20.0.1",
        ]
        for baseURL in privateURLs {
            let privateVM = makeViewModel { [cloudSession] _ in
                ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
            }
            let endpoint = APIEndpointRecord(
                name: "Private",
                provider: .custom,
                baseURL: baseURL,
                modelName: "model"
            )
            await privateVM.loadCloudEndpoint(endpoint)

            XCTAssertNotNil(
                privateVM.errorMessage,
                "Private IP \(baseURL) should surface an error"
            )
            XCTAssertFalse(privateVM.isModelLoaded)
        }

        // Sabotage: a valid public HTTPS endpoint must NOT be rejected.
        let validVM = makeViewModel { [cloudSession] _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
        }
        let validEndpoint = APIEndpointRecord(
            name: "Valid",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "model"
        )
        await validVM.loadCloudEndpoint(validEndpoint)
        XCTAssertNil(validVM.errorMessage, "localhost should not be rejected")
    }

    func test_loadCloudEndpoint_linkLocalIMDS_surfacesError() async {
        let imdsVM = makeViewModel { [cloudSession] _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
        }
        let imdsEndpoint = APIEndpointRecord(
            name: "IMDS",
            provider: .custom,
            baseURL: "https://169.254.169.254/latest/meta-data",
            modelName: "model"
        )
        await imdsVM.loadCloudEndpoint(imdsEndpoint)

        let errorMsg = imdsVM.errorMessage ?? ""
        XCTAssertFalse(errorMsg.isEmpty, "Link-local IMDS address must surface an error")
        XCTAssertFalse(imdsVM.isModelLoaded)
    }

    func test_loadCloudEndpoint_insecureRemoteScheme_surfacesError() async {
        let insecureVM = makeViewModel { [cloudSession] _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
        }
        let insecureEndpoint = APIEndpointRecord(
            name: "Insecure",
            provider: .custom,
            baseURL: "http://api.example.com",
            modelName: "model"
        )
        await insecureVM.loadCloudEndpoint(insecureEndpoint)

        XCTAssertNotNil(insecureVM.errorMessage, "http:// remote endpoint must surface an error")
        XCTAssertFalse(insecureVM.isModelLoaded)

        // Sabotage: https:// against the same host must NOT be rejected at the
        // validation layer (it may fail later for other reasons, but not URL validation).
        let httpsVM = makeViewModel { [cloudSession] _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSession!)
        }
        let httpsEndpoint = APIEndpointRecord(
            name: "Secure",
            provider: .custom,
            baseURL: "https://api.example.com",
            modelName: "model"
        )
        await httpsVM.loadCloudEndpoint(httpsEndpoint)
        if let msg = httpsVM.errorMessage {
            XCTAssertFalse(
                msg.localizedCaseInsensitiveContains("scheme")
                || msg.localizedCaseInsensitiveContains("http"),
                "https:// must not fail URL-scheme validation, got: \(msg)"
            )
        }
    }
}

// MARK: - Backend Wrappers

/// Wraps `OpenAIBackend` to conform to both `CloudBackendURLModelConfigurable`
/// and `CloudBackendKeychainConfigurable`, matching the real app's wiring.
private final class ConfiguringOpenAICloudBackend: InferenceBackend,
                                                   ConversationHistoryReceiver,
                                                   CloudBackendURLModelConfigurable,
                                                   CloudBackendKeychainConfigurable,
                                                   @unchecked Sendable {
    private let backend: OpenAIBackend
    private let probeOnLoad: Bool

    init(urlSession: URLSession, probeOnLoad: Bool = false) {
        self.backend = OpenAIBackend(urlSession: urlSession)
        self.probeOnLoad = probeOnLoad
    }

    var isModelLoaded: Bool { backend.isModelLoaded }
    var isGenerating: Bool { backend.isGenerating }
    var capabilities: BackendCapabilities { backend.capabilities }

    func setConversationHistory(_ messages: [(role: String, content: String)]) {
        backend.setConversationHistory(messages)
    }

    func configure(baseURL: URL, modelName: String) {
        backend.configure(baseURL: baseURL, apiKey: nil, modelName: modelName)
    }

    func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        backend.configure(baseURL: baseURL, keychainAccount: keychainAccount, modelName: modelName)
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        try await backend.loadModel(from: url, plan: plan)

        guard probeOnLoad else { return }
        let stream = try backend.generate(
            prompt: "probe",
            systemPrompt: nil,
            config: GenerationConfig(maxOutputTokens: 1)
        )
        for try await _ in stream.events { break }
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        try backend.generate(prompt: prompt, systemPrompt: systemPrompt, config: config)
    }

    func stopGeneration() { backend.stopGeneration() }
    func unloadModel() { backend.unloadModel() }
    func resetConversation() { backend.resetConversation() }
}

/// Wraps `ClaudeBackend` with `CloudBackendKeychainConfigurable` conformance.
private final class ConfiguringClaudeCloudBackend: InferenceBackend,
                                                   ConversationHistoryReceiver,
                                                   CloudBackendKeychainConfigurable,
                                                   @unchecked Sendable {
    private let backend: ClaudeBackend

    init(urlSession: URLSession) {
        self.backend = ClaudeBackend(urlSession: urlSession)
    }

    var isModelLoaded: Bool { backend.isModelLoaded }
    var isGenerating: Bool { backend.isGenerating }
    var capabilities: BackendCapabilities { backend.capabilities }

    func setConversationHistory(_ messages: [(role: String, content: String)]) {
        backend.setConversationHistory(messages)
    }

    func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        backend.configure(baseURL: baseURL, keychainAccount: keychainAccount, modelName: modelName)
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        try await backend.loadModel(from: url, plan: plan)
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        try backend.generate(prompt: prompt, systemPrompt: systemPrompt, config: config)
    }

    func stopGeneration() { backend.stopGeneration() }
    func unloadModel() { backend.unloadModel() }
    func resetConversation() { backend.resetConversation() }
}
#endif
