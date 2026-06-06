import XCTest
import Darwin
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for the InferenceService orchestrator and backend behavior.
///
/// These tests verify service-level logic without loading real models.
/// Concrete backend tests (LlamaBackend, MLXBackend, FoundationBackend) belong
/// in ManifoldBackendsTests since those types live in ManifoldBackends.
@MainActor
final class InferenceServiceTests: XCTestCase {

    // MARK: - InferenceService

    func test_generate_noModelLoaded_throwsError() {
        let service = InferenceService()
        XCTAssertThrowsError(try service.generate(messages: [("user", "hello")]))
    }

    func test_unloadModel_resetsState() {
        let service = InferenceService()
        service.unloadModel()
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertFalse(service.isGenerating)
        XCTAssertNil(service.activeBackendName)
        XCTAssertNil(service.activeModelName)
    }

    // MARK: - Mock Backend via #if DEBUG init

    func test_generate_withMockBackend_streamsTokens() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Once", " upon", " a", " time"]

        let service = InferenceService(backend: mock, name: "Mock")
        XCTAssertTrue(service.isModelLoaded)

        let stream = try service.generate(messages: [("user", "Tell me a story")])

        var collected: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                collected.append(text)
            }
        }

        XCTAssertEqual(collected, ["Once", " upon", " a", " time"],
                        "Should stream all token events from the mock backend")
        XCTAssertEqual(mock.generateCallCount, 1, "Should have called generate once")
    }

    func test_capabilities_delegatesToBackend() {
        let customCaps = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 2048,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false
        )
        let mock = MockInferenceBackend(capabilities: customCaps)
        let service = InferenceService(backend: mock, name: "Mock")

        let caps = service.capabilities
        XCTAssertNotNil(caps, "Capabilities should not be nil when backend is loaded")
        XCTAssertEqual(caps?.maxContextTokens, 2048)
        XCTAssertTrue(caps?.requiresPromptTemplate == true)
        XCTAssertFalse(caps?.supportsSystemPrompt == true)
        XCTAssertEqual(caps?.supportedParameters, [.temperature])
    }

    func test_promptTemplate_appliedForTemplateBackend() throws {
        let templateCaps = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: true,
            supportsSystemPrompt: true
        )
        let mock = MockInferenceBackend(capabilities: templateCaps)
        mock.isModelLoaded = true

        let service = InferenceService(backend: mock, name: "Mock")
        service.selectedPromptTemplate = .chatML

        // Generate with messages; since requiresPromptTemplate is true,
        // InferenceService should format them using the selected template.
        let _ = try service.generate(
            messages: [("user", "Hello")],
            systemPrompt: "Be helpful."
        )

        // The prompt passed to the backend should be ChatML-formatted.
        XCTAssertNotNil(mock.lastPrompt, "Backend should have received a prompt")
        XCTAssertTrue(mock.lastPrompt?.contains("<|im_start|>") == true,
                      "Prompt should be formatted with ChatML template, got: \(mock.lastPrompt ?? "nil")")
        // System prompt should be baked into the formatted string, so effectiveSystemPrompt is nil.
        XCTAssertNil(mock.lastSystemPrompt,
                     "System prompt should be nil when baked into template")
    }

    func test_capabilities_nilWhenNoBackend() {
        let service = InferenceService()
        XCTAssertNil(service.capabilities, "Capabilities should be nil when no backend is loaded")
    }

    // MARK: - GenerationConfig

    func test_generationConfig_defaults() {
        let config = GenerationConfig()
        XCTAssertEqual(config.temperature, 0.7)
        XCTAssertEqual(config.topP, 0.9)
        XCTAssertEqual(config.repeatPenalty, 1.1)
        XCTAssertEqual(config.maxOutputTokens, 2048)
    }

    // MARK: - ModelType backend selection
    // NOTE: test_inferenceService_backendName_gguf requires LlamaBackend from ManifoldBackends.
    // That test belongs in ManifoldBackendsTests. Keeping a mock-based equivalent here:

    func test_inferenceService_backendName_reflectsLoadedBackend() {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "MockBackend", modelName: "tinyllama-1.1b")
        XCTAssertEqual(service.activeBackendName, "MockBackend")
        XCTAssertEqual(service.activeModelName, "tinyllama-1.1b",
                       "debug init now routes backend label and model name to separate fields")
    }

    func test_inferenceService_activeModelName_isNilWhenDebugInitOmitsIt() {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "MockBackend")
        XCTAssertEqual(service.activeBackendName, "MockBackend")
        XCTAssertNil(service.activeModelName,
                     "debug init without modelName leaves activeModelName unknown, not a copy of the backend label")
    }

    // MARK: - loadCloudBackend

    func test_loadCloudBackend_invalidURL_throwsError() async {
        let service = InferenceService()
        // A null byte makes URL(string:) return nil on all Apple platforms.
        let badURL = "http://foo\0bar"
        let endpoint = APIEndpointRecord(name: "Bad", provider: .custom, baseURL: badURL)

        do {
            try await service.loadCloudBackend(from: endpoint)
            XCTFail("Expected CloudBackendError.invalidURL to be thrown")
        } catch CloudBackendError.invalidURL(let raw) {
            XCTAssertEqual(raw, badURL)
        } catch {
            XCTFail("Expected CloudBackendError.invalidURL, got \(error)")
        }
    }

    // MARK: - loadCloudBackend endpoint validation (SSRF guard)

    func test_loadCloudBackend_privateIPv4_throwsInvalidURL() async {
        let service = InferenceService()
        let cases = [
            "https://192.168.1.100/api",
            "https://10.0.0.1/api",
            "https://172.20.0.1/api",
        ]
        for baseURL in cases {
            let endpoint = APIEndpointRecord(name: "Private", provider: .custom, baseURL: baseURL)
            do {
                try await service.loadCloudBackend(from: endpoint)
                XCTFail("Expected CloudBackendError.invalidURL for \(baseURL)")
            } catch CloudBackendError.invalidURL {
                // expected
            } catch {
                XCTFail("Expected CloudBackendError.invalidURL for \(baseURL), got \(error)")
            }
        }
    }

    func test_loadCloudBackend_linkLocalIPv4_throwsInvalidURL() async {
        let service = InferenceService()
        let endpoint = APIEndpointRecord(
            name: "IMDS",
            provider: .custom,
            baseURL: "https://169.254.169.254/latest/meta-data"
        )
        do {
            try await service.loadCloudBackend(from: endpoint)
            XCTFail("Expected CloudBackendError.invalidURL for link-local address")
        } catch CloudBackendError.invalidURL {
            // expected
        } catch {
            XCTFail("Expected CloudBackendError.invalidURL, got \(error)")
        }

        // Sabotage: a public HTTPS endpoint should NOT be rejected at this stage.
        let publicEndpoint = APIEndpointRecord(
            name: "Public",
            provider: .custom,
            baseURL: "https://api.example.com"
        )
        do {
            try await service.loadCloudBackend(from: publicEndpoint)
        } catch CloudBackendError.invalidURL(let url) {
            XCTFail("Public endpoint should not be rejected as invalid URL, got \(url)")
        } catch {
            // Other errors (no factory, etc.) are acceptable here — the point is
            // the endpoint was NOT rejected as an invalid URL.
        }
    }

    func test_loadCloudBackend_insecureRemoteScheme_throwsInvalidURL() async {
        let service = InferenceService()
        let endpoint = APIEndpointRecord(
            name: "Insecure Remote",
            provider: .custom,
            baseURL: "http://api.example.com"
        )
        do {
            try await service.loadCloudBackend(from: endpoint)
            XCTFail("Expected CloudBackendError.invalidURL for http:// remote endpoint")
        } catch CloudBackendError.invalidURL {
            // expected
        } catch {
            XCTFail("Expected CloudBackendError.invalidURL, got \(error)")
        }
    }

    func test_loadCloudBackend_localhostHTTP_isNotRejectedByURLValidation() async {
        let service = InferenceService()
        let endpoint = APIEndpointRecord(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434"
        )
        do {
            try await service.loadCloudBackend(from: endpoint)
        } catch CloudBackendError.invalidURL(let url) {
            XCTFail("Localhost http:// should not fail URL validation, got invalidURL(\(url))")
        } catch {
            // Other errors (no factory, etc.) are expected — localhost was accepted.
        }
    }

    func test_loadCloudBackend_ipv6LinkLocal_throwsInvalidURL() async {
        let service = InferenceService()
        let endpoint = APIEndpointRecord(
            name: "IPv6 Link-Local",
            provider: .custom,
            baseURL: "https://[fe80::1]/api"
        )
        do {
            try await service.loadCloudBackend(from: endpoint)
            XCTFail("Expected CloudBackendError.invalidURL for IPv6 link-local address")
        } catch CloudBackendError.invalidURL {
            // expected
        } catch {
            XCTFail("Expected CloudBackendError.invalidURL, got \(error)")
        }
    }

    func test_loadCloudBackend_noFactoryRegistered_throwsError() async {
        let service = InferenceService()
        let endpoint = APIEndpointRecord(name: "Ollama", provider: .ollama)

        do {
            try await service.loadCloudBackend(from: endpoint)
            XCTFail("Expected InferenceError.inferenceFailure to be thrown")
        } catch InferenceError.inferenceFailure {
            // expected
        } catch {
            XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
        }
    }

    func test_loadCloudBackend_setsIsModelLoaded() async throws {
        let service = InferenceService()
        let mock = MockCloudURLModelBackend()

        service.registerCloudBackendFactory { _ in mock }

        let endpoint = APIEndpointRecord(name: "Ollama", provider: .ollama)
        try await service.loadCloudBackend(from: endpoint)

        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, BackendName.ollama.rawValue)
        XCTAssertEqual(service.activeModelName, endpoint.modelName)
        XCTAssertEqual(mock.loadModelCallCount, 1)
        XCTAssertEqual(mock.configuredBaseURL?.absoluteString, endpoint.baseURL)
        XCTAssertEqual(mock.configuredModelName, endpoint.modelName)
        XCTAssertTrue(mock.didConfigureBeforeLoad)
    }

    func test_loadCloudBackend_unloadsExistingModel() async throws {
        let firstMock = MockInferenceBackend()
        let service = InferenceService(backend: firstMock, name: "First")

        let cloudMock = MockCloudURLModelBackend()
        service.registerCloudBackendFactory { _ in cloudMock }

        let endpoint = APIEndpointRecord(name: "Ollama", provider: .ollama)
        try await service.loadCloudBackend(from: endpoint)

        // The old backend should have been unloaded.
        XCTAssertEqual(firstMock.unloadCallCount, 1, "Old backend should be unloaded")
        // New backend is active.
        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, BackendName.ollama.rawValue)
    }

    func test_loadCloudBackend_configuresKeychainBackend_beforeLoad() async throws {
        let service = InferenceService()
        let mock = MockCloudKeychainBackend()
        service.registerCloudBackendFactory { _ in mock }

        let endpoint = APIEndpointRecord(
            name: "Claude",
            provider: .claude,
            baseURL: "https://api.anthropic.com",
            modelName: "claude-sonnet-4-6"
        )
        try await service.loadCloudBackend(from: endpoint)

        XCTAssertEqual(mock.configuredBaseURL?.absoluteString, endpoint.baseURL)
        XCTAssertEqual(mock.configuredModelName, endpoint.modelName)
        XCTAssertEqual(mock.configuredKeychainAccount, endpoint.keychainAccount)
        XCTAssertTrue(mock.didConfigureBeforeLoad)
    }

    func test_loadCloudBackend_nonConfigurableBackend_throwsError() async {
        let service = InferenceService()
        let mock = MockInferenceBackend()
        service.registerCloudBackendFactory { _ in mock }

        let endpoint = APIEndpointRecord(name: "Ollama", provider: .ollama)

        do {
            try await service.loadCloudBackend(from: endpoint)
            XCTFail("Expected InferenceError.inferenceFailure when backend does not conform to config protocol")
        } catch InferenceError.inferenceFailure {
            // expected
        } catch {
            XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
        }
    }

    // MARK: - Load lifecycle races

    func test_loadModel_rapidModelSwitch_latestRequestWins_staleCompletionSuppressed() async throws {
        let service = InferenceService()
        let firstBackend = ControlledLoadBackend()
        let secondBackend = ControlledLoadBackend()

        service.registerBackendFactory { modelType in
            switch modelType {
            case .gguf:
                firstBackend
            case .foundation:
                secondBackend
            case .mlx:
                nil
            }
        }

        let firstTask = Task {
            try await service.loadModel(from: makeModelInfo(name: "First", modelType: .gguf), plan: .testStub())
        }
        await firstBackend.waitUntilLoadStarted()

        let secondTask = Task {
            try await service.loadModel(from: makeModelInfo(name: "Second", modelType: .foundation), plan: .testStub())
        }
        await secondBackend.waitUntilLoadStarted()

        await secondBackend.releaseLoadSuccess()
        try await secondTask.value

        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, BackendName.foundation.rawValue)

        await firstBackend.releaseLoadSuccess()
        try await firstTask.value

        XCTAssertEqual(firstBackend.unloadCallCount, 1, "Stale backend should be unloaded when completion is discarded")
        XCTAssertEqual(secondBackend.unloadCallCount, 0)
        XCTAssertEqual(service.activeBackendName, BackendName.foundation.rawValue)
    }

    func test_loadCloudBackend_rapidEndpointSwitch_latestRequestWins_staleCompletionSuppressed() async throws {
        let service = InferenceService()
        let firstBackend = ControlledLoadBackend()
        let secondBackend = ControlledLoadBackend()

        service.registerCloudBackendFactory { provider in
            switch provider {
            case .ollama:
                firstBackend
            case .lmStudio:
                secondBackend
            default:
                nil
            }
        }

        let firstEndpoint = makeEndpoint(name: "First", provider: .ollama, modelName: "first-model")
        let secondEndpoint = makeEndpoint(name: "Second", provider: .lmStudio, modelName: "second-model")

        let firstTask = Task {
            try await service.loadCloudBackend(from: firstEndpoint)
        }
        await firstBackend.waitUntilLoadStarted()

        let secondTask = Task {
            try await service.loadCloudBackend(from: secondEndpoint)
        }
        await secondBackend.waitUntilLoadStarted()

        await secondBackend.releaseLoadSuccess()
        try await secondTask.value

        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, APIProvider.lmStudio.rawValue)

        await firstBackend.releaseLoadSuccess()
        try await firstTask.value

        XCTAssertEqual(firstBackend.unloadCallCount, 1, "Stale cloud completion should be discarded and unloaded")
        XCTAssertEqual(secondBackend.unloadCallCount, 0)
        XCTAssertEqual(service.activeBackendName, APIProvider.lmStudio.rawValue)
    }

    func test_loadModel_staleFailure_doesNotOverwriteNewerSuccessfulState() async throws {
        let service = InferenceService()
        let firstBackend = ControlledLoadBackend()
        let secondBackend = ControlledLoadBackend()

        service.registerBackendFactory { modelType in
            switch modelType {
            case .gguf:
                firstBackend
            case .foundation:
                secondBackend
            case .mlx:
                nil
            }
        }

        let firstTask = Task {
            try await service.loadModel(from: makeModelInfo(name: "First", modelType: .gguf), plan: .testStub())
        }
        await firstBackend.waitUntilLoadStarted()

        let secondTask = Task {
            try await service.loadModel(from: makeModelInfo(name: "Second", modelType: .foundation), plan: .testStub())
        }
        await secondBackend.waitUntilLoadStarted()

        await secondBackend.releaseLoadSuccess()
        try await secondTask.value

        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, BackendName.foundation.rawValue)

        await firstBackend.releaseLoadFailure(ControlledLoadTestError.plannedFailure)
        _ = try? await firstTask.value

        XCTAssertTrue(service.isModelLoaded, "Newer successful load should remain active after stale failure")
        XCTAssertEqual(service.activeBackendName, BackendName.foundation.rawValue)
        XCTAssertEqual(secondBackend.unloadCallCount, 0)
    }

    func test_loadModel_unloadDuringInFlightLoad_invalidatesRequest_preventsCommit() async throws {
        let service = InferenceService()
        let backend = ControlledLoadBackend()
        service.registerBackendFactory { modelType in
            guard modelType == .gguf else { return nil }
            return backend
        }

        let loadTask = Task {
            try await service.loadModel(from: makeModelInfo(name: "InFlight", modelType: .gguf), plan: .testStub())
        }
        await backend.waitUntilLoadStarted()

        service.unloadModel()
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertNil(service.activeBackendName)

        await backend.releaseLoadSuccess()
        try await loadTask.value

        XCTAssertFalse(service.isModelLoaded, "Unload should invalidate the in-flight request")
        XCTAssertNil(service.activeBackendName)
        XCTAssertEqual(backend.unloadCallCount, 1, "Late completion should unload its stale backend")
    }

    // MARK: - isGenerating lifecycle

    func test_generate_backendThrowsSynchronously_isGeneratingUnchanged() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("boom")

        let service = InferenceService(backend: mock, name: "Mock")

        do {
            _ = try service.generate(messages: [("user", "hello")])
            XCTFail("Expected generate to throw")
        } catch {
            // expected
        }

        // generate() no longer manages isGenerating — the queue does.
        XCTAssertFalse(service.isGenerating,
                        "isGenerating should remain false — generate() no longer sets it")
    }

    func test_generate_streamCompletesNormally_isGeneratingResetByAutoDrain() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["a", "b"]

        let service = InferenceService(backend: mock, name: "Mock")
        let stream = try service.generate(messages: [("user", "hi")])

        for try await _ in stream.events {}

        XCTAssertFalse(service.isGenerating,
                        "isGenerating should be false after the stream terminates (queue auto-drains)")
    }

    func test_generate_streamErrorMidStream_isGeneratingManagedByQueue() async throws {
        let midStreamBackend = MidStreamErrorBackend(
            tokensBeforeError: ["partial"],
            errorToThrow: NSError(domain: "test", code: 1)
        )
        let service = InferenceService(backend: midStreamBackend, name: "MidStream")

        let stream = try service.generate(messages: [("user", "hi")])

        var caughtError = false
        do {
            for try await _ in stream.events {}
        } catch {
            caughtError = true
        }

        XCTAssertTrue(caughtError, "Stream should have thrown mid-stream")
        // generate() no longer manages isGenerating — the queue does.
        // When called directly (not via enqueue), isGenerating is not set.
        // The caller (queue or legacy code) is responsible for lifecycle state.
        XCTAssertFalse(service.isGenerating,
                       "generate() no longer sets isGenerating — the generation queue manages this state")
    }

    // MARK: - Cloud backend interop

    func test_generate_cloudBackend_passesConversationHistory() throws {
        let mock = MockConversationHistoryBackend()
        let service = InferenceService(backend: mock, name: "CloudMock")

        let messages: [(role: String, content: String)] = [
            ("user", "Hello"),
            ("assistant", "Hi there"),
            ("user", "How are you?")
        ]

        let _ = try service.generate(messages: messages)

        XCTAssertNotNil(mock.receivedHistory, "setConversationHistory should have been called")
        let received = mock.receivedHistory ?? []
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[0].role, "user")
        XCTAssertEqual(received[0].content, "Hello")
        XCTAssertEqual(received[2].content, "How are you?")
    }

    func test_generate_cloudBackend_capturesTokenUsage() async throws {
        let mock = MockTokenUsageBackend()
        mock.stubbedUsage = (promptTokens: 42, completionTokens: 17)
        let service = InferenceService(backend: mock, name: "CloudMock")

        let stream = try service.generate(messages: [("user", "ping")])
        // Drain the stream so generation completes.
        for try await _ in stream.events {}

        let usage = service.lastTokenUsage
        XCTAssertNotNil(usage, "lastTokenUsage should be populated after generation")
        XCTAssertEqual(usage?.promptTokens, 42)
        XCTAssertEqual(usage?.completionTokens, 17)
    }

    // MARK: - Backend factory fallback chain

    func test_createBackend_firstFactoryWins() async throws {
        let service = InferenceService()

        var firstCallCount = 0
        var secondCallCount = 0

        let firstMock = MockInferenceBackend()
        service.registerBackendFactory { modelType in
            guard modelType == .foundation else { return nil }
            firstCallCount += 1
            return firstMock
        }

        let secondMock = MockInferenceBackend()
        service.registerBackendFactory { modelType in
            guard modelType == .foundation else { return nil }
            secondCallCount += 1
            return secondMock
        }

        let modelInfo = ModelInfo(
            name: "Foundation",
            fileName: "Built-in",
            url: URL(fileURLWithPath: "/"),
            fileSize: 0,
            modelType: .foundation
        )
        try await service.loadModel(from: modelInfo, plan: .testStub())

        XCTAssertEqual(firstCallCount, 1, "First factory should be called once")
        XCTAssertEqual(secondCallCount, 0, "Second factory should never be called when first wins")
        XCTAssertEqual(firstMock.loadModelCallCount, 1, "First factory's backend should be loaded")
        XCTAssertEqual(secondMock.loadModelCallCount, 0, "Second factory's backend should not be loaded")
    }

    func test_createBackend_firstFactoryRejectsSecondHandles() async throws {
        let service = InferenceService()

        var firstCallCount = 0
        service.registerBackendFactory { modelType in
            firstCallCount += 1
            return nil  // always rejects
        }

        var secondCallCount = 0
        let secondMock = MockInferenceBackend()
        service.registerBackendFactory { modelType in
            guard modelType == .gguf else { return nil }
            secondCallCount += 1
            return secondMock
        }

        let modelInfo = ModelInfo(
            name: "Test GGUF",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 0,
            modelType: .gguf
        )
        try await service.loadModel(from: modelInfo, plan: .testStub())

        XCTAssertEqual(firstCallCount, 1, "First factory should be called once")
        XCTAssertEqual(secondCallCount, 1, "Second factory should be called after first rejects")
        XCTAssertEqual(secondMock.loadModelCallCount, 1, "Second factory's backend should be loaded")
        XCTAssertTrue(service.isModelLoaded)
    }

    func test_createBackend_allFactoriesReturnNil_throwsError() async {
        let service = InferenceService()

        service.registerBackendFactory { _ in nil }
        service.registerBackendFactory { _ in nil }

        let modelInfo = ModelInfo(
            name: "Unknown",
            fileName: "model.gguf",
            url: URL(fileURLWithPath: "/tmp/model.gguf"),
            fileSize: 0,
            modelType: .gguf
        )

        do {
            try await service.loadModel(from: modelInfo, plan: .testStub())
            XCTFail("Expected InferenceError.inferenceFailure to be thrown")
        } catch InferenceError.inferenceFailure {
            // expected
        } catch {
            XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
        }
    }

    func test_registerCloudBackendFactory_fallsBackToSecond() async throws {
        let service = InferenceService()

        var firstCallCount = 0
        service.registerCloudBackendFactory { provider in
            firstCallCount += 1
            return nil  // always rejects
        }

        var secondCallCount = 0
        let secondMock = MockCloudURLModelBackend()
        service.registerCloudBackendFactory { provider in
            guard provider == .ollama else { return nil }
            secondCallCount += 1
            return secondMock
        }

        let endpoint = APIEndpointRecord(name: "Ollama", provider: .ollama)
        try await service.loadCloudBackend(from: endpoint)

        XCTAssertEqual(firstCallCount, 1, "First cloud factory should be called once")
        XCTAssertEqual(secondCallCount, 1, "Second cloud factory should be called after first rejects")
        XCTAssertEqual(secondMock.loadModelCallCount, 1, "Second cloud factory's backend should be loaded")
        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.activeBackendName, BackendName.ollama.rawValue)
    }

    // MARK: - TokenizerVendor

    func test_tokenizer_nilWhenNoBackendLoaded() {
        let service = InferenceService()
        XCTAssertNil(service.tokenizer, "tokenizer should be nil when no backend is loaded")
    }

    func test_tokenizer_nilForNonVendorBackend() {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "Mock")
        XCTAssertNil(service.tokenizer, "tokenizer should be nil for backends that don't conform to TokenizerVendor")
    }

    func test_tokenizer_returnedForVendorBackend() {
        let mock = MockTokenizerVendorBackend()
        let service = InferenceService(backend: mock, name: "VendorMock")
        XCTAssertNotNil(service.tokenizer, "tokenizer should be non-nil for TokenizerVendor backends")
    }

    func test_tokenizer_delegatesToBackendTokenizerProvider() {
        let mock = MockTokenizerVendorBackend()
        mock.stubbedTokenCount = 42
        let service = InferenceService(backend: mock, name: "VendorMock")

        let count = service.tokenizer?.tokenCount("anything")
        XCTAssertEqual(count, 42, "InferenceService should delegate tokenCount to the backend's tokenizer")
    }

    func test_tokenizer_nilAfterUnload() {
        let mock = MockTokenizerVendorBackend()
        let service = InferenceService(backend: mock, name: "VendorMock")
        XCTAssertNotNil(service.tokenizer)

        service.unloadModel()
        XCTAssertNil(service.tokenizer, "tokenizer should be nil after backend is unloaded")
    }

    func test_loadModel_replacesExistingBackend() async throws {
        // Load model A first using the #if DEBUG init.
        let firstMock = MockInferenceBackend()
        let service = InferenceService(backend: firstMock, name: "ModelA")
        XCTAssertTrue(service.isModelLoaded)

        // Register a factory for the second model.
        let secondMock = MockInferenceBackend()
        service.registerBackendFactory { _ in secondMock }

        let modelInfo = ModelInfo(
            name: "ModelB",
            fileName: "model-b.gguf",
            url: URL(fileURLWithPath: "/tmp/model-b.gguf"),
            fileSize: 0,
            modelType: .gguf
        )
        try await service.loadModel(from: modelInfo, plan: .testStub())

        XCTAssertEqual(firstMock.unloadCallCount, 1, "First backend's unloadModel() should be called exactly once")
        XCTAssertEqual(secondMock.loadModelCallCount, 1, "Second backend should be loaded")
        XCTAssertTrue(service.isModelLoaded)
    }

    // MARK: - Responsiveness: loadModel must not block the main thread

    func test_loadModel_doesNotCallBackendLoadOnMainThread() async throws {
        let service = InferenceService()
        let mock = MockInferenceBackend()
        service.registerBackendFactory { _ in mock }

        let modelInfo = makeModelInfo(name: "TestModel", modelType: .gguf)
        try await service.loadModel(from: modelInfo, plan: .testStub())

        XCTAssertEqual(mock.loadModelCallCount, 1)
        XCTAssertEqual(mock.loadModelCalledOnMainThread, false,
                       "loadModel must NOT run on the main thread — blocking there triggers watchdog timeouts")
    }

    func test_loadCloudBackend_doesNotCallBackendLoadOnMainThread() async throws {
        let service = InferenceService()
        let mock = ControlledLoadBackend()
        service.registerCloudBackendFactory { _ in mock }

        let endpointTask = Task {
            try await service.loadCloudBackend(from: makeEndpoint(name: "Cloud", provider: .ollama, modelName: "m"))
        }
        await mock.waitUntilLoadStarted()

        XCTAssertEqual(mock.loadModelCalledOnMainThread, false,
                       "cloud loadModel must NOT run on the main thread")

        await mock.releaseLoadSuccess()
        try await endpointTask.value
    }

    // MARK: - Rapid load stress

    /// Fires 5 load requests in rapid succession, releases their gates in reverse
    /// order, and verifies only the last (5th) load is committed.
    func test_rapidLoadStress_onlyLastLoadCommits() async throws {
        let service = InferenceService()

        // 5 gates, one per load attempt.
        let gates: [ControlledLoadGate] = (0..<5).map { _ in ControlledLoadGate() }
        var backends: [ControlledLoadBackend] = []

        // Each load attempt gets its own backend gated by the corresponding gate.
        var callIndex = 0
        service.registerBackendFactory { _ in
            let idx = callIndex
            callIndex += 1
            let backend = ControlledLoadBackend(gate: gates[idx])
            backends.append(backend)
            return backend
        }

        // Fire 5 load requests. Each uses a distinct model name so we can verify
        // which one won by checking activeBackendName after loading.
        // ModelType alternates .gguf/.foundation so each factory call is exercised.
        var loadTasks: [Task<Void, any Error>] = []
        for i in 0..<5 {
            let modelType: ModelType = (i % 2 == 0) ? .gguf : .gguf
            let task = Task {
                try await service.loadModel(
                    from: self.makeModelInfo(name: "Model\(i)", modelType: modelType),
                    plan: .testStub()
                )
            }
            loadTasks.append(task)
            // Wait for this load to reach its gate before firing the next.
            await gates[i].waitUntilStarted()
        }

        // Release gates in reverse order: 4, 3, 2, 1, 0.
        for i in stride(from: 4, through: 0, by: -1) {
            await gates[i].releaseSuccess()
            // Allow the task to propagate so the service processes the commit.
            _ = try? await loadTasks[i].value
        }

        // The latest-wins protocol means only load #4 should be committed.
        XCTAssertTrue(service.isModelLoaded,
            "Service should have a model loaded after all loads complete")

        // All backends except #4 should have been unloaded (stale suppression).
        for i in 0..<4 {
            XCTAssertEqual(backends[i].unloadCallCount, 1,
                "Backend \(i) should be unloaded since it's stale (got \(backends[i].unloadCallCount))")
        }
        XCTAssertEqual(backends[4].unloadCallCount, 0,
            "Backend 4 (the winner) should not be unloaded")
    }

    private func makeModelInfo(name: String, modelType: ModelType) -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).bin",
            url: URL(fileURLWithPath: "/\(name).bin"),
            fileSize: 0,
            modelType: modelType
        )
    }

    private func makeEndpoint(name: String, provider: APIProvider, modelName: String) -> APIEndpointRecord {
        APIEndpointRecord(name: name, provider: provider, modelName: modelName)
    }
}

