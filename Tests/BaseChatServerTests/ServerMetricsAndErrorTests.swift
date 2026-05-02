#if Server
@testable import BaseChatServerCore
import XCTest

final class ServerMetricsAndErrorTests: XCTestCase {
    func testMetricsSnapshotStartsEmptyAndRecordsCounters() {
        let metrics = ServerMetrics()

        XCTAssertEqual(metrics.snapshot(), ServerMetricsSnapshot())

        metrics.recordRequestStarted()
        metrics.recordGenerationStarted()
        metrics.recordGenerationCompleted(tokenCount: 12)
        metrics.recordRequestCompleted()
        metrics.recordFailure()

        XCTAssertEqual(
            metrics.snapshot(),
            ServerMetricsSnapshot(
                requests: 1,
                inFlightGenerations: 0,
                completions: 1,
                failures: 1,
                tokens: 12
            )
        )
    }

    func testMetricsFailureCompletesInFlightGeneration() {
        let metrics = ServerMetrics()

        metrics.recordGenerationStarted()
        metrics.recordGenerationFailed()

        XCTAssertEqual(metrics.snapshot().inFlightGenerations, 0)
        XCTAssertEqual(metrics.snapshot().failures, 1)
    }

    func testServerErrorDescriptionsUseEnvelopeMessage() {
        XCTAssertEqual(ServerError.backendUnavailable("backend missing").description, "backend missing")
        XCTAssertEqual(ServerError.invalidConfiguration("bad port").description, "bad port")
        XCTAssertEqual(ServerError.notImplemented("todo").description, "todo")
    }

    func testErrorEnvelopeEncodesOpenAIStyleErrorBody() throws {
        let envelope = ChatCompletionErrorEnvelope(
            message: "Missing or invalid bearer token.",
            type: "invalid_request_error",
            code: "invalid_api_key"
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ChatCompletionErrorEnvelope.self, from: data)

        XCTAssertEqual(decoded.error.message, "Missing or invalid bearer token.")
        XCTAssertEqual(decoded.error.type, "invalid_request_error")
        XCTAssertNil(decoded.error.param)
        XCTAssertEqual(decoded.error.code, "invalid_api_key")
    }

    func testServerAppKeepsInjectedSeams() {
        let backendProvider = FakeServerBackendProvider(backend: ServerTestBackendFactory.loadedMock())
        let adapter = FakeChatCompletionsAdapter()
        let metrics = ServerMetrics()
        let configuration = ServerConfiguration(host: "localhost", port: 9090, metricsEnabled: true)

        let app = ServerApp(
            configuration: configuration,
            backendProvider: backendProvider,
            adapter: adapter,
            metrics: metrics
        )

        XCTAssertEqual(app.configuration, configuration)
        XCTAssertEqual(app.health(), ServerHealth(status: "ok"))
        XCTAssertEqual(app.metrics.snapshot(), ServerMetricsSnapshot())
    }
}

#endif
