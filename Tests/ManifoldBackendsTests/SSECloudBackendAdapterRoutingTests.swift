#if CloudSaaS
import Testing
import Foundation
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - Test doubles
//
// These spies exist only here. They're shaped to make assertions on which
// adapter-routed seam fired during a generation — the legacy path uses
// the subclass overrides on `SSECloudBackend` directly and never touches
// these witnesses.

/// Minimal `SSEPayloadHandler` that records each payload it sees and yields
/// a single token per non-empty frame.
private final class RecordingPayloadHandler: SSEPayloadHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _payloads: [String] = []
    var payloads: [String] {
        lock.lock(); defer { lock.unlock() }
        return _payloads
    }

    func extractToken(from payload: String) -> String? {
        return payload.isEmpty ? nil : "tok(\(payload))"
    }
    func extractEvents(from payload: String) -> [GenerationEvent] {
        lock.lock(); _payloads.append(payload); lock.unlock()
        guard !payload.isEmpty, payload != "DONE" else { return [] }
        return [.token("tok(\(payload))")]
    }
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
    func isStreamEnd(_ payload: String) -> Bool { false }
    func extractStreamError(from payload: String) -> Error? { nil }
}

/// `FramedTransport` that emits a hardcoded sequence of frames, ignoring the
/// upstream byte stream entirely. Records how many times `frames(from:)` is
/// invoked so the test can confirm the envelope routed through it.
private final class RecordingFramedTransport: FramedTransport, @unchecked Sendable {
    let scriptedFrames: [Data]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    init(frames: [Data]) { self.scriptedFrames = frames }

    func frames(from bytes: URLSession.AsyncBytes) -> AsyncStream<Data> {
        lock.lock(); _callCount += 1; lock.unlock()
        let scripted = scriptedFrames
        return AsyncStream { continuation in
            for frame in scripted { continuation.yield(frame) }
            continuation.finish()
        }
    }
}

/// `StreamFinalizer` that terminates on a configured frame and records
/// every frame it inspected.
private final class RecordingFinalizer: StreamFinalizer, @unchecked Sendable {
    let terminalFrame: Data
    private let lock = NSLock()
    private var _inspected: [Data] = []
    var inspected: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _inspected
    }

    init(terminalFrame: Data) { self.terminalFrame = terminalFrame }

    func finalize(frame: Data) -> StreamTermination? {
        lock.lock(); _inspected.append(frame); lock.unlock()
        if frame == terminalFrame {
            return .streamComplete(usage: .init(promptTokens: 7, completionTokens: 11), stopReason: "stop")
        }
        return .streamContinue
    }
}

/// `ErrorBodyDecoder` whose `extractMessage` records each body and returns
/// a stable canned message so we can prove the routing override fired.
private final class RecordingErrorBodyDecoder: ErrorBodyDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [String] = []
    var bodies: [String] {
        lock.lock(); defer { lock.unlock() }
        return _bodies
    }
    func extractMessage(from body: String) -> String? {
        lock.lock(); _bodies.append(body); lock.unlock()
        return "routed:\(body.prefix(20))"
    }
}

// MARK: - Minimal SSECloudBackend subclass

/// Thin subclass exposing the legacy hooks as no-ops so the envelope is
/// the only thing under test. The legacy `buildRequest` traps — when the
/// adapter routing is installed it must never be called.
private final class TestBackend: SSECloudBackend, @unchecked Sendable {
    override var backendName: String { "AdapterRoutingTest" }
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

    /// Default (legacy-only) handler is a no-op. Adapter-routed tests
    /// install a recording handler on the routing instead, so this is
    /// only exercised by the legacy regression case.
    final class IdleHandler: SSEPayloadHandler, @unchecked Sendable {
        func extractToken(from payload: String) -> String? { nil }
        func extractEvents(from payload: String) -> [GenerationEvent] { [] }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
        func isStreamEnd(_ payload: String) -> Bool { false }
        func extractStreamError(from payload: String) -> Error? { nil }
    }
}

// MARK: - Mock session

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Tests

@Suite("SSECloudBackend adapter-routed path", .serialized)
struct SSECloudBackendAdapterRoutingTests {

