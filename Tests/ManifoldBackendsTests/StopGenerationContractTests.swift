import XCTest
import os
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldCloudCore
import ManifoldCloudSaaS
import ManifoldOllama
import ManifoldFoundation

@MainActor
final class StopGenerationContractTests: XCTestCase {
    func test_compliantBackend_stopsAndImmediatelyReuses() async throws {
        try await BackendContractChecks.assertStopGenerationContract(backend: StopContractFixture())
    }

    func test_sabotage_flagStillTrue_isRejected() async {
        await assertViolation(.keepsGenerating, contains: "synchronously")
    }

    func test_sabotage_successorRejected_isRejected() async {
        await assertViolation(.rejectsReuse, contains: "successor rejected")
    }

    func test_sabotage_unterminatedStream_isBoundedAndRejected() async {
        await assertViolation(.neverFinishes, contains: "did not terminate")
    }

    func test_sabotage_finishedGeneration_cannotProveCancellation() async {
        await assertViolation(.alreadyFinished, contains: "not in flight")
    }

    func test_sabotage_silentGeneration_cannotProveCancellation() async {
        await assertViolation(.silent, contains: "no content")
    }

    func test_sabotage_predecessorClearsSuccessorFlag_isRejected() async {
        await assertViolation(.clearsSuccessorFlag, contains: "successor was not in flight")
    }

    private func assertViolation(_ mode: StopContractFixture.Mode, contains expected: String) async {
        let backend = StopContractFixture(mode: mode)
        defer { backend.unloadModel() }
        do {
            try await BackendContractChecks.assertStopGenerationContract(
                backend: backend, timeout: .milliseconds(100)
            )
            XCTFail("Broken backend satisfied the contract: \(mode)")
        } catch {
            XCTAssertTrue(String(describing: error).contains(expected), "Unexpected failure: \(error)")
        }
    }

    func test_openAI_liveTransportStopAndReuse() async throws { try await checkCloud(.openAI) }
    func test_responses_liveTransportStopAndReuse() async throws { try await checkCloud(.responses) }
    func test_claude_liveTransportStopAndReuse() async throws { try await checkCloud(.claude) }
    func test_ollama_liveTransportStopAndReuse() async throws { try await checkCloud(.ollama) }

    private enum Provider { case openAI, responses, claude, ollama }

    private func checkCloud(_ provider: Provider) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let baseURL = try XCTUnwrap(URL(string: "http://localhost/stop-contract-\(UUID())"))
        let backend: SSECloudBackend
        let path: String
        let chunk: String
        switch provider {
        case .openAI:
            backend = OpenAIBackend(urlSession: session)
            path = "v1/chat/completions"
            chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"token \"}}]}\n\n"
        case .responses:
            backend = OpenAIResponsesBackend(urlSession: session)
            path = "v1/responses"
            chunk = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"token \"}\n\n"
        case .claude:
            backend = ClaudeBackend(urlSession: session)
            path = "v1/messages"
            chunk = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"token \"}}\n\n"
        case .ollama:
            backend = OllamaBackend(urlSession: session)
            path = "api/chat"
            chunk = "{\"message\":{\"role\":\"assistant\",\"content\":\"token \"},\"done\":false}\n"
        }
        let streamURL = baseURL.appendingPathComponent(path)
        let showURL = baseURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(url: streamURL, response: .asyncSSE(
            chunks: Array(repeating: Data(chunk.utf8), count: 100), chunkDelay: 0.02, statusCode: 200
        ))
        MockURLProtocol.stub(url: showURL, response: .immediate(
            data: Data("{\"capabilities\":[]}".utf8), statusCode: 200
        ))
        defer {
            backend.unloadModel()
            MockURLProtocol.unstub(url: streamURL)
            MockURLProtocol.unstub(url: showURL)
        }
        backend.configure(baseURL: baseURL, apiKey: "test-only", modelName: "contract-model")
        try await backend.loadModel(from: baseURL, plan: .testStub())
        try await BackendContractChecks.assertStopGenerationContract(backend: backend)
    }

    func test_foundation_liveModelStopAndReuse() async throws {
        guard #available(macOS 26, iOS 26, *) else {
            throw XCTSkip("Foundation Models requires OS 26")
        }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_SLOW_TESTS"] == "1",
                          "Set RUN_SLOW_TESTS=1 for physical Foundation inference")
        try XCTSkipUnless(FoundationBackend.isAvailable, "Apple Intelligence is unavailable")
        let backend = FoundationBackend()
        defer { backend.unloadModel() }
        try await backend.loadModel(from: URL(fileURLWithPath: "/dev/null"),
                                    plan: .systemManaged(requestedContextSize: 4096))
        try await BackendContractChecks.assertStopGenerationContract(backend: backend, timeout: .seconds(60))
    }
}

private final class StopContractFixture: InferenceBackend, Sendable {
    enum Mode { case compliant, keepsGenerating, rejectsReuse, neverFinishes, alreadyFinished, silent, clearsSuccessorFlag }
    private struct State {
        var loaded = true
        var generating = false
        var generationCount = 0
        var continuations: [AsyncThrowingStream<GenerationEvent, Error>.Continuation] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let mode: Mode
    init(mode: Mode = .compliant) { self.mode = mode }
    var isModelLoaded: Bool { state.withLock { $0.loaded } }
    var isGenerating: Bool { state.withLock { $0.generating } }
    var capabilities: BackendCapabilities { .init(supportedParameters: [.temperature], maxContextTokens: 4096) }
    func loadModel(from url: URL, plan: ModelLoadPlan) async throws { state.withLock { $0.loaded = true } }

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig,
                  hints: GenerationRuntimeHints) throws -> GenerationStream {
        try state.withLock { s in
            if mode == .rejectsReuse, s.generationCount > 0 {
                throw InferenceError.inferenceFailure("successor rejected")
            }
            s.generationCount += 1
            s.generating = !(mode == .clearsSuccessorFlag && s.generationCount > 1)
        }
        let pair = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        state.withLock { $0.continuations.append(pair.continuation) }
        if mode != .silent { pair.continuation.yield(.token("in-flight")) }
        if mode == .alreadyFinished {
            state.withLock { $0.generating = false }
            pair.continuation.finish()
        }
        return GenerationStream(pair.stream)
    }

    func stopGeneration() {
        let continuations = state.withLock { s in
            if mode != .keepsGenerating { s.generating = false }
            return s.continuations
        }
        if mode != .neverFinishes { for continuation in continuations { continuation.finish() } }
    }

    func unloadModel() {
        let continuations = state.withLock { s in
            s.loaded = false
            s.generating = false
            let result = s.continuations
            s.continuations.removeAll()
            return result
        }
        for continuation in continuations { continuation.finish() }
    }
}
