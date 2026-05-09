import XCTest
import ManifoldTestSupport

/// Tests for ``DenyAllURLProtocol``.
///
/// The protocol exists to back `LocalOnlyNetworkIsolationTests` — a regression
/// would silently re-enable network exfiltration in builds that claim to be
/// local-only. These tests pin the load-bearing properties:
/// 1. **Unconditional interception** — `canInit` always returns `true`.
/// 2. **Custom session injection** — sessions built via `installedSession`
///    intercept requests through their `protocolClasses`.
/// 3. **Attempt log fidelity** — every intercepted request is recorded.
/// 4. **Reset semantics** — `reset()` clears the log without un-registering.
/// 5. **Reference-counted registration** — nested register/unregister pairs.
final class DenyAllURLProtocolTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DenyAllURLProtocol.reset()
        DenyAllURLProtocol.register()
    }

    override func tearDown() {
        DenyAllURLProtocol.unregister()
        DenyAllURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - canInit always intercepts

    func test_canInit_returnsTrueForArbitraryRequest() {
        let request = URLRequest(url: URL(string: "https://example.invalid/foo")!)
        XCTAssertTrue(DenyAllURLProtocol.canInit(with: request))
    }

    func test_canInit_returnsTrueForLocalhostRequest() {
        // The only allowed local-loopback case (Ollama) must still be visible
        // to the canary so test failures call it out rather than silently
        // passing through.
        let request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        XCTAssertTrue(DenyAllURLProtocol.canInit(with: request))
    }

    // MARK: - Custom session via installedSession

    func test_installedSession_interceptsRequest() async throws {
        let session = DenyAllURLProtocol.installedSession()
        defer { session.invalidateAndCancel() }

        let url = URL(string: "https://example.invalid/installed")!
        do {
            _ = try await session.data(from: url)
            XCTFail("Expected request to be denied")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        XCTAssertEqual(DenyAllURLProtocol.attemptedRequests.count, 1)
        XCTAssertEqual(DenyAllURLProtocol.attemptedRequests.first?.url, url)
    }

    func test_installedConfiguration_canBeReusedAcrossSessions() async {
        let config = DenyAllURLProtocol.installedConfiguration()
        let session1 = URLSession(configuration: config)
        let session2 = URLSession(configuration: config)
        defer {
            session1.invalidateAndCancel()
            session2.invalidateAndCancel()
        }

        _ = try? await session1.data(from: URL(string: "https://example.invalid/s1")!)
        _ = try? await session2.data(from: URL(string: "https://example.invalid/s2")!)

        XCTAssertEqual(DenyAllURLProtocol.attemptedRequests.count, 2)
    }

    func test_installedConfiguration_putsProtocolFirstSoItWinsOverDefaults() {
        let config = DenyAllURLProtocol.installedConfiguration()
        let classes = config.protocolClasses ?? []
        XCTAssertEqual(classes.first.map(ObjectIdentifier.init),
                       ObjectIdentifier(DenyAllURLProtocol.self))
    }

    // MARK: - Attempt log fidelity

    func test_multipleAttempts_areAllRecordedInOrder() async {
        let urls = [
            URL(string: "https://example.invalid/one")!,
            URL(string: "https://example.invalid/two")!,
            URL(string: "https://example.invalid/three")!,
        ]

        let session = DenyAllURLProtocol.installedSession()
        defer { session.invalidateAndCancel() }

        for url in urls {
            _ = try? await session.data(from: url)
        }

        let recorded = DenyAllURLProtocol.attemptedRequests.compactMap { $0.url }
        XCTAssertEqual(recorded, urls)
    }

    func test_reset_clearsAttemptLogButLeavesProtocolRegistered() async {
        let session = DenyAllURLProtocol.installedSession()
        defer { session.invalidateAndCancel() }

        _ = try? await session.data(from: URL(string: "https://example.invalid/before-reset")!)
        XCTAssertTrue(DenyAllURLProtocol.didAttemptRequest)

        DenyAllURLProtocol.reset()
        XCTAssertFalse(DenyAllURLProtocol.didAttemptRequest)

        // After reset, the next request must still be intercepted — reset
        // wipes the log but does not unregister the protocol.
        _ = try? await session.data(from: URL(string: "https://example.invalid/after-reset")!)
        XCTAssertEqual(DenyAllURLProtocol.attemptedRequests.count, 1)
    }

    // MARK: - Reference-counted registration

    func test_nestedRegisterUnregister_keepsProtocolActiveUntilOutermostUnregister() async {
        // setUp already called register() once. Add a second registration.
        DenyAllURLProtocol.register()

        // Inner unregister: count drops to 1, protocol still active.
        DenyAllURLProtocol.unregister()

        let session = DenyAllURLProtocol.installedSession()
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(from: URL(string: "https://example.invalid/still-active")!)
        XCTAssertTrue(DenyAllURLProtocol.didAttemptRequest, "Protocol should still intercept after inner unregister")

        // tearDown's outer unregister will drop count to 0 and remove the class.
    }
}