    init() {
        // Bypass DNSRebindingGuard for synthetic test hosts.
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    /// Configures a routing, generates one turn, and asserts that the
    /// routing's `buildRequest`, `framedTransport`, and `payloadHandler`
    /// all participated. The legacy `buildRequest` override on the
    /// subclass would trap — its absence from the call graph is itself
    /// part of the assertion.
    @Test func adapterRouting_invokesAdapterSeams() async throws {
        let scriptedFrames: [Data] = [
            Data("alpha".utf8),
            Data("beta".utf8),
            Data("DONE".utf8),
        ]
        let payloadHandler = RecordingPayloadHandler()
        let framedTransport = RecordingFramedTransport(frames: scriptedFrames)
        let finalizer = RecordingFinalizer(terminalFrame: Data("DONE".utf8))
        let errorDecoder = RecordingErrorBodyDecoder()

        // Sentinel value the test can identify in the recorded URLRequests.
        let host = "adapter-routing-\(UUID().uuidString).test"
        let endpoint = URL(string: "https://\(host)/v1/generate")!

        let buildRequestCount = Counter()
        let routing = CloudAdapterRouting(
            payloadHandler: payloadHandler,
            framedTransport: framedTransport,
            streamFinalizer: finalizer,
            errorBodyDecoder: errorDecoder,
            buildRequest: { _, _, _ in
                buildRequestCount.increment()
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("adapter-built", forHTTPHeaderField: "X-Test-Marker")
                return req
            }
        )

        // Stub the endpoint so the URLSession completes; the routing's
        // `framedTransport` ignores the body and emits the scripted frames.
        // We still need a successful HTTP response so `parseResponseStream`
        // is reached.
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: Data("ok".utf8), statusCode: 200))

        let backend = TestBackend(
            defaultModelName: "stub",
            urlSession: makeMockSession(),
            payloadHandler: TestBackend.IdleHandler()
        )
        backend.configure(baseURL: URL(string: "https://\(host)")!, apiKey: nil, modelName: "stub")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        backend.configure(adapterRouting: routing)

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())

        var tokens: [String] = []
        var usagePrompt: Int?
        var usageCompletion: Int?
        for try await event in stream.events {
            switch event {
            case .token(let t): tokens.append(t)
            case .usage(let p, let c):
                usagePrompt = p
                usageCompletion = c
            default: break
            }
        }

        // buildRequest on the routing was called exactly once.
        #expect(buildRequestCount.value == 1)
        // framedTransport.frames(from:) was the framing source.
        #expect(framedTransport.callCount == 1)
        // payloadHandler saw every non-empty scripted frame.
        #expect(payloadHandler.payloads.contains("alpha"))
        #expect(payloadHandler.payloads.contains("beta"))
        // finalizer was consulted on every frame and terminated on "DONE".
        #expect(finalizer.inspected.count == 3)
        // Tokens flowed through the routing's handler.
        #expect(tokens == ["tok(alpha)", "tok(beta)"])
        // Stream finalizer's usage was emitted on the terminal frame.
        #expect(usagePrompt == 7)
        #expect(usageCompletion == 11)
    }

    /// Directly exercises the extracted routed parser seam without a backend
    /// subclass. The backend still owns orchestration; this pins the helper's
    /// handler-driven event routing, thinking boundary, and finalizer usage.
    @Test func routedParser_handlerPathInjectsThinkingBoundaryAndFinalizerUsage() async throws {
        let scriptedFrames: [Data] = [
            Data("think".utf8),
            Data("text".utf8),
            Data("DONE".utf8),
        ]
        let payloadHandler = ThinkingBoundaryHandler()
        let framedTransport = RecordingFramedTransport(frames: scriptedFrames)
        let finalizer = RecordingFinalizer(terminalFrame: Data("DONE".utf8))
        let usageRecorder = UsageRecorder()
        let routing = CloudAdapterRouting(
            payloadHandler: payloadHandler,
            framedTransport: framedTransport,
            streamFinalizer: finalizer,
            errorBodyDecoder: RecordingErrorBodyDecoder(),
            buildRequest: { _, _, _ in URLRequest(url: URL(string: "https://unused.test/x")!) }
        )
        let parser = CloudRoutedStreamParser(
            routing: routing,
            limits: .default,
            handleUsage: { usage in usageRecorder.record(usage) }
        )

        let endpoint = URL(string: "https://parser-seam-\(UUID().uuidString).test/stream")!
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: Data("ok".utf8), statusCode: 200))
        let request = URLRequest(url: endpoint)
        let (bytes, _) = try await makeMockSession().bytes(for: request)
        MockURLProtocol.unstub(url: endpoint)

        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                do {
                    try await parser.parse(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        var events: [String] = []
        for try await event in stream {
            switch event {
            case .thinkingToken(let text): events.append("thinking:\(text)")
            case .thinkingComplete: events.append("thinkingComplete")
            case .token(let text): events.append("token:\(text)")
            case .usage(let prompt, let completion): events.append("usage:\(prompt)/\(completion)")
            default: break
            }
        }

        #expect(events == ["thinking:rationale", "thinkingComplete", "token:answer", "usage:7/11"])
        #expect(usageRecorder.lastPrompt == 7)
        #expect(usageRecorder.lastCompletion == 11)
        #expect(framedTransport.callCount == 1)
    }

    /// Asserts that an unconfigured backend (no routing installed) still
    /// runs the legacy subclass-override path end-to-end. This is the
    /// regression check that the widen didn't accidentally re-route
    /// non-adopting backends.
    @Test func legacyPath_unchangedWhenNoRoutingConfigured() async throws {
        let host = "legacy-path-\(UUID().uuidString).test"
        let endpoint = URL(string: "https://\(host)/v1/generate")!

        // Single SSE frame carrying a payload our legacy handler recognises.
        let chunks: [Data] = [Data("data: hello\n\n".utf8)]
        MockURLProtocol.stub(url: endpoint, response: .sse(chunks: chunks, statusCode: 200))

        let handler = LegacyEchoHandler()
        let backend = LegacyTestBackend(
            urlSession: makeMockSession(),
            endpoint: endpoint,
            payloadHandler: handler
        )
        backend.configure(baseURL: URL(string: "https://\(host)")!, apiKey: nil, modelName: "stub")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        // Crucially: NO `configure(adapterRouting:)`. The envelope must
        // dispatch into `buildRequest` and `parseResponseStream` overrides.
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        #expect(backend.buildRequestInvocations == 1, "legacy buildRequest must fire when no routing is installed")
        #expect(tokens == ["legacy:hello"], "legacy parseResponseStream + payload handler must drive token extraction")
    }

    /// `extractErrorMessage` defers to the routing's error decoder when
    /// configured. The test calls the hook directly rather than wiring a
    /// failing HTTP response, because the existing `checkStatusCode`
    /// suite already covers the integration path — this asserts only the
    /// envelope's dispatch choice.
    @Test func errorMessage_routedThroughAdapterDecoder() async throws {
        let decoder = RecordingErrorBodyDecoder()
        let routing = CloudAdapterRouting(
            payloadHandler: TestBackend.IdleHandler(),
            framedTransport: RecordingFramedTransport(frames: []),
            streamFinalizer: RecordingFinalizer(terminalFrame: Data()),
            errorBodyDecoder: decoder,
            buildRequest: { _, _, _ in URLRequest(url: URL(string: "https://unused.test/x")!) }
        )

        let backend = TestBackend(
            defaultModelName: "stub",
            urlSession: makeMockSession(),
            payloadHandler: TestBackend.IdleHandler()
        )
        backend.configure(adapterRouting: routing)

        let extracted = backend.extractErrorMessage(from: "{\"error\":{\"message\":\"boom\"}}")
        // Decoder returns "routed:" + first 20 UTF-8 chars of the body.
        #expect(extracted == "routed:{\"error\":{\"message\":")
        #expect(decoder.bodies.count == 1)
    }
}

