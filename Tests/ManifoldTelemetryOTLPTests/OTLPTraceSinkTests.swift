import XCTest
@testable import ManifoldTelemetryOTLP
import ManifoldInference
import ManifoldTestSupport

/// Tests for ``OTLPTraceSink``.
///
/// Verifies HTTP plumbing (method, URL, Content-Type) and error-resilience using
/// ``MockURLProtocol``. Body serialisation is covered in ``OTLPSerializerTests``.
///
/// URLSession converts `httpBody` to `httpBodyStream` internally, so captured
/// requests have a nil `httpBody`. Tests that need the body should use
/// ``OTLPSpanSerializer`` directly (serialiser tests) rather than reading the stream.
final class OTLPTraceSinkTests: XCTestCase {

    // UUID-per-instance so tests don't collide in the shared MockURLProtocol state.
    private let endpoint = URL(string: "https://otlp-sink-\(UUID().uuidString).test/v1/traces")!

    private func makeSink() -> OTLPTraceSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return OTLPTraceSink(endpoint: endpoint, session: session)
    }

    private func makeSpan() -> GenSpan {
        GenSpan(
            context: .root(),
            kind: .llm,
            name: "claude-sonnet-4-6",
            start: Date(timeIntervalSince1970: 1_000_000),
            end: Date(timeIntervalSince1970: 1_000_001),
            attributes: [GenAIAttributeKeys.system: .string("Claude")],
            status: .ok
        )
    }

    private func capturedRequest() -> URLRequest? {
        MockURLProtocol.capturedRequests.last { $0.url == endpoint }
    }

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.unstub(url: endpoint)
    }

    // MARK: - HTTP plumbing

    func test_record_postsToConfiguredEndpoint() async {
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: Data(), statusCode: 200))
        let sink = makeSink()

        await sink.record(makeSpan())

        guard let req = capturedRequest() else {
            XCTFail("Expected a request to the configured endpoint — got none")
            return
        }
        XCTAssertEqual(req.url, endpoint)
        XCTAssertEqual(req.httpMethod, "POST")
        // Sabotage: changing httpMethod to "GET" would fail the method check.
    }

    func test_record_setsContentTypeJSON() async {
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: Data(), statusCode: 200))
        let sink = makeSink()

        await sink.record(makeSpan())

        guard let req = capturedRequest() else {
            XCTFail("Expected a request")
            return
        }
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // Sabotage: removing the Content-Type set in OTLPTraceSink would fail this.
    }

    func test_record_sendsARequest() async {
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: Data(), statusCode: 200))
        let sink = makeSink()

        await sink.record(makeSpan())

        XCTAssertNotNil(capturedRequest(), "Expected exactly one request to the endpoint")
        // Sabotage: commenting out the URLSession call in record() yields nil.
    }

    // MARK: - Error resilience

    func test_record_doesNotCrashOn500Response() async {
        MockURLProtocol.stub(url: endpoint, response: .immediate(data: Data(), statusCode: 500))
        let sink = makeSink()
        await sink.record(makeSpan())
        // POST was still attempted (sink did not short-circuit before sending).
        XCTAssertNotNil(capturedRequest(), "Expected a POST even when the collector returns 500")
        // Reaches here without crash — 500 is logged and swallowed.
    }

    func test_record_doesNotCrashOnNetworkError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DenyAllURLProtocol.self]
        let session = URLSession(configuration: config)
        let sink = OTLPTraceSink(endpoint: endpoint, session: session)
        await sink.record(makeSpan())
        // Reaches here without crash.
    }
}
