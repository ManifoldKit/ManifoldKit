import XCTest
@testable import BaseChatInference

/// Unit + integration tests for ``RedirectGuardDelegate`` and its
/// host-stripping policy.
///
/// The redirect callback runs on the URLSession delegate queue (a
/// background thread) and is synchronous, so the tests exercise both:
///
/// - the static policy helpers (``RedirectGuardDelegate/stripSensitiveHeadersIfCrossOrigin(originalURL:request:)``,
///   ``RedirectGuardDelegate/isSameOrigin(_:_:)``,
///   ``RedirectGuardDelegate/blockedHostReason(for:)``) directly, and
/// - a real `URLSession` whose traffic is intercepted by
///   ``RedirectingURLProtocol`` — a tiny URLProtocol subclass that issues
///   a 302 with a `Location:` header so URLSession invokes the delegate's
///   `willPerformHTTPRedirection` callback for real.
///
/// Per `feedback_mockurlprotocol.md`, every integration test uses a
/// UUID-namespaced hostname so stubs don't bleed between tests.
final class RedirectGuardDelegateTests: XCTestCase {

    // MARK: - Static helper: same-origin check

    func test_isSameOrigin_truePerSchemeHostPort() {
        XCTAssertTrue(RedirectGuardDelegate.isSameOrigin(
            URL(string: "https://api.example.com/v1/foo")!,
            URL(string: "https://api.example.com/v1/bar")!
        ))
    }

    func test_isSameOrigin_explicitDefaultPortMatchesImplicit() {
        XCTAssertTrue(RedirectGuardDelegate.isSameOrigin(
            URL(string: "https://api.example.com/foo")!,
            URL(string: "https://api.example.com:443/bar")!
        ))
    }

    func test_isSameOrigin_falseOnHostChange() {
        XCTAssertFalse(RedirectGuardDelegate.isSameOrigin(
            URL(string: "https://api.example.com/v1/foo")!,
            URL(string: "https://attacker.example.com/v1/bar")!
        ))
    }

    func test_isSameOrigin_falseOnSchemeChange() {
        XCTAssertFalse(RedirectGuardDelegate.isSameOrigin(
            URL(string: "https://api.example.com/foo")!,
            URL(string: "http://api.example.com/foo")!
        ))
    }

    func test_isSameOrigin_falseOnPortChange() {
        XCTAssertFalse(RedirectGuardDelegate.isSameOrigin(
            URL(string: "https://api.example.com/foo")!,
            URL(string: "https://api.example.com:8443/foo")!
        ))
    }

    // MARK: - Static helper: header stripping

