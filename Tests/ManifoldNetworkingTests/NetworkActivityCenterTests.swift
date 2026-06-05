import XCTest
@testable import ManifoldNetworking
@testable import ManifoldInference
import ManifoldTestSupport

/// Unit coverage for ``NetworkActivityCenter`` and the
/// ``URLSessionFactory`` wiring that funnels in-flight requests into it.
///
/// Every test instantiates its own `NetworkActivityCenter` so observations
/// cannot leak between tests under `swift test --parallel`. Stubs use a
/// UUID-based hostname per test so they cannot cross-contaminate other
/// suites (`MockURLProtocol.reset()` is process-wide — never called).
@MainActor
final class NetworkActivityCenterTests: XCTestCase {

    private func uniqueURL(prefix: String = "net-act") -> URL {
        URL(string: "https://\(prefix)-\(UUID().uuidString).test/path")!
    }

    private func makeStubbedSession(activityCenter: NetworkActivityCenter?) -> URLSession {
        // We can't use `URLSessionFactory.ephemeral` directly because we need
        // `MockURLProtocol` in the config — the factory's session won't see
        // the stub. Instead we install the tracking delegate manually via a
        // composite, mirroring what the factory builds internally.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self] + (config.protocolClasses ?? [])
        let tracker: NetworkActivityTrackingDelegate? = activityCenter.map {
            NetworkActivityTrackingDelegate(center: $0)
        }
        let composite = CompositeURLSessionDelegate(
            redirectGuard: RedirectGuardDelegate(hopCap: 3),
            serverTrustHandler: nil,
            downloadDelegate: nil,
            dataDelegate: nil,
            ownedDataDelegate: tracker
        )
        return URLSession(configuration: config, delegate: composite, delegateQueue: nil)
    }

    // MARK: - Direct API

    func test_idle_when_no_requests() {
        let center = NetworkActivityCenter()
        XCTAssertEqual(center.current, .idle)
        XCTAssertEqual(center.inFlightCount, 0)
        XCTAssertTrue(center.activeHosts.isEmpty)
    }

    func test_begin_and_end_round_trip() {
        let center = NetworkActivityCenter()
        let token = center.begin(kind: .metadata, host: "huggingface.co")
        XCTAssertEqual(center.inFlightCount, 1)
        XCTAssertEqual(center.activeHosts, ["huggingface.co"])
        XCTAssertEqual(center.current, .fetchingMetadata(host: "huggingface.co"))
        center.end(token)
        XCTAssertEqual(center.current, .idle)
        XCTAssertEqual(center.inFlightCount, 0)
    }

    func test_download_dominates_metadata_in_summary() {
        let center = NetworkActivityCenter()
        let probeToken = center.begin(kind: .probe, host: "probe.test")
        let metaToken = center.begin(kind: .metadata, host: "meta.test")
        let downloadToken = center.begin(
            kind: .download(modelID: "vendor/model"),
            host: "huggingface.co"
        )
        // Drive the download token forward so `bytesReceived` is non-zero.
        center.updateDownload(downloadToken, bytesReceived: 1024, totalBytes: 4096)

        guard case let .downloading(modelID, bytes, total, _) = center.current else {
            XCTFail("expected .downloading, got \(center.current)")
            return
        }
        XCTAssertEqual(modelID, "vendor/model")
        XCTAssertEqual(bytes, 1024)
        XCTAssertEqual(total, 4096)
        XCTAssertEqual(center.inFlightCount, 3)
        XCTAssertEqual(center.activeHosts.sorted(), ["huggingface.co", "meta.test", "probe.test"])

        center.end(downloadToken)
        XCTAssertEqual(center.current, .fetchingMetadata(host: "meta.test"))
        center.end(metaToken)
        XCTAssertEqual(center.current, .probing(host: "probe.test"))
        center.end(probeToken)
        XCTAssertEqual(center.current, .idle)
    }

    func test_end_is_idempotent_for_stale_token() {
        let center = NetworkActivityCenter()
        let token = center.begin(kind: .probe, host: "host.test")
        center.end(token)
        // Second call must not crash and must not flip current.
        center.end(token)
        XCTAssertEqual(center.current, .idle)
    }

    // MARK: - URLSession wiring

    func test_session_traffic_increments_then_decrements_on_success() async throws {
        let center = NetworkActivityCenter()
        let url = uniqueURL()
        MockURLProtocol.stub(
            url: url,
            response: .immediate(data: Data("{}".utf8), statusCode: 200)
        )
        defer { MockURLProtocol.unstub(url: url) }

        let session = makeStubbedSession(activityCenter: center)
        defer { session.invalidateAndCancel() }

        let (_, _) = try await session.data(from: url)

        // The tracker hops to MainActor; give it one runloop tick to drain.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(center.inFlightCount, 0)
        XCTAssertEqual(center.current, .idle)
    }

    func test_session_traffic_decrements_on_network_error() async {
        let center = NetworkActivityCenter()
        let url = uniqueURL()
        MockURLProtocol.stub(
            url: url,
            response: .error(URLError(.notConnectedToInternet))
        )
        defer { MockURLProtocol.unstub(url: url) }

        let session = makeStubbedSession(activityCenter: center)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await session.data(from: url)
            XCTFail("expected the stub to surface a URLError")
        } catch {
            // Expected — we asserted on the *side-effect* below.
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.inFlightCount, 0)
        XCTAssertEqual(center.current, .idle)
    }

    func test_session_decrements_on_cancel() async {
        let center = NetworkActivityCenter()
        let url = uniqueURL()
        // 5-second delay so the cancel beats the response.
        MockURLProtocol.stub(
            url: url,
            response: .delayedFirstByte(
                data: Data("{}".utf8),
                firstByteDelay: 5,
                statusCode: 200
            )
        )
        defer { MockURLProtocol.unstub(url: url) }

        let session = makeStubbedSession(activityCenter: center)
        defer { session.invalidateAndCancel() }

        let task = Task { try await session.data(from: url) }
        // Let the request start, then cancel.
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        _ = try? await task.value

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(center.inFlightCount, 0)
        XCTAssertEqual(center.current, .idle)
    }

    // MARK: - Async subscriber

    func test_updates_stream_emits_initial_state() async {
        let center = NetworkActivityCenter()
        let stream = center.updates()

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .idle)
    }

    func test_updates_stream_emits_transitions() async {
        let center = NetworkActivityCenter()
        let stream = center.updates()
        var iterator = stream.makeAsyncIterator()
        // Drain initial idle.
        _ = await iterator.next()

        let token = center.begin(kind: .metadata, host: "transitions.test")
        let next = await iterator.next()
        XCTAssertEqual(next, .fetchingMetadata(host: "transitions.test"))

        center.end(token)
        let final = await iterator.next()
        XCTAssertEqual(final, .idle)
    }
}
