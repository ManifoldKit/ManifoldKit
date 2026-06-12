import Testing
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - Helpers

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

// MARK: - Event-emitting payload handlers

/// Legacy-style handler that only implements `extractToken` and relies on the
/// protocol's default `extractEvents` wrapper to surface `.token` events.
private struct LegacyTokenHandler: SSEPayloadHandler {
    var token: @Sendable (String) -> String?
    init(token: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.token = token
    }
    func extractToken(from payload: String) -> String? { token(payload) }
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
    func isStreamEnd(_ payload: String) -> Bool { false }
    func extractStreamError(from payload: String) -> Error? { nil }
}

/// Modern handler that implements `extractEvents` directly to classify
/// thinking vs. plain token deltas.
private struct EventEmittingHandler: SSEPayloadHandler {
    var events: @Sendable (String) -> [GenerationEvent]
    init(events: @escaping @Sendable (String) -> [GenerationEvent] = { _ in [] }) {
        self.events = events
    }
    func extractToken(from payload: String) -> String? { nil }
    func extractEvents(from payload: String) -> [GenerationEvent] { events(payload) }
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
    func isStreamEnd(_ payload: String) -> Bool { false }
    func extractStreamError(from payload: String) -> Error? { nil }
}

// MARK: - Minimal concrete backend for tests

private final class TestExtractEventsBackend: SSECloudBackend, @unchecked Sendable {
    override var backendName: String { "TestExtractEvents" }

    override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: false,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: true,
            memoryStrategy: .external,
            maxOutputTokens: 4096,
            supportsStreaming: true,
            isRemote: true
        )
    }

    override func buildRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> URLRequest {
        guard let baseURL else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("stream"))
        request.httpMethod = "POST"
        return request
    }
}

// MARK: - Tests

@Suite("SSEPayloadHandler.extractEvents routing", .serialized)
struct SSEExtractEventsTests {

