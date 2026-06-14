import Testing
import Foundation
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - Shared helpers

/// Creates a `URLSession` whose traffic is intercepted by `MockURLProtocol`.
private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Formats a single SSE data line from a JSON string.
private func sseData(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
}

/// Formats the SSE `[DONE]` sentinel (used by the OpenAI-compatible backend).
private let sseDone = Data("data: [DONE]\n\n".utf8)

/// Coarse category for an ordered assertion of the event stream. We collapse
/// usage events since neither test cares about their exact position — only
/// that thinking events bracket content correctly.
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
    case .toolCall: return nil
    case .toolResult: return nil
    case .toolIterationLimitExceeded: return nil
    case .kvCacheReuse: return nil
    case .throttleDiagnostic: return nil
    case .thinkingSignature: return nil
    case .toolCallStart, .toolCallArgumentsDelta: return nil
    case .toolProgress, .toolDispatchStarted, .toolDispatchCompleted, .toolCallApproved: return nil
    case .prefillProgress: return nil
    case .handoffRequested: return nil
    }
}

// MARK: - Claude Extended Thinking Tests

@Suite("Claude extended thinking", .serialized)
struct ClaudeExtendedThinkingTests {

    init() {
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    private func makeBackend() -> (ClaudeBackend, URL) {
        let session = makeMockSession()
        let backend = ClaudeBackend(urlSession: session)
        let baseURL = URL(string: "https://claude-thinking-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "claude-sonnet-4-20250514")
        return (backend, baseURL.appendingPathComponent("v1/messages"))
    }

    private func load(_ backend: ClaudeBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    /// Full extended-thinking stream: thinking block → text block → message_stop.
    ///
    /// The Anthropic wire shape we're exercising:
    /// ```
    /// content_block_start {content_block:{type:"thinking"}}
    /// content_block_delta {delta:{type:"thinking_delta", thinking:"Let me"}}
    /// content_block_delta {delta:{type:"thinking_delta", thinking:" think..."}}
    /// content_block_stop
    /// content_block_start {content_block:{type:"text"}}
    /// content_block_delta {delta:{type:"text_delta", text:"The answer"}}
    /// content_block_delta {delta:{type:"text_delta", text:" is 42."}}
    /// content_block_stop
    /// message_stop
    /// ```
    @Test func extendedThinking_emitsThinkingTokensThenCompleteThenContent() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseData(#"{"type":"message_start","message":{"usage":{"input_tokens":30}}}"#),
            sseData(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#),
            sseData(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me"}}"#),
            sseData(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" think..."}}"#),
            sseData(#"{"type":"content_block_stop","index":0}"#),
            sseData(#"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#),
            sseData(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"The answer"}}"#),
            sseData(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" is 42."}}"#),
            sseData(#"{"type":"content_block_stop","index":1}"#),
            sseData(#"{"type":"message_delta","usage":{"output_tokens":6}}"#),
            sseData(#"{"type":"message_stop"}"#),
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

        // Must see the two thinking tokens, exactly one thinkingCompleted before
        // any visible token, then the two visible tokens. Usage events may be
        // interleaved but order between thinking/content is pinned.
        let contentEvents = categories.filter {
            if case .usage = $0 { return false } else { return true }
        }

        #expect(contentEvents == [
            .thinkingToken("Let me"),
            .thinkingToken(" think..."),
            .thinkingCompleted,
            .token("The answer"),
            .token(" is 42."),
        ], "Got: \(contentEvents)")

        // .thinkingCompleted must fire exactly once.
        let completeCount = categories.filter { $0 == .thinkingCompleted }.count
        #expect(completeCount == 1)
    }

    /// Non-thinking response (plain Claude call) must never fire .thinkingCompleted
    /// and must pass tokens through unchanged.
    @Test func nonReasoningResponse_noThinkingCompleteFires() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseData(#"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#),
            sseData(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#),
            sseData(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#),
            sseData(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#),
            sseData(#"{"type":"content_block_stop","index":0}"#),
            sseData(#"{"type":"message_stop"}"#),
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

        #expect(tokens == ["Hello", " world"])
        #expect(!sawThinking, "No thinking tokens should be emitted for a non-reasoning response")
        #expect(!sawThinkingComplete, ".thinkingCompleted must not fire when no thinking was ever seen")
    }

    /// Request wiring: when `maxThinkingTokens` is set, the outbound request
    /// must carry the `thinking` object and temperature==1.0 (both required by
    /// Anthropic when extended thinking is enabled).
    @Test func requestBody_includesThinkingBlock_whenBudgetProvided() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseData(#"{"type":"message_stop"}"#),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)

        let request = try backend.buildRequest(
            prompt: "hi",
            systemPrompt: nil,
            config: GenerationConfig(maxOutputTokens: 8000, maxThinkingTokens: 5000)
        )

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        let thinking = body?["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect((thinking?["budget_tokens"] as? Int) == 5000)
        #expect((body?["temperature"] as? Double) == 1.0)
    }
}

// MARK: - OpenAI Reasoning Model Tests

@Suite("OpenAI reasoning delta", .serialized)
struct OpenAIReasoningTests {

    init() {
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    private func makeBackend() -> (OpenAIBackend, URL) {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)
        let baseURL = URL(string: "https://openai-reasoning-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "o1-mini")
        return (backend, baseURL.appendingPathComponent("v1/chat/completions"))
    }

    private func load(_ backend: OpenAIBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    /// Reasoning-model stream using DeepSeek-style `reasoning_content` field,
    /// which is the canonical shape for OpenAI-compatible hosted reasoning
    /// models (DeepSeek R1, xAI Grok, some Qwen deployments).
    @Test func reasoningContent_emitsThinkingTokensThenCompleteThenContent() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseData(#"{"choices":[{"delta":{"role":"assistant"}}]}"#),
            sseData(#"{"choices":[{"delta":{"reasoning_content":"Analysing"}}]}"#),
            sseData(#"{"choices":[{"delta":{"reasoning_content":" the prompt..."}}]}"#),
            sseData(#"{"choices":[{"delta":{"content":"The answer"}}]}"#),
            sseData(#"{"choices":[{"delta":{"content":" is 42."}}]}"#),
            sseData(#"{"choices":[{"delta":{}}],"usage":{"prompt_tokens":20,"completion_tokens":8,"total_tokens":28}}"#),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "What is the answer?",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var categories: [EventCategory] = []
        for try await event in stream.events {
            if let cat = categorise(event) { categories.append(cat) }
        }

        let contentEvents = categories.filter {
            if case .usage = $0 { return false } else { return true }
        }

        #expect(contentEvents == [
            .thinkingToken("Analysing"),
            .thinkingToken(" the prompt..."),
            .thinkingCompleted,
            .token("The answer"),
            .token(" is 42."),
        ], "Got: \(contentEvents)")

        let completeCount = categories.filter { $0 == .thinkingCompleted }.count
        #expect(completeCount == 1)
    }

    /// The OpenAI-native shape uses `reasoning` (not `reasoning_content`).
    /// Both must map to `.thinkingToken`.
    @Test func reasoningField_openAINativeShape_alsoMapsToThinking() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseData(#"{"choices":[{"delta":{"reasoning":"Considering"}}]}"#),
            sseData(#"{"choices":[{"delta":{"content":"done"}}]}"#),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "x",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var categories: [EventCategory] = []
        for try await event in stream.events {
            if let cat = categorise(event) { categories.append(cat) }
        }

        #expect(categories == [
            .thinkingToken("Considering"),
            .thinkingCompleted,
            .token("done"),
        ])
    }

    /// Non-reasoning model response: plain content deltas only. No thinking
    /// events whatsoever — same shape as pre-thinking-support behaviour.
    @Test func nonReasoningResponse_noThinkingCompleteFires() async throws {
        let (backend, url) = makeBackend()

        let chunks: [Data] = [
            sseData(#"{"choices":[{"delta":{"role":"assistant"}}]}"#),
            sseData(#"{"choices":[{"delta":{"content":"Hello"}}]}"#),
            sseData(#"{"choices":[{"delta":{"content":" there"}}]}"#),
            sseData(#"{"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}"#),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await load(backend)
        let stream = try backend.generate(
            prompt: "Hi",
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

        #expect(tokens == ["Hello", " there"])
        #expect(!sawThinking)
        #expect(!sawThinkingComplete, ".thinkingCompleted must not fire for plain Chat Completions streams")
    }
}
