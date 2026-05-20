import XCTest
@testable import ManifoldInference

/// Tests for ``ManifoldConfiguration/NetworkPolicy``, ``NetworkPolicyGuard``,
/// and ``NetworkPolicyURLProtocol``.
///
/// These tests cover:
/// - Default policy is `.unrestricted`.
/// - `.unrestricted` passes all hosts.
/// - `.allowlist` passes exact host matches and subdomain matches.
/// - `.allowlist` blocks non-listed hosts with ``NetworkPolicyError/hostNotAllowed``.
/// - Localhost is always allowed regardless of policy.
/// - Subdomain matching is correct (exact OR `.hasSuffix("." + apex)`).
final class NetworkPolicyTests: XCTestCase {

    // MARK: - ManifoldConfiguration defaults

    func test_defaultConfig_networkPolicy_isUnrestricted() {
        let config = ManifoldConfiguration()
        XCTAssertEqual(config.networkPolicy, .unrestricted)
    }

    func test_init_backwardsCompatible_withoutNetworkPolicy() {
        // Callers that don't pass networkPolicy: must still compile and get the
        // safe unrestricted default.
        let config = ManifoldConfiguration(appName: "TestApp")
        XCTAssertEqual(config.networkPolicy, .unrestricted)
    }

    func test_init_networkPolicy_canBeSetToAllowlist() {
        let config = ManifoldConfiguration(networkPolicy: .allowlist(["example.com"]))
        XCTAssertEqual(config.networkPolicy, .allowlist(["example.com"]))
    }

    // MARK: - NetworkPolicyGuard.check — unrestricted