    init() {
        // UUID-based test hostnames don't resolve; return a public IP so
        // DNSRebindingGuard passes for mock endpoints.
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    private func makeBackend(handler: any SSEPayloadHandler) -> (TestExtractEventsBackend, URL) {
        let session = makeMockSession()
        let backend = TestExtractEventsBackend(
            defaultModelName: "extract-events-test",
            urlSession: session,
            payloadHandler: handler
        )
        let baseURL = URL(string: "https://extract-events-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "test", modelName: "extract-events-test")
        return (backend, baseURL.appendingPathComponent("stream"))
    }

    private func loadBackend(_ backend: TestExtractEventsBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    // MARK: - (a) Default-shim covers legacy extractToken-only handlers

    /// A handler that only implements the legacy ``SSEPayloadHandler/extractToken(from:)``
    /// method — never overriding ``extractEvents(from:)`` — must keep working
    /// unchanged. The protocol's default `extractEvents` wraps the token into
    /// a single-element `[.token(...)]` array so the base parse loop sees the
    /// same token it used to see.
    @Test func legacyHandler_defaultExtractEvents_yieldsTokenEvents() async throws {
        let handler = LegacyTokenHandler(token: { payload in
            payload.hasPrefix("T:") ? String(payload.dropFirst(2)) : nil
        })
        let (backend, url) = makeBackend(handler: handler)

        let chunks: [Data] = [
            sseData("T:hello"),
            sseData("T:world"),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        #expect(tokens == ["hello", "world"],
                "Default extractEvents must wrap the legacy extractToken result into [.token(...)]")
    }

    // MARK: - (b) Thinking → token transition injects .thinkingCompleted exactly once

    /// When a handler emits one or more ``GenerationEvent/thinkingToken(_:)``
    /// events followed by a plain ``GenerationEvent/token(_:)``, the base
    /// ``SSECloudBackend/parseResponseStream(bytes:continuation:)`` loop must
    /// inject a single ``GenerationEvent/thinkingCompleted`` at the boundary.
    /// The injected event must sit between the final thinking token and the
    /// first plain token, and must not repeat if further plain tokens follow.
    @Test func thinkingToTokenTransition_injectsThinkingCompleteOnce() async throws {
        let handler = EventEmittingHandler(events: { payload in
            switch payload {
            case "THINK:pondering":
                return [.thinkingToken("pondering")]
            case "THINK:more":
                return [.thinkingToken("more")]
            case "TOKEN:answer":
                return [.token("answer")]
            case "TOKEN:continued":
                return [.token("continued")]
            default:
                return []
            }
        })
        let (backend, url) = makeBackend(handler: handler)

        let chunks: [Data] = [
            sseData("THINK:pondering"),
            sseData("THINK:more"),
            sseData("TOKEN:answer"),
            sseData("TOKEN:continued"),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        // Expected exact sequence: two thinking tokens, one thinkingCompleted
        // injected by the base loop, then two plain tokens.
        let expected: [GenerationEvent] = [
            .thinkingToken("pondering"),
            .thinkingToken("more"),
            .thinkingCompleted,
            .token("answer"),
            .token("continued"),
        ]
        #expect(events == expected,
                "Base loop must inject exactly one .thinkingCompleted at the thinking→token boundary; got \(events)")

        // Extra pin: no duplicates.
        let completes = events.filter { if case .thinkingCompleted = $0 { return true } else { return false } }
        #expect(completes.count == 1,
                ".thinkingCompleted must appear exactly once across the whole stream")
    }

    // MARK: - (c) Handler-emitted .thinkingCompleted is not double-injected

    /// A handler that already emits ``GenerationEvent/thinkingCompleted``
    /// itself (e.g. an inline-tag backend using `ThinkingTransform`) must not
    /// get a second duplicate injected by the base loop. The internal
    /// `wasThinking` flag must clear when the handler's explicit event
    /// passes through.
    @Test func handlerEmitsThinkingComplete_baseLoopDoesNotDuplicate() async throws {
        let handler = EventEmittingHandler(events: { payload in
            switch payload {
            case "THINK:pondering":
                return [.thinkingToken("pondering")]
            case "THINK:DONE":
                // Handler emits its own explicit close — e.g. ThinkingTransform
                // saw the `</think>` closing tag.
                return [.thinkingCompleted]
            case "TOKEN:answer":
                return [.token("answer")]
            default:
                return []
            }
        })
        let (backend, url) = makeBackend(handler: handler)

        let chunks: [Data] = [
            sseData("THINK:pondering"),
            sseData("THINK:DONE"),
            sseData("TOKEN:answer"),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        let expected: [GenerationEvent] = [
            .thinkingToken("pondering"),
            .thinkingCompleted,
            .token("answer"),
        ]
        #expect(events == expected,
                "Handler-emitted .thinkingCompleted must not be duplicated by the base loop; got \(events)")

        let completes = events.filter { if case .thinkingCompleted = $0 { return true } else { return false } }
        #expect(completes.count == 1,
                ".thinkingCompleted must appear exactly once when the handler emits it explicitly")
    }

    // MARK: - (d) Multiple events per payload — one chunk, several events

    /// A single SSE payload can return multiple events. This is the whole
    /// point of the protocol change: a chunk that carries both reasoning
    /// and visible text (some providers do this) gets classified natively,
    /// without the base loop needing to stitch state together from two
    /// separate payloads.
    @Test func singlePayload_multipleEvents_allPassThroughInOrder() async throws {
        let handler = EventEmittingHandler(events: { payload in
            guard payload == "BOTH" else { return [] }
            return [.thinkingToken("thought"), .token("visible")]
        })
        let (backend, url) = makeBackend(handler: handler)

        let chunks: [Data] = [
            sseData("BOTH"),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(prompt: "x", systemPrompt: nil, config: GenerationConfig())

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        // Within the single payload: thinkingToken first, then the base loop
        // injects .thinkingCompleted because the next event is .token, then
        // the .token itself.
        let expected: [GenerationEvent] = [
            .thinkingToken("thought"),
            .thinkingCompleted,
            .token("visible"),
        ]
        #expect(events == expected,
                "Multiple events in one payload must preserve order and boundary injection; got \(events)")
    }
}
