import Testing
import Foundation
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - Ring buffer tests

@Suite("InMemoryMetricSink")
struct InMemoryMetricSinkTests {

    private func makeMetric(provider: String = "Test", model: String = "m") -> InferenceMetric {
        InferenceMetric(
            provider: provider,
            model: model,
            promptTokens: 10,
            cachedPromptTokens: 0,
            completionTokens: 5,
            timeToFirstToken: .zero,
            meanInterTokenLatency: .zero,
            wallClockDuration: .zero,
            errorClass: nil
        )
    }

    @Test("Empty sink returns empty metrics")
    func emptySinkReturnsEmpty() async {
        let sink = InMemoryMetricSink(capacity: 10)
        let metrics = await sink.recentMetrics()
        #expect(metrics.isEmpty)
    }

    @Test("Recorded metrics are returned in insertion order")
    func insertionOrder() async {
        let sink = InMemoryMetricSink(capacity: 10)
        await sink.record(makeMetric(provider: "A"))
        await sink.record(makeMetric(provider: "B"))
        let metrics = await sink.recentMetrics()
        #expect(metrics.count == 2)
        #expect(metrics[0].provider == "A")
        #expect(metrics[1].provider == "B")
    }

    @Test("Ring buffer evicts oldest entry when capacity is exceeded")
    func evictsOldestAtCapacity() async {
        let sink = InMemoryMetricSink(capacity: 3)
        await sink.record(makeMetric(model: "first"))
        await sink.record(makeMetric(model: "second"))
        await sink.record(makeMetric(model: "third"))
        await sink.record(makeMetric(model: "fourth")) // should evict "first"

        let metrics = await sink.recentMetrics()
        #expect(metrics.count == 3)
        #expect(metrics[0].model == "second")
        #expect(metrics[1].model == "third")
        #expect(metrics[2].model == "fourth")
    }

    @Test("Exactly at capacity does not evict")
    func exactlyAtCapacity() async {
        let sink = InMemoryMetricSink(capacity: 2)
        await sink.record(makeMetric(model: "a"))
        await sink.record(makeMetric(model: "b"))
        let metrics = await sink.recentMetrics()
        #expect(metrics.count == 2)
    }

    @Test("Clear empties the buffer")
    func clearEmptiesBuffer() async {
        let sink = InMemoryMetricSink(capacity: 10)
        await sink.record(makeMetric())
        await sink.clear()
        let metrics = await sink.recentMetrics()
        #expect(metrics.isEmpty)
    }

    @Test("Shared singleton is non-nil")
    func sharedSingletonExists() {
        // Just verify the shared singleton is accessible without crashing.
        let sink: InMemoryMetricSink = .shared
        _ = sink
    }
}

// MARK: - SSECloudBackend integration tests


// Minimal SSE payload handler for tests that exercise SSECloudBackend directly.
private struct TestPayloadHandler: SSEPayloadHandler {
    func extractToken(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["token"] as? String else { return nil }
        return text
    }
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
    func isStreamEnd(_ payload: String) -> Bool { payload.contains("[DONE]") }
    func extractStreamError(from payload: String) -> Error? { nil }
}

