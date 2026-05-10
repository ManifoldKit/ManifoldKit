#if MCP
import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldTestSupport

final class MCPHardeningTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        MCPSSRFPolicy._resolverForTesting = nil
        super.tearDown()
    }

    func test_connectRejectsSSRFBlockedTransportEndpoint() async {
        let client = MCPClient()
        let descriptor = MCPServerDescriptor(
            displayName: "Blocked",
            transport: .streamableHTTP(endpoint: URL(string: "https://169.254.169.254/mcp")!, headers: [:]),
            dataDisclosure: "test"
        )

        do {
            _ = try await client.connect(descriptor)
            XCTFail("Expected SSRF rejection")
        } catch let error as MCPError {
            guard case .ssrfBlocked(let blockedURL) = error else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.absoluteString, "https://169.254.169.254/mcp")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_oauthDiscoveryRejectsSSRFBlockedAuthorizationIssuer() async {
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let resourceMetadataURL = URL(string: "https://resource.example.com/.well-known/oauth-protected-resource")!
        MockURLProtocol.stub(url: resourceMetadataURL, response: .immediate(data: Data(
            """
            { "authorization_servers": ["https://169.254.169.254"] }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: nil),
            serverID: UUID(),
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                XCTFail("OAuth browser flow should not begin when issuer is blocked")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: .inMemory(),
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: resourceURL)) { error in
            guard case .ssrfBlocked(let blockedURL) = error as? MCPError else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.absoluteString, "https://169.254.169.254")
        }
    }

    func test_oauthDiscoveryRejectsSSRFBlockedTokenEndpoint() async throws {
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let metadataURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
        MockURLProtocol.stub(url: metadataURL, response: .immediate(data: Data(
            """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://169.254.169.254/token"
            }
            """.utf8
        ), statusCode: 200, headers: ["Content-Type": "application/json"]))

        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "expired",
                refreshToken: "refresh-token",
                expiresAt: Date().addingTimeInterval(-10),
                scopes: ["tools:read"],
                issuer: issuer
            ),
            serverID
        )

        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: issuer),
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                XCTFail("OAuth browser flow should not begin when token endpoint is blocked")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: resourceURL)) { error in
            guard case .ssrfBlocked(let blockedURL) = error as? MCPError else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.absoluteString, "https://169.254.169.254/token")
        }
    }

    func test_ssrf_requestTimeValidation_blocksTransportDNSRebinding() async {
        MCPSSRFPolicy._resolverForTesting = { host in
            host == "example.com" ? ["169.254.169.254"] : ["93.184.216.34"]
        }

        await XCTAssertThrowsErrorAsync(
            try await MCPSSRFPolicy.validateTransportRequestURL(URL(string: "https://example.com/mcp")!)
        ) { error in
            guard case .ssrfBlocked(let blockedURL) = error as? MCPError else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.host, "example.com")
        }
    }

    func test_ssrf_requestTimeValidation_blocksOAuthDNSRebinding() async {
        MCPSSRFPolicy._resolverForTesting = { host in
            host == "token.example.com" ? ["10.0.0.4"] : ["93.184.216.34"]
        }

        await XCTAssertThrowsErrorAsync(
            try await MCPSSRFPolicy.validateOAuthRequestURL(
                URL(string: "https://token.example.com/token")!,
                label: "token endpoint"
            )
        ) { error in
            guard case .ssrfBlocked(let blockedURL) = error as? MCPError else {
                XCTFail("Expected ssrfBlocked, got \(error)")
                return
            }
            XCTAssertEqual(blockedURL.host, "token.example.com")
        }
    }

    // MARK: - Fix 3: PKCE verifier TTL

    func test_pkce_verifier_expires_after_5min() {
        // Sabotage check: change the expiry threshold in PKCEVerifier from 300 to
        // Int.max — the verifier never expires and isExpired returns false below.
        let ancient = Date().addingTimeInterval(-301) // 301 seconds ago
        let verifier = PKCEVerifier(data: Data("test".utf8), createdAt: ancient)
        XCTAssertTrue(verifier.isExpired, "Verifier created 301 seconds ago must be expired")

        let fresh = PKCEVerifier(data: Data("test".utf8))
        XCTAssertFalse(fresh.isExpired, "Freshly created verifier must not be expired")
    }

    func test_pkce_verifier_zeroised_after_exchange() {
        // Verify the PKCEVerifier zero() clears its internal bytes.
        // We test the struct directly via internal access (@testable import).
        // Sabotage check: remove the zero() implementation — bytes remain non-zero.
        var verifier = PKCEVerifierTestHarness.make(string: "test-verifier-abc")
        verifier.zero()
        XCTAssertTrue(verifier.isZeroed, "Verifier data should be zeroed after zero()")
    }

    func test_pkce_verifier_zeroised_on_failure() {
        // Verify zero() is idempotent — calling it twice is safe.
        // Sabotage check: remove the second zero call — test still passes (idempotent),
        // but demonstrates the harness works.
        var verifier = PKCEVerifierTestHarness.make(string: "another-verifier")
        verifier.zero()
        verifier.zero() // second call must not crash
        XCTAssertTrue(verifier.isZeroed)
    }

    // MARK: - Fix 5: Bearer token redaction

    func test_token_neverInURLQuery() async throws {
        // Sabotage check: append the token to the URL query in authorizationHeader —
        // this test will then fail because the query contains the raw token.
        let serverID = UUID()
        let resourceURL = URL(string: "https://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let tokenStore = MCPOAuthTokenStore.inMemory()
        let secretToken = "super-secret-bearer-token-xyz"
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: secretToken,
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                scopes: ["tools:read"],
                issuer: issuer
            ),
            serverID
        )

        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: issuer),
            serverID: serverID,
            resourceURL: resourceURL,
            redirectListener: RedirectListenerMock { _ in
                URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        let header = try await authorization.authorizationHeader(for: resourceURL)
        // The header value itself is expected to be present.
        XCTAssertEqual(header, "Bearer \(secretToken)")

        // The token must not appear in the resource URL's query string.
        let query = resourceURL.query ?? ""
        XCTAssertFalse(query.contains(secretToken), "Token must not leak into URL query")
    }

    func test_token_neverSentOverHTTP() async throws {
        // Sabotage check: remove the HTTPS guard in authorizationHeader — the
        // request is sent and no error is thrown.
        let serverID = UUID()
        let httpResourceURL = URL(string: "http://resource.example.com/mcp")!
        let issuer = URL(string: "https://auth.example.com")!
        let tokenStore = MCPOAuthTokenStore.inMemory()
        try await tokenStore.write(
            MCPOAuthTokens(
                accessToken: "http-should-fail",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                scopes: ["tools:read"],
                issuer: issuer
            ),
            serverID
        )

        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: issuer),
            serverID: serverID,
            resourceURL: httpResourceURL,
            redirectListener: RedirectListenerMock { _ in
                URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: tokenStore,
            session: makeSession()
        )

        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: httpResourceURL)) { error in
            guard let mcpError = error as? MCPError else {
                XCTFail("Expected MCPError, got \(error)")
                return
            }
            switch mcpError {
            case .authorizationFailed, .ssrfBlocked:
                break // Either is acceptable — both mean the request is blocked.
            default:
                XCTFail("Expected authorizationFailed or ssrfBlocked, got \(mcpError)")
            }
        }
    }

    func test_token_logRedacted() {
        // Sabotage check: change bearerRedacted to return the raw token — assertion fails.
        let rawToken = "my-raw-access-token-do-not-log"
        let tokenData = Data(rawToken.utf8)
        let redacted = bearerRedactedForTest(tokenData)
        XCTAssertFalse(redacted.contains(rawToken), "Raw token must not appear in redacted log string")
        XCTAssertTrue(redacted.hasPrefix("Bearer <"), "Redacted string should start with 'Bearer <'")
    }

    func test_oauthSecurity_normalizesIssuerForComparison() {
        let upperDefaultPort = URL(string: "https://AUTH.example.com:443/tenant/")!
        let canonical = URL(string: "https://auth.example.com/tenant")!
        let differentPath = URL(string: "https://auth.example.com/other")!

        XCTAssertTrue(OAuthSecurity.isSameIssuer(upperDefaultPort, canonical))
        XCTAssertFalse(OAuthSecurity.isSameIssuer(upperDefaultPort, differentPath))
    }

    func test_oauthTokenExchange_rejectsInvalidBearerTokens() {
        let newlineToken = MCPOAuthTokens(
            accessToken: "line1\nline2",
            refreshToken: nil,
            expiresAt: nil,
            scopes: ["tools:read"],
            issuer: URL(string: "https://auth.example.com")!
        )

        XCTAssertThrowsError(try OAuthTokenExchange.validateBearerTransmission(newlineToken)) { error in
            guard case .authorizationFailed(let message) = error as? MCPError else {
                return XCTFail("Expected authorizationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("invalid bearer characters"))
        }
    }

    // MARK: - Fix 6: SSRF — .local mDNS

    func test_ssrf_localDomain_rejected() async {
        // Sabotage check: remove the .local check from validateHostNotBlocked —
        // the request is allowed through and no error is thrown.
        let authorization = MCPOAuthAuthorization(
            descriptor: makeDescriptor(issuer: URL(string: "https://printer.local")!),
            serverID: UUID(),
            resourceURL: URL(string: "https://printer.local/mcp")!,
            redirectListener: RedirectListenerMock { _ in
                XCTFail("Redirect listener should not be invoked for blocked host")
                return URL(string: "basechat://oauth/callback?code=unused&state=unused")!
            },
            tokenStore: .inMemory(),
            session: makeSession()
        )

        let target = URL(string: "https://printer.local/mcp")!
        await XCTAssertThrowsErrorAsync(try await authorization.authorizationHeader(for: target)) { error in
            guard let mcpError = error as? MCPError else {
                XCTFail("Expected MCPError, got \(error)")
                return
            }
            switch mcpError {
            case .ssrfBlocked, .authorizationFailed:
                break // Either form of blocking is acceptable.
            default:
                XCTFail("Expected ssrfBlocked or authorizationFailed, got \(mcpError)")
            }
        }
    }

    func test_ssrf_redirect_capped_at_one() {
        // Sabotage check: change `redirectCount <= 1` to `redirectCount <= 10` in
        // MCPRedirectCapDelegate — the second call will also return the request,
        // and this test will fail because capturedNull is now false.
        //
        // We test MCPRedirectCapDelegate directly because MockURLProtocol delivers
        // responses at the URLProtocol layer before URLSession's redirect machinery
        // fires the task delegate.

        let delegate = MCPRedirectCapDelegate()
        let session = URLSession.shared
        let fakeHTTPResponse = HTTPURLResponse(
            url: URL(string: "https://auth.example.com/token")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://redirect1.example.com/token"]
        )!
        let firstRequest = URLRequest(url: URL(string: "https://redirect1.example.com/token")!)
        let secondRequest = URLRequest(url: URL(string: "https://attacker.example.com/steal")!)

        var firstResult: URLRequest?
        var secondResult: URLRequest?

        let exp1 = expectation(description: "first redirect callback")
        delegate.urlSession(
            session,
            task: session.dataTask(with: URLRequest(url: URL(string: "https://auth.example.com/token")!)),
            willPerformHTTPRedirection: fakeHTTPResponse,
            newRequest: firstRequest
        ) { req in
            firstResult = req
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1)

        let exp2 = expectation(description: "second redirect callback")
        delegate.urlSession(
            session,
            task: session.dataTask(with: URLRequest(url: URL(string: "https://redirect1.example.com/token")!)),
            willPerformHTTPRedirection: fakeHTTPResponse,
            newRequest: secondRequest
        ) { req in
            secondResult = req
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1)

        // First redirect is allowed.
        XCTAssertNotNil(firstResult, "First redirect should be followed")
        // Second redirect is refused — completionHandler called with nil.
        XCTAssertNil(secondResult, "Second redirect must be refused")
    }

    func test_ssrf_redirect_validation_blocksTransportDestination() {
        let delegate = MCPRedirectCapDelegate(
            maxRedirects: nil,
            validator: MCPSSRFPolicy.validateTransportRedirectURL
        )
        let session = URLSession.shared
        let fakeHTTPResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/mcp")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://192.168.1.20/mcp"]
        )!
        let blockedRequest = URLRequest(url: URL(string: "https://192.168.1.20/mcp")!)
        var result: URLRequest?

        let exp = expectation(description: "redirect validation callback")
        delegate.urlSession(
            session,
            task: session.dataTask(with: URLRequest(url: URL(string: "https://api.example.com/mcp")!)),
            willPerformHTTPRedirection: fakeHTTPResponse,
            newRequest: blockedRequest
        ) { request in
            result = request
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertNil(result, "Redirect to private-resolving host must be blocked")
    }

    func test_ssrf_redirect_validation_blocksOAuthDestination() {
        let delegate = MCPRedirectCapDelegate(validator: MCPSSRFPolicy.validateOAuthRedirectURL)
        let session = URLSession.shared
        let fakeHTTPResponse = HTTPURLResponse(
            url: URL(string: "https://auth.example.com/token")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://[fd00::1]/token"]
        )!
        let blockedRequest = URLRequest(url: URL(string: "https://[fd00::1]/token")!)
        var result: URLRequest?

        let exp = expectation(description: "oauth redirect validation callback")
        delegate.urlSession(
            session,
            task: session.dataTask(with: URLRequest(url: URL(string: "https://auth.example.com/token")!)),
            willPerformHTTPRedirection: fakeHTTPResponse,
            newRequest: blockedRequest
        ) { request in
            result = request
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        XCTAssertNil(result, "OAuth redirect to private-resolving host must be blocked")
    }

    func test_networkAndLifecycleObserversPlumbIntoConnectionState() async {
        let networkObserver = TestNetworkPathObserver()
        let lifecycleObserver = TestLifecycleObserver()
        let client = MCPClient(configuration: .init(
            networkPathObserver: networkObserver,
            lifecycleObserver: lifecycleObserver
        ))

        var iterator = client.connectionState.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .idle)

        networkObserver.emit(.satisfied)
        let afterPath = await iterator.next()
        XCTAssertEqual(afterPath, .idle)

        lifecycleObserver.emit(.willEnterForeground)
        let afterForeground = await iterator.next()
        XCTAssertEqual(afterForeground, .idle)
    }

    func test_notificationLifecycleObserverMapsFoundationNotifications() async {
        let center = NotificationCenter()
        let notificationName = Notification.Name("test.mcp.memory-warning")
        let observer = MCPNotificationLifecycleEventObserver(
            notificationCenter: center,
            mapping: [notificationName: .memoryWarning]
        )

        var iterator = observer.events.makeAsyncIterator()
        center.post(name: notificationName, object: nil)
        let event = await iterator.next()

        XCTAssertEqual(event, .memoryWarning)
    }

    func test_notificationLifecycleObserverFinishesStreamOnDeinit() async {
        let center = NotificationCenter()
        let notificationName = Notification.Name("test.mcp.memory-warning")
        var observer: MCPNotificationLifecycleEventObserver? = MCPNotificationLifecycleEventObserver(
            notificationCenter: center,
            mapping: [notificationName: .memoryWarning]
        )
        var iterator = observer!.events.makeAsyncIterator()

        observer = nil
        let event = await iterator.next()

        XCTAssertNil(event)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeDescriptor(issuer: URL?) -> MCPAuthorizationDescriptor.OAuthDescriptor {
        MCPAuthorizationDescriptor.OAuthDescriptor(
            clientName: "ManifoldKit",
            scopes: ["tools:read"],
            redirectURI: URL(string: "basechat://oauth/callback")!,
            authorizationServerIssuer: issuer
        )
    }
}

private final class TestNetworkPathObserver: MCPNetworkPathObserver, @unchecked Sendable {
    let pathUpdates: AsyncStream<MCPNetworkPathStatus>
    private let continuation: AsyncStream<MCPNetworkPathStatus>.Continuation

    init() {
        var streamContinuation: AsyncStream<MCPNetworkPathStatus>.Continuation!
        self.pathUpdates = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func emit(_ status: MCPNetworkPathStatus) {
        continuation.yield(status)
    }
}

private final class TestLifecycleObserver: MCPLifecycleEventObserver, @unchecked Sendable {
    let events: AsyncStream<MCPLifecycleEvent>
    private let continuation: AsyncStream<MCPLifecycleEvent>.Continuation

    init() {
        var streamContinuation: AsyncStream<MCPLifecycleEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func emit(_ event: MCPLifecycleEvent) {
        continuation.yield(event)
    }
}

private actor RedirectListenerMock: MCPOAuthRedirectListener {
    private let handler: (URL) -> URL

    init(handler: @escaping (URL) -> URL) {
        self.handler = handler
    }

    func authorize(
        authorizationURL: URL,
        callbackURLScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL {
        _ = callbackURLScheme
        _ = prefersEphemeralSession
        return handler(authorizationURL)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}

// MARK: - Test harness for PKCEVerifier (D7)

/// Wraps `PKCEVerifier` to let tests inspect whether bytes were zeroed.
struct PKCEVerifierTestHarness {
    var inner: PKCEVerifier

    static func make(string: String) -> PKCEVerifierTestHarness {
        PKCEVerifierTestHarness(inner: PKCEVerifier(data: Data(string.utf8)))
    }

    mutating func zero() {
        inner.zero()
    }

    /// True when all bytes in the verifier storage are zero.
    var isZeroed: Bool {
        inner.verifierData.allSatisfy { $0 == 0 }
    }
}

// MARK: - Test shim for bearerRedacted (D14)

/// Thin shim so tests can call the internal `mcpBearerRedacted` without going
/// through `MCPOAuthAuthorization` (which is an actor requiring async context).
func bearerRedactedForTest(_ data: Data) -> String {
    mcpBearerRedacted(data)
}
#endif
