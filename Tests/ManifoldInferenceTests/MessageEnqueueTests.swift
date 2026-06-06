import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// I6 introduces a typed ``Message`` enum (`.system` / `.user` / `.assistant`)
/// for the ``InferenceService/enqueue(messages:...)`` overload. The legacy
/// `[(role: String, content: String)]` tuple variant is retained as a
/// deprecation shim. These tests pin the typed variant's wire mapping.
@MainActor
final class MessageEnqueueTests: XCTestCase {

    /// Captures the prompt the backend ultimately receives so we can verify
    /// the typed messages flow through to the wire shape.
    private final class CapturingBackend: InferenceBackend, @unchecked Sendable {
        var isModelLoaded: Bool = true
        var isGenerating: Bool = false
        let capabilities = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )
        var lastPrompt: String?
        var lastSystemPrompt: String?
        var lastConfig: GenerationConfig?

        func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
            isModelLoaded = true
        }

        func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
            lastPrompt = prompt
            lastSystemPrompt = systemPrompt
            lastConfig = config
            return GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { continuation in
                continuation.yield(.token("ok"))
                continuation.finish()
            })
        }

        func stopGeneration() {}
        func unloadModel() { isModelLoaded = false }
    }

    // MARK: - .user mapping

    func test_enqueue_userMessage_mapsToUserRole() async throws {
        let backend = CapturingBackend()
        let service = InferenceService(backend: backend, name: "Capture")

        let (_, stream) = try service.enqueue(messages: [.user("hello world")])
        for try await _ in stream.events {}

        // The default backend prompt-format places "User: hello world" in the
        // composed prompt. We assert on the substring (not exact format) so
        // the test isn't coupled to prompt-template trivia.
        let prompt = try XCTUnwrap(backend.lastPrompt)
        XCTAssertTrue(prompt.contains("hello world"),
                      "User content should reach the backend prompt; got: \(prompt)")
    }

    // MARK: - systemPrompt parameter is honoured alongside .user

    func test_enqueue_systemPromptParameter_routesToBackend() async throws {
        // The Message variant doesn't reroute `.system` cases into the
        // top-level systemPrompt parameter — that's an explicit caller
        // choice via the `systemPrompt:` argument. Pin that the typed
        // overload still threads systemPrompt through correctly.
        let backend = CapturingBackend()
        let service = InferenceService(backend: backend, name: "Capture")

        let (_, stream) = try service.enqueue(
            messages: [.user("hi")],
            systemPrompt: "you are concise"
        )
        for try await _ in stream.events {}

        XCTAssertEqual(backend.lastSystemPrompt, "you are concise",
                       "systemPrompt argument must reach the backend.")
    }

    // MARK: - Round-trip with the legacy tuple variant

    /// Constructs the same logical conversation via both overloads and
    /// asserts the backend sees the same final prompt. Pins that the typed
    /// variant doesn't accidentally re-encode the messages differently.
    func test_typedAndTupleVariants_produceSameWireShape() async throws {
        let typedBackend = CapturingBackend()
        let typedService = InferenceService(backend: typedBackend, name: "Typed")
        let (_, typedStream) = try typedService.enqueue(messages: [
            .user("hi"),
            .assistant("hello"),
            .user("how are you?")
        ])
        for try await _ in typedStream.events {}

        let tupleBackend = CapturingBackend()
        let tupleService = InferenceService(backend: tupleBackend, name: "Tuple")
        // Suppress the deprecation warning on the legacy overload — that's
        // exactly the surface this round-trip is checking.
        let (_, tupleStream) = try enqueueTuples(service: tupleService)
        for try await _ in tupleStream.events {}

        XCTAssertEqual(typedBackend.lastPrompt, tupleBackend.lastPrompt,
                       "Typed and tuple variants must produce the same composed prompt.")
    }

    @available(*, deprecated)
    private func enqueueTuples(
        service: InferenceService
    ) throws -> (token: InferenceService.GenerationRequestToken, stream: GenerationStream) {
        try service.enqueue(messages: [
            ("user", "hi"),
            ("assistant", "hello"),
            ("user", "how are you?")
        ])
    }

    // MARK: - Value-typed config entry point

    /// Canonical exercise of the value-typed
    /// ``InferenceService/enqueue(messages:config:priority:requestGroupID:)`` entry
    /// point introduced when the ~18-parameter sampling list was collapsed onto
    /// ``GenerationConfig``. Pins that a caller-built config reaches the backend
    /// verbatim, with every field preserved.
    func test_enqueue_valueTypedConfig_reachesBackendVerbatim() async throws {
        let backend = CapturingBackend()
        let service = InferenceService(backend: backend, name: "Capture")

        var config = GenerationConfig(
            temperature: 0.42,
            topP: 0.81,
            repeatPenalty: 1.23,
            topK: 7,
            seed: 99,
            maxOutputTokens: 333
        )
        config.maxThinkingTokens = 64

        let (_, stream) = try service.enqueue(
            messages: [.user("hello")],
            config: config,
            priority: .normal,
            requestGroupID: nil
        )
        for try await _ in stream.events {}

        let received = try XCTUnwrap(backend.lastConfig)
        XCTAssertEqual(received.temperature, 0.42)
        XCTAssertEqual(received.topP, 0.81)
        XCTAssertEqual(received.repeatPenalty, 1.23)
        XCTAssertEqual(received.topK, 7)
        XCTAssertEqual(received.seed, 99)
        XCTAssertEqual(received.maxOutputTokens, 333)
        XCTAssertEqual(received.maxThinkingTokens, 64)
    }

    /// The deprecated parameterized builder must produce the same config the
    /// new value-typed path would — proves the shim is a pure forwarder.
    @available(*, deprecated)
    func test_parameterizedBuilder_matchesValueTypedConfig() async throws {
        let paramBackend = CapturingBackend()
        let paramService = InferenceService(backend: paramBackend, name: "Param")
        let (_, paramStream) = try paramService.enqueue(
            messages: [.user("hello")],
            temperature: 0.42,
            topP: 0.81,
            repeatPenalty: 1.23,
            topK: 7,
            seed: 99,
            maxOutputTokens: 333,
            maxThinkingTokens: 64
        )
        for try await _ in paramStream.events {}

        let configBackend = CapturingBackend()
        let configService = InferenceService(backend: configBackend, name: "Config")
        var config = GenerationConfig(
            temperature: 0.42,
            topP: 0.81,
            repeatPenalty: 1.23,
            topK: 7,
            seed: 99,
            maxOutputTokens: 333
        )
        config.maxThinkingTokens = 64
        let (_, configStream) = try configService.enqueue(
            messages: [.user("hello")],
            config: config
        )
        for try await _ in configStream.events {}

        let viaParams = try XCTUnwrap(paramBackend.lastConfig)
        let viaConfig = try XCTUnwrap(configBackend.lastConfig)
        XCTAssertEqual(viaParams.temperature, viaConfig.temperature)
        XCTAssertEqual(viaParams.topP, viaConfig.topP)
        XCTAssertEqual(viaParams.repeatPenalty, viaConfig.repeatPenalty)
        XCTAssertEqual(viaParams.topK, viaConfig.topK)
        XCTAssertEqual(viaParams.seed, viaConfig.seed)
        XCTAssertEqual(viaParams.maxOutputTokens, viaConfig.maxOutputTokens)
        XCTAssertEqual(viaParams.maxThinkingTokens, viaConfig.maxThinkingTokens)
        XCTAssertEqual(viaParams.maxToolIterations, viaConfig.maxToolIterations)
    }

    // MARK: - Message conformance / role mapping

    /// Smoke-test for the Message → tuple bridge. If a future change adds a
    /// new case (e.g. `.tool(...)`) the bridge must be updated; this test
    /// pins the existing role discriminators.
    func test_message_roleAndContent_areCorrectForEachCase() {
        XCTAssertEqual(Message.system("s").role, "system")
        XCTAssertEqual(Message.system("s").content, "s")
        XCTAssertEqual(Message.user("u").role, "user")
        XCTAssertEqual(Message.user("u").content, "u")
        XCTAssertEqual(Message.assistant("a").role, "assistant")
        XCTAssertEqual(Message.assistant("a").content, "a")

        let tuples: [(role: String, content: String)] = [
            Message.system("s"),
            Message.user("u"),
            Message.assistant("a")
        ].asRoleContentTuples
        XCTAssertEqual(tuples.map(\.role), ["system", "user", "assistant"])
        XCTAssertEqual(tuples.map(\.content), ["s", "u", "a"])
    }
}