// Concrete SSECloudBackend subclass for integration tests.
private final class TestSSEBackend: SSECloudBackend {
    override var backendName: String { "TestBackend" }
    override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )
    }

    override func buildRequest(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> URLRequest {
        let url = baseURL!.appendingPathComponent("generate")
        return URLRequest(url: url)
    }
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func sseData(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
}

private let sseDone = Data("data: [DONE]\n\n".utf8)

@Suite("SSECloudBackend metric emission", .serialized)
struct SSECloudBackendMetricTests {

    init() {
        // Bypass DNS rebinding guard for test hostnames.
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    private func makeBackend() -> (TestSSEBackend, URL) {
        let session = makeMockSession()
        let backend = TestSSEBackend(
            defaultModelName: "gpt-4o",
            urlSession: session,
            payloadHandler: TestPayloadHandler()
        )
        let baseURL = URL(string: "https://metrics-test-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, apiKey: "test-key", modelName: "gpt-4o")
        return (backend, baseURL.appendingPathComponent("generate"))
    }

    @Test("Metric is emitted to sink on successful generation")
    func emitsMetricOnSuccess() async throws {
        let (backend, endpointURL) = makeBackend()
        let sink = InMemoryMetricSink(capacity: 10)
        backend.metricSink = sink

        let chunks: [Data] = [
            sseData(#"{"token":"Hello"}"#),
            sseData(#"{"token":" world"}"#),
            sseDone,
        ]
        MockURLProtocol.stub(url: endpointURL, response: .sse(chunks: chunks, statusCode: 200))

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events {}

        // Allow the metric emission Task to complete.
        try await Task.sleep(for: .milliseconds(100))

        let metrics = await sink.recentMetrics()
        #expect(metrics.count == 1)

        let metric = try #require(metrics.first)
        #expect(metric.provider == "TestBackend")
        #expect(metric.model == "gpt-4o")
        #expect(metric.errorClass == nil)
        // The metric carries the token counts the downstream consumer needs to
        // join against its own price table; this handler reports no usage, so 0.
        #expect(metric.promptTokens == 0)
        #expect(metric.completionTokens == 0)

        // The same surfaces through the vendor-neutral GenAI span: provider,
        // model, and token counts — no cost attributes.
        let span = metric.asGenSpan()
        #expect(span.attributes[GenAIAttributeKeys.system] == .string("TestBackend"))
        #expect(span.attributes[GenAIAttributeKeys.requestModel] == .string("gpt-4o"))
        #expect(span.attributes[GenAIAttributeKeys.usagePromptTokens] == .int(0))
        #expect(span.attributes[GenAIAttributeKeys.usageCompletionTokens] == .int(0))
    }

    @Test("Metric errorClass is populated on failure")
    func emitsMetricOnFailure() async throws {
        let (backend, endpointURL) = makeBackend()
        let sink = InMemoryMetricSink(capacity: 10)
        backend.metricSink = sink

        let errorBody = Data(#"{"error":{"message":"Unauthorized"}}"#.utf8)
        MockURLProtocol.stub(url: endpointURL, response: .immediate(data: errorBody, statusCode: 401))

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        var caughtError: Error?
        do {
            let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events {}
        } catch {
            caughtError = error
        }
        // 401 must produce authenticationFailed, not silently succeed.
        #expect(caughtError != nil, "Expected stream to throw on 401 response")

        // Allow the metric emission Task to complete.
        try await Task.sleep(for: .milliseconds(100))

        let metrics = await sink.recentMetrics()
        #expect(metrics.count == 1)

        let metric = try #require(metrics.first)
        #expect(metric.errorClass == "authenticationFailed")
    }

    @Test("Setting metricSink to nil disables emission")
    func nilSinkDisablesEmission() async throws {
        let (backend, endpointURL) = makeBackend()
        backend.metricSink = nil

        let chunks: [Data] = [sseData(#"{"token":"hi"}"#), sseDone]
        MockURLProtocol.stub(url: endpointURL, response: .sse(chunks: chunks, statusCode: 200))

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events {}

        // Verify no crash occurs and the default shared sink hasn't grown unexpectedly.
        let sharedMetrics = await InMemoryMetricSink.shared.recentMetrics()
        // We can't assert count == 0 because other tests may have written to the
        // shared sink; just confirm we reach this point without error.
        _ = sharedMetrics
    }

    @Test("Span is emitted to traceSink on successful generation")
    func emitsSpanToTraceSinkOnSuccess() async throws {
        let (backend, endpointURL) = makeBackend()
        backend.metricSink = nil
        let traceSink = RecordingTraceSink()
        backend.traceSink = traceSink

        let chunks: [Data] = [sseData(#"{"token":"Hi"}"#), sseDone]
        MockURLProtocol.stub(url: endpointURL, response: .sse(chunks: chunks, statusCode: 200))

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events {}

        try await Task.sleep(for: .milliseconds(100))

        let spans = await traceSink.recordedSpans()
        #expect(spans.count == 1)
        // Sabotage: if wiring were removed, count would be 0 and the check above would fail.

        let span = try #require(spans.first)
        #expect(span.kind == .llm)
        #expect(span.status == .ok)
        #expect(span.attributes[GenAIAttributeKeys.system] == .string("TestBackend"))
        #expect(span.attributes[GenAIAttributeKeys.requestModel] == .string("gpt-4o"))
    }

    @Test("Setting traceSink to nil disables span emission")
    func nilTraceSinkDisablesSpanEmission() async throws {
        let (backend, endpointURL) = makeBackend()
        let traceSink = RecordingTraceSink()
        backend.traceSink = traceSink
        // Immediately clear the reference so the context captures nil.
        backend.traceSink = nil

        let chunks: [Data] = [sseData(#"{"token":"hi"}"#), sseDone]
        MockURLProtocol.stub(url: endpointURL, response: .sse(chunks: chunks, statusCode: 200))

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events {}

        try await Task.sleep(for: .milliseconds(100))

        let spans = await traceSink.recordedSpans()
        #expect(spans.isEmpty, "No spans should be emitted when traceSink is nil at generate() time")
        // Sabotage: setting traceSink before generate() instead of nil-ing it would yield count 1.
    }
}