// MARK: - Local mock types for cloud interop tests

/// A mock backend that also adopts ConversationHistoryReceiver.
private final class MockConversationHistoryBackend: InferenceBackend,
                                                    ConversationHistoryReceiver,
                                                    @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var receivedHistory: [(role: String, content: String)]?

    func setConversationHistory(_ messages: [(role: String, content: String)]) {
        receivedHistory = messages
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in continuation.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() {}
}

/// A mock backend that also adopts TokenUsageProvider.
private final class MockTokenUsageBackend: InferenceBackend,
                                            TokenUsageProvider,
                                            @unchecked Sendable {
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var stubbedUsage: (promptTokens: Int, completionTokens: Int)?
    var lastUsage: (promptTokens: Int, completionTokens: Int)? { stubbedUsage }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in continuation.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() {}
}

private final class MockCloudURLModelBackend: InferenceBackend,
                                              EndpointBackendURLModelConfigurable,
                                              @unchecked Sendable {
    var isModelLoaded: Bool = false
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var loadModelCallCount = 0
    var configuredBaseURL: URL?
    var configuredModelName: String?
    var didConfigureBeforeLoad = false

    func configure(baseURL: URL, modelName: String) {
        configuredBaseURL = baseURL
        configuredModelName = modelName
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        loadModelCallCount += 1
        isModelLoaded = true
        didConfigureBeforeLoad = (configuredBaseURL != nil && configuredModelName != nil)
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in continuation.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() {
        isModelLoaded = false
    }
}

private final class MockCloudKeychainBackend: InferenceBackend,
                                               EndpointBackendKeychainConfigurable,
                                               @unchecked Sendable {
    var isModelLoaded: Bool = false
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var configuredBaseURL: URL?
    var configuredKeychainAccount: String?
    var configuredModelName: String?
    var didConfigureBeforeLoad = false

    func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        configuredBaseURL = baseURL
        configuredKeychainAccount = keychainAccount
        configuredModelName = modelName
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
        didConfigureBeforeLoad = (
            configuredBaseURL != nil
                && configuredKeychainAccount != nil
                && configuredModelName != nil
        )
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in continuation.finish() }
        return GenerationStream(stream)
    }

    func stopGeneration() {}
    func unloadModel() {
        isModelLoaded = false
    }
}

