import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Unit coverage for `HuggingFaceProbe.run(url:timeout:session:)` — the test
/// seam behind `HuggingFaceServiceProtocol.probe(timeout:)`.
///
/// Uses `MockURLProtocol` with a UUID-based hostname per test so concurrent
/// runs (or other suites with stubs registered) cannot cross-contaminate.
/// `MockURLProtocol.reset()` is intentionally not called — that helper
/// touches process-wide state shared with other suites (see CLAUDE.md). We
/// `unstub(url:)` instead.
final class HuggingFaceProbeTests: XCTestCase {

    /// Builds a URLSession with `MockURLProtocol` ahead of every other
    /// protocol so the stub intercepts the request before URLSession reaches
    /// the network. Each test seeds its own UUID hostname to keep stubs
    /// isolated from peer suites.
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    private func uniqueProbeURL() -> URL {
        URL(string: "https://hf-probe-\(UUID().uuidString).test/api/models?limit=1")!
    }

    func test_probe_returnsSuccess_on200() async throws {
        let url = uniqueProbeURL()
        MockURLProtocol.stub(
            url: url,
            response: .immediate(data: Data("{}".utf8), statusCode: 200)
        )
        defer { MockURLProtocol.unstub(url: url) }

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let result = await HuggingFaceProbe.run(url: url, timeout: 2, session: session)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.httpStatus, 200)
        XCTAssertNil(result.failureReason)
        XCTAssertGreaterThan(result.latency, .zero)
        XCTAssertLessThan(abs(result.timestamp.timeIntervalSinceNow), 5)
    }

    func test_probe_returnsFailure_on500() async throws {
        let url = uniqueProbeURL()
        MockURLProtocol.stub(
            url: url,
            response: .immediate(data: Data(), statusCode: 500)
        )
        defer { MockURLProtocol.unstub(url: url) }

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let result = await HuggingFaceProbe.run(url: url, timeout: 2, session: session)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.httpStatus, 500)
        XCTAssertEqual(result.failureReason, "HTTP 500")
    }

    func test_probe_returnsFailure_onNetworkError() async throws {
        let url = uniqueProbeURL()
        MockURLProtocol.stub(
            url: url,
            response: .error(URLError(.notConnectedToInternet))
        )
        defer { MockURLProtocol.unstub(url: url) }

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let result = await HuggingFaceProbe.run(url: url, timeout: 2, session: session)

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.httpStatus)
        XCTAssertEqual(result.failureReason, "Not connected to the internet")
        // Sanitiser must not echo the raw URL or hostname back.
        if let reason = result.failureReason {
            XCTAssertFalse(reason.contains(url.absoluteString))
            XCTAssertFalse(reason.contains("hf-probe-"))
        }
    }

    func test_probe_returnsTimeout_whenServerWedges() async throws {
        let url = uniqueProbeURL()
        // Server takes far longer than the probe budget to deliver any byte.
        MockURLProtocol.stub(
            url: url,
            response: .delayedFirstByte(
                data: Data("{}".utf8),
                firstByteDelay: 5,
                statusCode: 200
            )
        )
        defer { MockURLProtocol.unstub(url: url) }

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let timeout: TimeInterval = 0.3
        let result = await HuggingFaceProbe.run(url: url, timeout: timeout, session: session)

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.httpStatus)
        XCTAssertEqual(result.failureReason, "Request timed out")
        // Latency should be in the neighbourhood of the timeout — generous
        // upper bound to absorb CI jitter without making the test flaky.
        let latencySeconds = Double(result.latency.components.seconds)
            + Double(result.latency.components.attoseconds) / 1e18
        XCTAssertGreaterThanOrEqual(latencySeconds, timeout * 0.5)
        XCTAssertLessThan(latencySeconds, timeout + 2.0)
    }

    func test_sanitise_bucketsDNSAndTLSErrors() {
        XCTAssertEqual(HuggingFaceProbe.sanitise(urlError: URLError(.cannotFindHost)), "DNS lookup failed")
        XCTAssertEqual(HuggingFaceProbe.sanitise(urlError: URLError(.secureConnectionFailed)), "TLS handshake failed")
        XCTAssertEqual(HuggingFaceProbe.sanitise(urlError: URLError(.timedOut)), "Request timed out")
        XCTAssertEqual(HuggingFaceProbe.sanitise(urlError: URLError(.cancelled)), "Request cancelled")
    }
}
