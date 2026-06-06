#if CloudSaaS
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests the OpenAI Responses-API backend's named-event SSE parsing.
///
/// The Responses API distinguishes events by the `event:` line — the data
/// payload itself is just a `delta` string with no type field — so the
/// backend consumes `SSEStreamParser.parseNamed(...)` and routes by event name.
final class OpenAIResponsesBackendTests: XCTestCase {

    // MARK: - Fixtures

    /// Each test gets a unique mock URL so concurrent test runs cannot cross
    /// stubs. `MockURLProtocol.unstub` in `tearDown` cleans up the entry
    /// without flushing other tests' stubs.
    private var mockURL: URL!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        mockURL = URL(string: "https://openai-responses-\(UUID().uuidString).test")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        if let url = mockURL {
            MockURLProtocol.unstub(url: url.appendingPathComponent("v1/responses"))
        }
        session = nil
        mockURL = nil
        super.tearDown()
    }

    private func makeBackend() -> (OpenAIResponsesBackend, URL) {
        let backend = OpenAIResponsesBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "sk-test", modelName: "gpt-5")
        return (backend, mockURL.appendingPathComponent("v1/responses"))
    }

    private func load(_ backend: OpenAIResponsesBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    /// Formats a named SSE event with its data payload.
    private func sseEvent(_ name: String, data: String) -> Data {
        Data("event: \(name)\ndata: \(data)\n\n".utf8)
    }

    private enum EventCategory: Equatable {
        case thinkingToken(String)
        case thinkingCompleted
        case token(String)
        case usage
    }

    private func categorise(_ event: GenerationEvent) -> EventCategory? {
        switch event {
        case .thinkingToken(let t): return .thinkingToken(t)
        case .thinkingCompleted: return .thinkingCompleted
        case .token(let t): return .token(t)
        case .usage: return .usage
        case .toolCall, .toolResult, .toolIterationLimitExceeded, .kvCacheReuse,
             .throttleDiagnostic, .thinkingSignature,
             .toolCallStart, .toolCallArgumentsDelta,
             .toolDispatchStarted, .toolDispatchCompleted, .toolCallApproved,
             .prefillProgress, .toolProgress,
             .handoffRequested:
            return nil
        }
    }

    // MARK: - Tests

    /// Reasoning summary deltas surface as `.thinkingToken`, and a single
    /// `.thinkingCompleted` is emitted on the transition to visible content.
    func test_reasoningSummaryDeltas_emitThinkingTokensThenCompleteThenContent() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseEvent("response.output_item.added",
                     data: #"{"type":"response.output_item.added","item":{"type":"reasoning"}}"#),
            sseEvent("response.reasoning_summary_text.delta", data: #"{"delta":"Analysing"}"#),
            sseEvent("response.reasoning_summary_text.delta", data: #"{"delta":" the prompt..."}"#),
            sseEvent("response.output_text.delta", data: #"{"delta":"The answer"}"#),
            sseEvent("response.output_text.delta", data: #"{"delta":" is 42."}"#),
            sseEvent("response.completed",
                     data: #"{"response":{"usage":{"input_tokens":20,"output_tokens":8}}}"#),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "What is the answer?",
            systemPrompt: nil,
            config: GenerationConfig(maxThinkingTokens: 4096)
        )

        var categories: [EventCategory] = []
        for try await event in stream.events {
            if let cat = categorise(event) { categories.append(cat) }
        }

        let contentEvents = categories.filter {
            if case .usage = $0 { return false } else { return true }
        }

        XCTAssertEqual(contentEvents, [
            .thinkingToken("Analysing"),
            .thinkingToken(" the prompt..."),
            .thinkingCompleted,
            .token("The answer"),
            .token(" is 42."),
        ], "Got: \(contentEvents)")

        let completeCount = categories.filter { $0 == .thinkingCompleted }.count
        XCTAssertEqual(completeCount, 1, ".thinkingCompleted must fire exactly once")
    }

    /// An explicit `response.reasoning_summary_text.done` event also flushes
    /// `.thinkingCompleted`, even before any visible content delta arrives.
    func test_reasoningSummaryDoneEvent_emitsThinkingCompleteOnce() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseEvent("response.reasoning_summary_text.delta", data: #"{"delta":"Pondering"}"#),
            sseEvent("response.reasoning_summary_text.done", data: "{}"),
            sseEvent("response.output_text.delta", data: #"{"delta":"hi"}"#),
            sseEvent("response.completed", data: "{}"),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "x",
            systemPrompt: nil,
            config: GenerationConfig(maxThinkingTokens: 1024)
        )

        var categories: [EventCategory] = []
        for try await event in stream.events {
            if let cat = categorise(event) { categories.append(cat) }
        }

        XCTAssertEqual(categories, [
            .thinkingToken("Pondering"),
            .thinkingCompleted,
            .token("hi"),
        ])
    }

    /// Plain (non-reasoning) responses must never emit `.thinkingCompleted`,
    /// matching the behaviour of `OpenAIBackend` for non-reasoning models.
    func test_emptyReasoning_noThinkingCompleteEmitted() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseEvent("response.output_text.delta", data: #"{"delta":"Hello"}"#),
            sseEvent("response.output_text.delta", data: #"{"delta":" world"}"#),
            sseEvent("response.completed",
                     data: #"{"response":{"usage":{"input_tokens":4,"output_tokens":2}}}"#),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "Say hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var sawThinking = false
        var sawThinkingComplete = false
        var tokens: [String] = []
        for try await event in stream.events {
            switch event {
            case .token(let t): tokens.append(t)
            case .thinkingToken: sawThinking = true
            case .thinkingCompleted: sawThinkingComplete = true
            default: break
            }
        }

        XCTAssertEqual(tokens, ["Hello", " world"])
        XCTAssertFalse(sawThinking)
        XCTAssertFalse(sawThinkingComplete,
                       ".thinkingCompleted must not fire when no reasoning was streamed")
    }

    /// `response.error` events are surfaced as a thrown error so callers see
    /// the failure in their `for try await` loop.
    func test_errorEvent_propagatesAsThrownError() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseEvent("response.output_text.delta", data: #"{"delta":"partial"}"#),
            sseEvent("response.error",
                     data: #"{"error":{"message":"upstream rejected the request"}}"#),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "x",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        var thrownError: Error?
        do {
            for try await event in stream.events {
                if case .token(let t) = event { tokens.append(t) }
            }
        } catch {
            thrownError = error
        }

        XCTAssertEqual(tokens, ["partial"], "Tokens emitted before the error must reach the consumer")
        XCTAssertNotNil(thrownError, "response.error must propagate as a thrown error")
        if case .serverError(_, let message) = thrownError as? CloudBackendError {
            XCTAssertTrue(message.contains("upstream rejected"),
                          "Error message should carry the upstream detail; got: \(message)")
        } else {
            XCTFail("Expected CloudBackendError.serverError, got: \(String(describing: thrownError))")
        }
    }

    /// The `response.reasoning_summary` (no `_text` suffix) variant is also
    /// recognised — providers vary on the exact event-name suffix.
    func test_alternativeEventName_reasoningSummary_alsoMapsToThinking() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseEvent("response.reasoning_summary.delta", data: #"{"delta":"Thinking..."}"#),
            sseEvent("response.output_text.delta", data: #"{"delta":"done"}"#),
            sseEvent("response.completed", data: "{}"),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "x",
            systemPrompt: nil,
            config: GenerationConfig(maxThinkingTokens: 512)
        )

        var categories: [EventCategory] = []
        for try await event in stream.events {
            if let cat = categorise(event) { categories.append(cat) }
        }

        XCTAssertEqual(categories, [
            .thinkingToken("Thinking..."),
            .thinkingCompleted,
            .token("done"),
        ])
    }

    /// Request-body shape: the backend POSTs to `/v1/responses` with
    /// `input` (not `messages`) and a `reasoning` block when the caller
    /// passes a thinking budget.
    func test_requestBody_targetsResponsesEndpointWithReasoningBlock() async throws {
        let (backend, _) = makeBackend()
        try await load(backend)

        let request = try backend.buildRequest(
            prompt: "hi",
            systemPrompt: "you are helpful",
            config: GenerationConfig(maxOutputTokens: 800, maxThinkingTokens: 2000)
        )

        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "gpt-5")
        XCTAssertEqual(body?["stream"] as? Bool, true)
        XCTAssertEqual(body?["max_output_tokens"] as? Int, 800)
        XCTAssertNil(body?["messages"], "Responses API uses `input`, not `messages`")
        XCTAssertNotNil(body?["input"] as? [[String: String]])

        let reasoning = body?["reasoning"] as? [String: Any]
        XCTAssertNotNil(reasoning, "reasoning block must appear when maxThinkingTokens is set")
        XCTAssertEqual(reasoning?["effort"] as? String, "medium")
    }

    /// `GenerationConfig.maxThinkingTokens == 0` is the documented "disable
    /// thinking entirely" sentinel. The request body must omit the
    /// `reasoning` block in that case so non-reasoning models aren't
    /// erroneously forced into a reasoning response (and to match the
    /// `nil` path).
    func test_requestBody_maxThinkingTokensZero_omitsReasoningBlock() async throws {
        let (backend, _) = makeBackend()
        try await load(backend)

        let request = try backend.buildRequest(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig(maxThinkingTokens: 0)
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        XCTAssertNil(
            body?["reasoning"],
            "maxThinkingTokens == 0 means 'disable thinking'; reasoning block must be omitted"
        )
    }

    /// Stream errors that fire while the parser is still inside a thinking
    /// block must emit `.thinkingCompleted` before rethrowing — otherwise UI
    /// consumers hang in a thinking-only state. Pins the parser-error path
    /// through `ThinkingBlockManager.flushIfOpen`.
    func test_errorMidThinkingBlock_emitsThinkingCompleteBeforeThrow() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseEvent("response.reasoning_summary_text.delta", data: #"{"delta":"Pondering"}"#),
            sseEvent("response.error",
                     data: #"{"error":{"message":"upstream rejected"}}"#),
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "x",
            systemPrompt: nil,
            config: GenerationConfig(maxThinkingTokens: 512)
        )

        var observed: [EventCategory] = []
        var threw = false
        do {
            for try await event in stream.events {
                if let cat = categorise(event) { observed.append(cat) }
            }
        } catch {
            threw = true
        }

        XCTAssertTrue(threw, "expected response.error to throw out of the stream")
        XCTAssertEqual(observed, [.thinkingToken("Pondering"), .thinkingCompleted],
                       ".thinkingCompleted must fire before the throw — got \(observed)")
    }
}
#endif
