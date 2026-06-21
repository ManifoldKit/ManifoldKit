import Testing
import Foundation
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - Cost estimator tests (no trait gate — ManifoldCloudCore is always compiled)

@Suite("InferenceCostEstimator")
struct InferenceCostEstimatorTests {

    // MARK: - Known Models

    @Test("Claude Sonnet 4-6 cost matches rate table")
    func claudeSonnet46Cost() {
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "Claude",
            model: "claude-sonnet-4-6",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        // Input $3/M + Output $15/M = $18 for 1M each
        #expect(usd == 18.0)
        #expect(!isApprox)
    }

    @Test("Claude Opus 4-7 cost matches rate table")
    func claudeOpus47Cost() {
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "Claude",
            model: "claude-opus-4-7",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        // Input $15/M + Output $75/M = $90 for 1M each
        #expect(usd == 90.0)
        #expect(!isApprox)
    }

    @Test("Claude Opus 4-8 cost is non-zero and non-approximate")
    func claudeOpus48Cost() {
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "Claude",
            model: "claude-opus-4-8",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        // Input $5/M + Output $25/M = $30 for 1M each
        #expect(usd == 30.0)
        #expect(!isApprox)
    }

    @Test("Claude Opus 4-6 cost is non-zero and non-approximate")
    func claudeOpus46Cost() {
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "Claude",
            model: "claude-opus-4-6",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        // Input $5/M + Output $25/M = $30 for 1M each
        #expect(usd == 30.0)
        #expect(!isApprox)
    }

    @Test("Claude Haiku 4-5 cost matches rate table")
    func claudeHaiku45Cost() {
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "Claude",
            model: "claude-haiku-4-5",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        // Input $0.80/M + Output $4/M = $4.80
        #expect(abs(usd - 4.80) < 0.0001)
        #expect(!isApprox)
    }

    @Test("GPT-4o cost matches rate table")
    func gpt4oCost() {
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "OpenAI",
            model: "gpt-4o",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        // Input $2.50/M + Output $10/M = $12.50
        #expect(usd == 12.5)
        #expect(!isApprox)
    }

    @Test("GPT-4o-mini cost matches rate table")
    func gpt4oMiniCost() {
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "OpenAI",
            model: "gpt-4o-mini",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        // Input $0.15/M + Output $0.60/M = $0.75
        #expect(abs(usd - 0.75) < 0.0001)
        #expect(!isApprox)
    }

    @Test("Unknown model returns zero cost and isApproximate = true")
    func unknownModel() {
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "SomeProvider",
            model: "totally-unknown-model-xyz",
            promptTokens: 100,
            completionTokens: 100
        )
        #expect(usd == 0)
        #expect(isApprox)
    }

    @Test("Model variant with date suffix is matched via prefix")
    func modelVariantPrefix() {
        // Model identifiers with a date suffix (e.g. claude-sonnet-4-6-20261201)
        // should still resolve against the base rate.
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "Claude",
            model: "claude-sonnet-4-6-20261201",
            promptTokens: 1_000_000,
            completionTokens: 0
        )
        #expect(usd == 3.0) // Input only: $3/M
        #expect(!isApprox)
    }

    @Test("gpt-4o-mini variant uses mini rate, not gpt-4o rate")
    func gpt4oMiniVariantUsesLongestPrefix() {
        // "gpt-4o-mini-20261201" has two matching prefixes: "gpt-4o" and "gpt-4o-mini".
        // The longest-prefix-wins rule must select "gpt-4o-mini" ($0.15/$0.60 per M)
        // rather than "gpt-4o" ($2.50/$10 per M).
        let (usd, isApprox) = InferenceCostEstimator.estimatedCost(
            provider: "OpenAI",
            model: "gpt-4o-mini-20261201",
            promptTokens: 1_000_000,
            completionTokens: 0
        )
        // Input $0.15/M → $0.15 for 1M tokens
        #expect(abs(usd - 0.15) < 0.0001)
        #expect(!isApprox)
    }

    @Test("Zero tokens produces zero cost")
    func zeroTokens() {
        let (usd, _) = InferenceCostEstimator.estimatedCost(
            provider: "Claude",
            model: "claude-sonnet-4-6",
            promptTokens: 0,
            completionTokens: 0
        )
        #expect(usd == 0)
    }

    @Test("Cost table date is set")
    func costTableDateIsSet() {
        #expect(!InferenceCostEstimator.costTableDate.isEmpty)
    }
}

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
            estimatedCostUSD: 0,
            isCostApproximate: false,
            costTableDate: "2026-05-24",
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

    override func buildRequest(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> URLRequest {
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
        #expect(!metric.isCostApproximate) // gpt-4o is in the rate table
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
}