    func test_unrestricted_allowsAnyHost() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.unrestricted
        let url = URL(string: "https://evil.example.net/steal")!
        // Must not throw.
        try NetworkPolicyGuard.check(url: url, policy: policy)
    }

    // MARK: - NetworkPolicyGuard.check — allowlist exact match

    func test_allowlist_exactMatch_passes() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com"])
        let url = URL(string: "https://example.com/path")!
        try NetworkPolicyGuard.check(url: url, policy: policy)
    }

    func test_allowlist_exactMatch_isCaseInsensitive() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["Example.Com"])
        let url = URL(string: "https://example.com/path")!
        // Should pass — comparison is lowercased on both sides.
        try NetworkPolicyGuard.check(url: url, policy: policy)
    }

    // MARK: - NetworkPolicyGuard.check — subdomain matching

    func test_allowlist_subdomain_passes() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com"])
        let url = URL(string: "https://sub.example.com/path")!
        try NetworkPolicyGuard.check(url: url, policy: policy)
    }

    func test_allowlist_deepSubdomain_passes() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["huggingface.co"])
        let url = URL(string: "https://cdn-lfs.huggingface.co/model-file")!
        try NetworkPolicyGuard.check(url: url, policy: policy)
    }

    func test_allowlist_apexInSubdomain_doesNotMatchUnrelatedApex() throws {
        // "badexample.com" is NOT a subdomain of "example.com".
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com"])
        let url = URL(string: "https://badexample.com/")!
        XCTAssertThrowsError(try NetworkPolicyGuard.check(url: url, policy: policy)) { error in
            guard case NetworkPolicyError.hostNotAllowed(let host) = error else {
                XCTFail("Expected NetworkPolicyError.hostNotAllowed, got \(error)")
                return
            }
            XCTAssertEqual(host, "badexample.com")
        }
    }

    // MARK: - NetworkPolicyGuard.check — blocked hosts

    func test_allowlist_blocksUnlistedHost() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com"])
        let url = URL(string: "https://other.com/api")!
        XCTAssertThrowsError(try NetworkPolicyGuard.check(url: url, policy: policy)) { error in
            guard case NetworkPolicyError.hostNotAllowed(let host) = error else {
                XCTFail("Expected NetworkPolicyError.hostNotAllowed, got \(error)")
                return
            }
            XCTAssertEqual(host, "other.com")
        }
    }

    func test_allowlist_blocksSubdomainOfUnlistedHost() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com"])
        let url = URL(string: "https://sub.other.com/api")!
        XCTAssertThrowsError(try NetworkPolicyGuard.check(url: url, policy: policy)) { error in
            guard case NetworkPolicyError.hostNotAllowed = error else {
                XCTFail("Expected NetworkPolicyError.hostNotAllowed, got \(error)")
                return
            }
        }
    }

    // MARK: - NetworkPolicyGuard.check — localhost bypass

    func test_allowlist_localhostAlwaysPasses() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com"])
        let localhostURL = URL(string: "http://localhost:11434/v1/chat")!
        // Must not throw — localhost is unconditionally permitted.
        try NetworkPolicyGuard.check(url: localhostURL, policy: policy)
    }

    func test_allowlist_loopback127AlwaysPasses() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com"])
        let loopbackURL = URL(string: "http://127.0.0.1:8080/v1")!
        try NetworkPolicyGuard.check(url: loopbackURL, policy: policy)
    }

    // MARK: - NetworkPolicyGuard.check — empty allowlist

    func test_emptyAllowlist_blocksAllNonLocalhost() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist([])
        let url = URL(string: "https://api.openai.com/v1/chat")!
        XCTAssertThrowsError(try NetworkPolicyGuard.check(url: url, policy: policy)) { error in
            guard case NetworkPolicyError.hostNotAllowed = error else {
                XCTFail("Expected NetworkPolicyError.hostNotAllowed, got \(error)")
                return
            }
        }
    }

    // MARK: - NetworkPolicyGuard.check — multiple entries

    func test_allowlist_multipleEntries_eachHostPasses() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com", "other.org"])
        try NetworkPolicyGuard.check(url: URL(string: "https://example.com/a")!, policy: policy)
        try NetworkPolicyGuard.check(url: URL(string: "https://sub.other.org/b")!, policy: policy)
    }

    func test_allowlist_multipleEntries_unlisted_throws() throws {
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["example.com", "other.org"])
        let url = URL(string: "https://third.com/c")!
        XCTAssertThrowsError(try NetworkPolicyGuard.check(url: url, policy: policy))
    }

    // MARK: - NetworkPolicyError equatability

    func test_networkPolicyError_equatable() {
        XCTAssertEqual(
            NetworkPolicyError.hostNotAllowed(host: "evil.com"),
            NetworkPolicyError.hostNotAllowed(host: "evil.com")
        )
        XCTAssertNotEqual(
            NetworkPolicyError.hostNotAllowed(host: "a.com"),
            NetworkPolicyError.hostNotAllowed(host: "b.com")
        )
    }

    // MARK: - NetworkPolicyURLProtocol integration

    /// End-to-end: an allowlisted host should fail with ``NetworkPolicyError``
    /// when a real URLSession request is made against a blocked host.
    ///
    /// Uses a UUID-scoped hostname to avoid colliding with any MockURLProtocol
    /// stubs registered elsewhere in the test process.
    func test_urlProtocol_blockedHost_failsWithNetworkPolicyError() throws {
        let uniqueHost = "blocked-\(UUID().uuidString.lowercased()).manifoldtest"
        let policy = ManifoldConfiguration.NetworkPolicy.allowlist(["allowedhost.manifoldtest"])

        let config = URLSessionConfiguration.ephemeral
        NetworkPolicyURLProtocol.register(in: config)
        let session = URLSession(configuration: config)

        let expectation = XCTestExpectation(description: "request fails with NetworkPolicyError")
        let url = URL(string: "https://\(uniqueHost)/api")!

        // Temporarily set the shared policy for this test. Restore afterward.
        let previous = ManifoldConfiguration.shared.networkPolicy
        ManifoldConfiguration.shared.networkPolicy = policy
        defer { ManifoldConfiguration.shared.networkPolicy = previous }

        let task = session.dataTask(with: url) { _, _, error in
            guard let error else {
                XCTFail("Expected an error but got a successful response")
                expectation.fulfill()
                return
            }
            if case NetworkPolicyError.hostNotAllowed(let host) = error {
                XCTAssertEqual(host, uniqueHost)
            } else {
                // The OS might surface the protocol error wrapped in an NSError —
                // verify the underlying cause carries the right domain/code.
                let nsErr = error as NSError
                XCTAssertEqual(
                    nsErr.domain,
                    (NetworkPolicyError.hostNotAllowed(host: uniqueHost) as NSError).domain,
                    "Expected NetworkPolicyError domain, got: \(nsErr.domain)"
                )
            }
            expectation.fulfill()
        }
        task.resume()

        let waiter = XCTWaiter()
        let result = waiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, "URLSession task did not complete within 5 seconds")
        session.invalidateAndCancel()
    }

    func test_urlProtocol_allowedHost_doesNotIntercept() throws {
        // When the policy is unrestricted the protocol must return canInit=false
        // and never intercept. We verify by checking that the URL protocol's
        // canInit returns false for unrestricted.
        let policy = ManifoldConfiguration.NetworkPolicy.unrestricted
        let previous = ManifoldConfiguration.shared.networkPolicy
        ManifoldConfiguration.shared.networkPolicy = policy
        defer { ManifoldConfiguration.shared.networkPolicy = previous }

        let request = URLRequest(url: URL(string: "https://example.com/api")!)
        // canInit is a class method — call via the type.
        let claimed = NetworkPolicyURLProtocol.canInit(with: request)
        XCTAssertFalse(claimed, "canInit must return false for unrestricted policy")
    }
}