    func test_stripHeaders_crossOrigin_removesAuthorizationCookieAndXAPI() {
        var request = URLRequest(url: URL(string: "https://attacker.example.com/exfil")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=abc", forHTTPHeaderField: "Cookie")
        request.setValue("BasicXX", forHTTPHeaderField: "Proxy-Authorization")
        request.setValue("k1", forHTTPHeaderField: "X-API-Key")
        request.setValue("k2", forHTTPHeaderField: "x-api-token")
        request.setValue("kept", forHTTPHeaderField: "Content-Type")

        let stripped = RedirectGuardDelegate.stripSensitiveHeadersIfCrossOrigin(
            originalURL: URL(string: "https://api.example.com/v1/chat")!,
            request: request
        )

        XCTAssertNil(stripped.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Proxy-Authorization"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "X-Api-Token"))
        XCTAssertEqual(stripped.value(forHTTPHeaderField: "Content-Type"), "kept")
    }

    func test_stripHeaders_sameOrigin_preservesAuthorization() {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/foo")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=abc", forHTTPHeaderField: "Cookie")

        let preserved = RedirectGuardDelegate.stripSensitiveHeadersIfCrossOrigin(
            originalURL: URL(string: "https://api.example.com/v1/redirected")!,
            request: request
        )

        XCTAssertEqual(preserved.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(preserved.value(forHTTPHeaderField: "Cookie"), "session=abc")
    }

    func test_stripHeaders_sameHostDifferentPort_treatedCrossOrigin() {
        var request = URLRequest(url: URL(string: "https://api.example.com:8443/foo")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let stripped = RedirectGuardDelegate.stripSensitiveHeadersIfCrossOrigin(
            originalURL: URL(string: "https://api.example.com/foo")!,
            request: request
        )

        XCTAssertNil(stripped.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Static helper: blocked host reasons

    func test_blockedHostReason_imdsLinkLocal_isBlocked() {
        let reason = RedirectGuardDelegate.blockedHostReason(
            for: URL(string: "http://169.254.169.254/latest/meta-data")!
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("link-local") == true || reason?.contains("169.254") == true,
                      "Expected link-local rejection, got: \(reason ?? "nil")")
    }

    func test_blockedHostReason_rfc1918_isBlocked() {
        XCTAssertNotNil(RedirectGuardDelegate.blockedHostReason(
            for: URL(string: "https://10.0.0.1/api")!
        ))
        XCTAssertNotNil(RedirectGuardDelegate.blockedHostReason(
            for: URL(string: "https://192.168.1.1/api")!
        ))
    }

    func test_blockedHostReason_mDNSLocal_isBlocked() {
        XCTAssertNotNil(RedirectGuardDelegate.blockedHostReason(
            for: URL(string: "https://printer.local/api")!
        ))
    }

    func test_blockedHostReason_localhost_passes() {
        XCTAssertNil(RedirectGuardDelegate.blockedHostReason(
            for: URL(string: "http://localhost:11434/api")!
        ))
        XCTAssertNil(RedirectGuardDelegate.blockedHostReason(
            for: URL(string: "http://127.0.0.1:11434/api")!
        ))
    }

    func test_blockedHostReason_publicIP_passes() {
        XCTAssertNil(RedirectGuardDelegate.blockedHostReason(
            for: URL(string: "https://1.1.1.1/")!
        ))
    }

    // MARK: - End-to-end through URLSession

    /// Cross-origin 302 → upstream redirect → strips Authorization.
    func test_endToEnd_crossOriginRedirect_stripsAuthorization() async throws {
        let runID = UUID().uuidString
        let upstreamHost = "upstream-\(runID).test"
        let attackerHost = "attacker-\(runID).test"
        let upstreamURL = URL(string: "https://\(upstreamHost)/start")!
        let attackerURL = URL(string: "https://\(attackerHost)/exfil")!

        RedirectingURLProtocol.installRedirect(
            from: upstreamURL,
            to: attackerURL,
            statusCode: 302,
            terminalStatusCode: 200,
            terminalBody: Data("ok".utf8)
        )
        defer { RedirectingURLProtocol.reset() }

        let session = makeURLSessionWithRedirectGuard(hopCap: 3)
        var request = URLRequest(url: upstreamURL)
        request.setValue("Bearer s3cr3t", forHTTPHeaderField: "Authorization")
        request.setValue("k", forHTTPHeaderField: "X-API-Key")

        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")

        let observed = RedirectingURLProtocol.terminalRequest(for: attackerURL)
        XCTAssertNotNil(observed, "Terminal request to attacker host was never observed")
        XCTAssertNil(observed?.value(forHTTPHeaderField: "Authorization"),
                     "Authorization must be stripped on cross-origin redirect")
        XCTAssertNil(observed?.value(forHTTPHeaderField: "X-API-Key"))
    }

    /// Same-origin redirect → preserves Authorization on follow-up.
    func test_endToEnd_sameOriginRedirect_preservesAuthorization() async throws {
        let runID = UUID().uuidString
        let host = "samesame-\(runID).test"
        let firstURL = URL(string: "https://\(host)/start")!
        let secondURL = URL(string: "https://\(host)/redirected")!

        RedirectingURLProtocol.installRedirect(
            from: firstURL,
            to: secondURL,
            statusCode: 302,
            terminalStatusCode: 200,
            terminalBody: Data("ok".utf8)
        )
        defer { RedirectingURLProtocol.reset() }

        let session = makeURLSessionWithRedirectGuard(hopCap: 3)
        var request = URLRequest(url: firstURL)
        request.setValue("Bearer s3cr3t", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let observed = RedirectingURLProtocol.terminalRequest(for: secondURL)
        XCTAssertEqual(observed?.value(forHTTPHeaderField: "Authorization"), "Bearer s3cr3t",
                       "Same-origin redirect must preserve Authorization")
    }

    /// Redirect target is link-local IMDS (169.254.169.254) → cancelled.
    func test_endToEnd_imdsRedirect_cancelled() async throws {
        let runID = UUID().uuidString
        let upstreamHost = "imds-upstream-\(runID).test"
        let upstreamURL = URL(string: "https://\(upstreamHost)/start")!
        let imdsURL = URL(string: "http://169.254.169.254/latest/meta-data/iam/security-credentials")!

        RedirectingURLProtocol.installRedirect(
            from: upstreamURL,
            to: imdsURL,
            statusCode: 302,
            terminalStatusCode: 200,
            terminalBody: Data()
        )
        defer { RedirectingURLProtocol.reset() }

        let session = makeURLSessionWithRedirectGuard(hopCap: 3)
        let (data, response) = try await session.data(for: URLRequest(url: upstreamURL))
        // Cancelled redirect surfaces the original 302 to the caller.
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertNil(RedirectingURLProtocol.terminalRequest(for: imdsURL),
                     "Terminal IMDS request must never be observed when redirect is cancelled")
        // Empty redirect body is the redirect's own body, not the IMDS response.
        XCTAssertTrue(data.isEmpty)
    }

    /// Redirect from https → http is rejected as a scheme downgrade.
    func test_endToEnd_schemeDowngrade_cancelled() async throws {
        let runID = UUID().uuidString
        let host = "downgrade-\(runID).test"
        let upstreamURL = URL(string: "https://\(host)/start")!
        let plainURL = URL(string: "http://\(host)/redirected")!

        RedirectingURLProtocol.installRedirect(
            from: upstreamURL,
            to: plainURL,
            statusCode: 302,
            terminalStatusCode: 200,
            terminalBody: Data("ok".utf8)
        )
        defer { RedirectingURLProtocol.reset() }

        let session = makeURLSessionWithRedirectGuard(hopCap: 3)
        let (_, response) = try await session.data(for: URLRequest(url: upstreamURL))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302,
                       "Scheme downgrade must surface the 30x without following")
        XCTAssertNil(RedirectingURLProtocol.terminalRequest(for: plainURL))
    }

    /// Hop cap exceeded → cancelled. With hopCap=0 a single 302 is enough.
    func test_endToEnd_hopCapZero_rejectsFirstRedirect() async throws {
        let runID = UUID().uuidString
        let upstreamHost = "hopcap-\(runID).test"
        let nextHost = "next-\(runID).test"
        let upstreamURL = URL(string: "https://\(upstreamHost)/start")!
        let nextURL = URL(string: "https://\(nextHost)/redirected")!

        RedirectingURLProtocol.installRedirect(
            from: upstreamURL,
            to: nextURL,
            statusCode: 302,
            terminalStatusCode: 200,
            terminalBody: Data("ok".utf8)
        )
        defer { RedirectingURLProtocol.reset() }

        let session = makeURLSessionWithRedirectGuard(hopCap: 0)
        let (_, response) = try await session.data(for: URLRequest(url: upstreamURL))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertNil(RedirectingURLProtocol.terminalRequest(for: nextURL),
                     "Hop cap 0 must reject the first redirect")
    }

    // MARK: - Helpers

    /// Builds a `URLSession` whose only delegate is a fresh
    /// ``RedirectGuardDelegate`` and whose configuration installs
    /// ``RedirectingURLProtocol`` so 30x can be simulated without a network.
    private func makeURLSessionWithRedirectGuard(hopCap: Int) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectingURLProtocol.self] + (config.protocolClasses ?? [])
        let guardDelegate = RedirectGuardDelegate(hopCap: hopCap)
        return URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
    }
}

// MARK: - RedirectingURLProtocol

/// Tiny `URLProtocol` that returns a configured 30x for one URL and a
/// terminal status for another. Captures every observed request so the
/// tests can assert which headers reached which host.
final class RedirectingURLProtocol: URLProtocol {

    private struct RedirectStub {
        let from: URL
        let to: URL
        let statusCode: Int
        let terminalStatusCode: Int
        let terminalBody: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [String: RedirectStub] = [:]
    private nonisolated(unsafe) static var observedRequests: [String: URLRequest] = [:]

    static func installRedirect(
        from: URL,
        to: URL,
        statusCode: Int,
        terminalStatusCode: Int,
        terminalBody: Data
    ) {
        lock.lock()
        defer { lock.unlock() }
        stubs[from.absoluteString] = RedirectStub(
            from: from,
            to: to,
            statusCode: statusCode,
            terminalStatusCode: terminalStatusCode,
            terminalBody: terminalBody
        )
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll()
        observedRequests.removeAll()
    }

    static func terminalRequest(for url: URL) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return observedRequests[url.absoluteString]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // Claim every request so this protocol can record it; routing is
        // decided in `startLoading`.
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.observedRequests[url.absoluteString] = request
        let stub = Self.stubs[url.absoluteString]
        let isTerminalForRedirect = Self.stubs.values.first(where: { $0.to == url })
        Self.lock.unlock()

        if let stub {
            // Issue the configured 30x via `wasRedirectedTo:redirectResponse:`.
            // That is the call URLSession's HTTP machinery makes when it
            // sees a 30x with a `Location` header — using `didReceive` for
            // the same response would surface the 302 to the caller without
            // ever invoking the delegate's redirect callback.
            let redirectResponse = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": stub.to.absoluteString]
            )!
            // Build a follow-up request that copies caller-supplied headers
            // through verbatim. URLSession's HTTP machinery normally does
            // this automatically; we replicate it so the redirect-guard
            // sees Authorization on `newRequest` and can decide whether to
            // strip it.
            var followUp = URLRequest(url: stub.to)
            followUp.httpMethod = request.httpMethod
            for (k, v) in (request.allHTTPHeaderFields ?? [:]) {
                followUp.setValue(v, forHTTPHeaderField: k)
            }
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: redirectResponse)
            // After `wasRedirectedTo`, the delegate either returns the
            // request (URLSession then re-enters `canInit/startLoading`
            // for the new URL) or returns nil (URLSession surfaces the
            // 302 to the caller). Either way, we must finish the *current*
            // task with the 302 response so the caller's `data(for:)` call
            // returns. URLSession only re-uses the redirect target when
            // the delegate calls completionHandler(request).
            client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if let target = isTerminalForRedirect {
            let response = HTTPURLResponse(
                url: url,
                statusCode: target.terminalStatusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: target.terminalBody)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // Unknown URL — surface a generic error so the test can detect leaks.
        client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
    }

    override func stopLoading() {}
}