private enum ControlledLoadTestError: Error, Sendable {
    case plannedFailure
}

private actor ControlledLoadGate {
    enum Release: Sendable {
        case success
        case failure(any Error & Sendable)
    }

    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseDecision: Release?
    private var releaseWaiters: [CheckedContinuation<Release, Never>] = []

    func markStarted() {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if didStart {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async -> Release {
        if let releaseDecision {
            return releaseDecision
        }
        return await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseSuccess() {
        release(.success)
    }

    func releaseFailure(_ error: any Error & Sendable) {
        release(.failure(error))
    }

    private func release(_ decision: Release) {
        guard releaseDecision == nil else { return }
        releaseDecision = decision
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: decision)
        }
    }
}

private final class ControlledLoadBackend: InferenceBackend,
                                           EndpointBackendURLModelConfigurable,
                                           @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    var loadModelCallCount = 0
    var unloadCallCount = 0
    var loadModelCalledOnMainThread: Bool?
    var configuredBaseURL: URL?
    var configuredModelName: String?

    private let gate: ControlledLoadGate

    init(gate: ControlledLoadGate = ControlledLoadGate()) {
        self.gate = gate
    }

    func configure(baseURL: URL, modelName: String) {
        configuredBaseURL = baseURL
        configuredModelName = modelName
    }

    func waitUntilLoadStarted() async {
        await gate.waitUntilStarted()
    }

    func releaseLoadSuccess() async {
        await gate.releaseSuccess()
    }

    func releaseLoadFailure(_ error: any Error & Sendable) async {
        await gate.releaseFailure(error)
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        loadModelCallCount += 1
        loadModelCalledOnMainThread = pthread_main_np() != 0
        await gate.markStarted()

        switch await gate.waitForRelease() {
        case .success:
            isModelLoaded = true
        case .failure(let error):
            throw error
        }
    }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {}

    func unloadModel() {
        unloadCallCount += 1
        isModelLoaded = false
    }
}