// MARK: - Legacy-path fixtures

/// Subclass that drives the legacy override path. Counts invocations so
/// the regression test can prove the envelope did not silently re-route.
private final class LegacyTestBackend: SSECloudBackend, @unchecked Sendable {
    let endpoint: URL
    private let lock = NSLock()
    private var _buildRequestInvocations = 0
    var buildRequestInvocations: Int {
        lock.lock(); defer { lock.unlock() }
        return _buildRequestInvocations
    }

    init(urlSession: URLSession, endpoint: URL, payloadHandler: any SSEPayloadHandler) {
        self.endpoint = endpoint
        super.init(defaultModelName: "legacy-stub", urlSession: urlSession, payloadHandler: payloadHandler)
    }

    override var backendName: String { "LegacyTest" }
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
        lock.lock(); _buildRequestInvocations += 1; lock.unlock()
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        return req
    }
}

/// Handler that recognises plain SSE data payloads like "hello" and emits
/// a `legacy:` prefix so the test can distinguish the legacy parse path
/// from the adapter-routed one.
private final class LegacyEchoHandler: SSEPayloadHandler, @unchecked Sendable {
    func extractToken(from payload: String) -> String? {
        payload.isEmpty ? nil : "legacy:\(payload)"
    }
    func extractEvents(from payload: String) -> [GenerationEvent] {
        guard !payload.isEmpty else { return [] }
        return [.token("legacy:\(payload)")]
    }
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
    func isStreamEnd(_ payload: String) -> Bool { false }
    func extractStreamError(from payload: String) -> Error? { nil }
}

private final class ThinkingBoundaryHandler: SSEPayloadHandler, @unchecked Sendable {
    func extractToken(from payload: String) -> String? { nil }
    func extractEvents(from payload: String) -> [GenerationEvent] {
        switch payload {
        case "think": return [.thinkingToken("rationale")]
        case "text": return [.token("answer")]
        default: return []
        }
    }
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
    func isStreamEnd(_ payload: String) -> Bool { false }
    func extractStreamError(from payload: String) -> Error? { nil }
}

// MARK: - Counter

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}

private final class UsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var usage: (promptTokens: Int?, completionTokens: Int?)?

    var lastPrompt: Int? {
        lock.lock(); defer { lock.unlock() }
        return usage?.promptTokens
    }

    var lastCompletion: Int? {
        lock.lock(); defer { lock.unlock() }
        return usage?.completionTokens
    }

    func record(_ usage: (promptTokens: Int?, completionTokens: Int?)) {
        lock.lock()
        self.usage = usage
        lock.unlock()
    }
}
#endif
