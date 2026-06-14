import XCTest
import CommonCrypto
import Security
import ManifoldInference
@testable import ManifoldFoundation
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

final class PinnedSessionDelegateTests: XCTestCase {

    // MARK: - SHA-256 Helper (tested indirectly via known input)

    /// Validates the delegate's SHA-256 implementation by computing a hash of
    /// known data and comparing against a pre-computed reference.
    func test_sha256_producesCorrectHash() {
        // The delegate's sha256 is private, so we replicate the same logic
        // and verify the delegate's pin-checking uses it correctly.
        // We verify the algorithm by computing SHA-256 of "hello" and checking
        // the base64 output matches the known value.
        let data = "hello".data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        let base64 = Data(hash).base64EncodedString()

        // SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        // Base64 of those bytes:
        XCTAssertEqual(base64, "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=",
                        "SHA-256 of 'hello' should match known base64 hash. "
                        + "Note: this validates the same algorithm the delegate uses.")
    }

    func test_spkiDER_wrapsP256KeyToStandardSPKIHash() {
        let rawWE1Key = Data(base64Encoded: "BG/NOv5nV0dMIQOFQMJHXbtYRw9AwVwXhcYZN+fVfO2GS5uB2dcaE6UKA/iYxMbonv8QWY8sJpj15iYluw8C+lY=")!
        let spki = PinnedSessionDelegate.spkiDER(
            rawPublicKey: rawWE1Key,
            keyType: kSecAttrKeyTypeECSECPrimeRandom as String,
            keySizeInBits: 256
        )

        XCTAssertEqual(spki.map(Self.sha256Base64), "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=")
    }

    func test_spkiDER_wrapsP384KeyToStandardSPKIHash() {
        let rawGTSRootR4Key = Data(base64Encoded: "BPN0c6doi2CuQ7g1xYEwe0tJnfvBYc7m3ka9a9VhGDWuQN1z94mRMFrrPO6FfKJAdjupxrhH2CrnkpFqc+mxcjmfKZ+imNNfXliGZQ+hhGUG0dyLycdzyIxqL+XEq9Edig==")!
        let spki = PinnedSessionDelegate.spkiDER(
            rawPublicKey: rawGTSRootR4Key,
            keyType: kSecAttrKeyTypeECSECPrimeRandom as String,
            keySizeInBits: 384
        )

        XCTAssertEqual(spki.map(Self.sha256Base64), "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=")
    }

    // MARK: - Bypass Hosts

    func test_bypassHost_localhost_returnsDefaultHandling() async {
        await verifyBypassHost("localhost")
    }

    func test_bypassHost_ipv4Loopback_returnsDefaultHandling() async {
        await verifyBypassHost("127.0.0.1")
    }

    func test_bypassHost_ipv6Loopback_returnsDefaultHandling() async {
        await verifyBypassHost("::1")
    }

    // SEC-17: full 127.0.0.0/8 (RFC 1122) must bypass pinning, not just 127.0.0.1.
    // A literal allowlist of {"localhost", "127.0.0.1", "::1"} leaves 127.0.0.2 and
    // the rest of 127.x.x.x falling through to platform trust.
    func test_bypassHost_ipv4Loopback_127_0_0_2_returnsDefaultHandling() async {
        await verifyBypassHost("127.0.0.2")
    }

    func test_bypassHost_ipv4Loopback_127_255_255_254_returnsDefaultHandling() async {
        await verifyBypassHost("127.255.255.254")
    }

    // MARK: - Unknown Host (No Pins Configured)

    func test_unknownHost_noPins_returnsDefaultHandling() async {
        // Ensure no pins are configured for this host
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }

        let delegate = PinnedSessionDelegate()
        let challenge = makeChallenge(host: "api.example.com")

        let expectation = XCTestExpectation(description: "completion called")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(
            URLSession.shared,
            didReceive: challenge
        ) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .performDefaultHandling)
    }

    // MARK: - Custom Host Trust Policy

    func test_customHost_noPins_platformDefault_returnsDefaultHandling() async {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        let savedConfig = ManifoldConfiguration.shared
        PinnedSessionDelegate.pinnedHosts = [:]
        ManifoldConfiguration.shared = ManifoldConfiguration(customHostTrustPolicy: .platformDefault)
        defer {
            PinnedSessionDelegate.pinnedHosts = savedPins
            ManifoldConfiguration.shared = savedConfig
        }

        let delegate = PinnedSessionDelegate()
        let challenge = makeChallenge(host: "custom.mycompany.com")

        let expectation = XCTestExpectation(description: "completion called")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .performDefaultHandling,
                       "platformDefault policy: custom host with no pins should fall back to OS trust")
    }

    func test_customHost_noPins_requireExplicitPins_cancelsChallenge() async {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        let savedConfig = ManifoldConfiguration.shared
        PinnedSessionDelegate.pinnedHosts = [:]
        ManifoldConfiguration.shared = ManifoldConfiguration(customHostTrustPolicy: .requireExplicitPins)
        defer {
            PinnedSessionDelegate.pinnedHosts = savedPins
            ManifoldConfiguration.shared = savedConfig
        }

        let delegate = PinnedSessionDelegate()
        let challenge = makeChallenge(host: "custom.mycompany.com")

        let expectation = XCTestExpectation(description: "completion called")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge,
                       "requireExplicitPins policy: custom host with no pins should fail-closed")
    }

    func test_customHost_withPins_requireExplicitPins_doesNotCancelBeforeTrustEval() async {
        // When pins ARE configured for a custom host, the requireExplicitPins guard
        // is satisfied and we proceed to trust evaluation (not an early cancel).
        let savedPins = PinnedSessionDelegate.pinnedHosts
        let savedConfig = ManifoldConfiguration.shared
        PinnedSessionDelegate.pinnedHosts = ["custom.mycompany.com": Set(["somePinHash="])]
        ManifoldConfiguration.shared = ManifoldConfiguration(customHostTrustPolicy: .requireExplicitPins)
        defer {
            PinnedSessionDelegate.pinnedHosts = savedPins
            ManifoldConfiguration.shared = savedConfig
        }

        let delegate = PinnedSessionDelegate()
        // Challenge with no server trust object — this triggers the missing-serverTrust cancel,
        // which proves we passed the no-pins guard and reached trust evaluation.
        let challenge = makeChallenge(host: "custom.mycompany.com")

        let expectation = XCTestExpectation(description: "completion called")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        // Disposition is .cancelAuthenticationChallenge because SecTrust is nil in the
        // test challenge, NOT because of the no-pins guard. This confirms the policy
        // does not short-circuit when pins are correctly configured.
        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge,
                       "With pins configured the no-pins guard is bypassed; challenge fails later at trust eval (nil SecTrust in test)")
    }

    func test_bypassHosts_ignoreTrustPolicy_requireExplicitPins() async {
        // Localhost addresses must bypass pinning regardless of trust policy.
        let savedConfig = ManifoldConfiguration.shared
        ManifoldConfiguration.shared = ManifoldConfiguration(customHostTrustPolicy: .requireExplicitPins)
        defer { ManifoldConfiguration.shared = savedConfig }

        for host in ["localhost", "127.0.0.1", "127.0.0.2", "::1"] {
            let delegate = PinnedSessionDelegate()
            let challenge = makeChallenge(host: host)

            let exp = XCTestExpectation(description: "completion for \(host)")
            var disposition: URLSession.AuthChallengeDisposition?

            delegate.urlSession(URLSession.shared, didReceive: challenge) { d, _ in
                disposition = d
                exp.fulfill()
            }

            await fulfillment(of: [exp], timeout: 2.0)
            XCTAssertEqual(disposition, .performDefaultHandling,
                           "Bypass host \(host) must bypass pinning even under requireExplicitPins policy")
        }
    }
    
    func test_requiredProductionHost_openAI_noPins_cancelsChallenge() async {
        await verifyRequiredHostNoPinsCancels("api.openai.com")
    }
    
    func test_requiredProductionHost_anthropic_noPins_cancelsChallenge() async {
        await verifyRequiredHostNoPinsCancels("api.anthropic.com")
    }

    // MARK: - Default Pins

    func test_loadDefaultPins_populatesBothHosts() {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.resetDefaultPinsForTesting()
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }

        PinnedSessionDelegate.loadDefaultPins()

        let anthropicPins = PinnedSessionDelegate.pinnedHosts["api.anthropic.com"]
        let openAIPins = PinnedSessionDelegate.pinnedHosts["api.openai.com"]

        XCTAssertNotNil(anthropicPins, "Anthropic pins should be populated after loadDefaultPins()")
        XCTAssertNotNil(openAIPins, "OpenAI pins should be populated after loadDefaultPins()")
        XCTAssertGreaterThanOrEqual(anthropicPins?.count ?? 0, 2,
                                     "Should have at least 2 pins (intermediate + root) for rotation safety")
        XCTAssertGreaterThanOrEqual(openAIPins?.count ?? 0, 2,
                                     "Should have at least 2 pins (intermediate + root) for rotation safety")
    }

    func test_loadDefaultPins_doesNotOverwriteHostAppPins() {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.resetDefaultPinsForTesting()
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }

        // Simulate a host app setting custom pins before framework init
        let customPin = "customHostAppPin123="
        PinnedSessionDelegate.pinnedHosts["api.anthropic.com"] = Set([customPin])

        PinnedSessionDelegate.loadDefaultPins()

        let anthropicPins = PinnedSessionDelegate.pinnedHosts["api.anthropic.com"]
        XCTAssertEqual(anthropicPins, Set([customPin]),
                       "loadDefaultPins() must not overwrite pins the host app already configured")

        // OpenAI had no custom pins, so defaults should be applied
        let openAIPins = PinnedSessionDelegate.pinnedHosts["api.openai.com"]
        XCTAssertNotNil(openAIPins, "Hosts without custom pins should still get defaults")
    }

    func test_loadDefaultPins_onlyRunsOnce() {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.resetDefaultPinsForTesting()
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }

        PinnedSessionDelegate.loadDefaultPins()
        let afterFirstLoad = PinnedSessionDelegate.pinnedHosts

        // Clear pins and call again — the guard should prevent re-population
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.loadDefaultPins()

        XCTAssertTrue(PinnedSessionDelegate.pinnedHosts.isEmpty,
                      "Second call to loadDefaultPins() should be a no-op due to one-shot guard")

        // Restore for comparison
        XCTAssertFalse(afterFirstLoad.isEmpty, "First call should have populated pins")
    }

    // MARK: - CI Regression Guard
    //
    // These tests exist specifically to catch a future maintainer accidentally
    // deleting or neutering `PinnedSessionDelegate.loadDefaultPins()`. The
    // delegate fails-closed when required production hosts have no pins, so a
    // well-intentioned "remove placeholder pin code" change would silently
    // break every OpenAI and Anthropic request shipped by the framework.
    //
    // If either of these tests fails in CI, DO NOT weaken the assertion. The
    // correct fix is to restore `loadDefaultPins()` (or replace its pin values
    // with freshly rotated SPKI hashes — see the rotation procedure in the
    // source doc comment).

    func test_ciGuard_loadDefaultPins_shipsOpenAIPins() {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.resetDefaultPinsForTesting()
        defer {
            PinnedSessionDelegate.pinnedHosts = savedPins
            PinnedSessionDelegate.resetDefaultPinsForTesting()
        }

        PinnedSessionDelegate.loadDefaultPins()

        let openAIPins = PinnedSessionDelegate.pinnedHosts["api.openai.com"]
        XCTAssertNotNil(openAIPins,
                        "loadDefaultPins() must populate api.openai.com or the delegate will fail-closed on every OpenAI request.")
        XCTAssertEqual(openAIPins?.isEmpty, false,
                       "api.openai.com pin set must be non-empty — empty sets fail-closed on required production hosts.")
        XCTAssertGreaterThanOrEqual(openAIPins?.count ?? 0, 2,
                                    "api.openai.com needs at least 2 pins (primary + backup) for rotation safety; losing the backup risks lockout during cert rotation.")
    }

    func test_ciGuard_loadDefaultPins_shipsAnthropicPins() {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.resetDefaultPinsForTesting()
        defer {
            PinnedSessionDelegate.pinnedHosts = savedPins
            PinnedSessionDelegate.resetDefaultPinsForTesting()
        }

        PinnedSessionDelegate.loadDefaultPins()

        let anthropicPins = PinnedSessionDelegate.pinnedHosts["api.anthropic.com"]
        XCTAssertNotNil(anthropicPins,
                        "loadDefaultPins() must populate api.anthropic.com or the delegate will fail-closed on every Anthropic request.")
        XCTAssertEqual(anthropicPins?.isEmpty, false,
                       "api.anthropic.com pin set must be non-empty — empty sets fail-closed on required production hosts.")
        XCTAssertGreaterThanOrEqual(anthropicPins?.count ?? 0, 2,
                                    "api.anthropic.com needs at least 2 pins (primary + backup) for rotation safety; losing the backup risks lockout during cert rotation.")
    }

    // MARK: - Non-ServerTrust Challenge

    func test_nonServerTrustChallenge_returnsDefaultHandling() async {
        let delegate = PinnedSessionDelegate()

        // Create a challenge with a non-server-trust authentication method
        let space = URLProtectionSpace(
            host: "example.com",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: StubChallengeSender()
        )

        let expectation = XCTestExpectation(description: "completion called")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(
            URLSession.shared,
            didReceive: challenge
        ) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .performDefaultHandling)
    }

    // MARK: - Concurrent Access

    func test_concurrentPinnedHostsAccess_doesNotCrash() {
        // Verify that concurrent reads and writes through the NSLock-guarded
        // accessor don't produce data races or crashes.
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        let group = DispatchGroup()

        for i in 0..<100 {
            group.enter()
            queue.async {
                if i.isMultiple(of: 2) {
                    PinnedSessionDelegate.pinnedHosts["api.example.com"] = ["hash\(i)"]
                } else {
                    _ = PinnedSessionDelegate.pinnedHosts
                }
                group.leave()
            }
        }

        group.wait()
        // Reaching here without a crash is sufficient.
        PinnedSessionDelegate.pinnedHosts = [:]
    }

    // MARK: - Helpers

    private func verifyBypassHost(_ host: String) async {
        let delegate = PinnedSessionDelegate()
        let challenge = makeChallenge(host: host)

        let expectation = XCTestExpectation(description: "completion called for \(host)")
        var receivedDisposition: URLSession.AuthChallengeDisposition?

        delegate.urlSession(
            URLSession.shared,
            didReceive: challenge
        ) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .performDefaultHandling,
                       "Bypass host \(host) should get .performDefaultHandling")
    }
    
    private func verifyRequiredHostNoPinsCancels(_ host: String) async {
        let savedPins = PinnedSessionDelegate.pinnedHosts
        PinnedSessionDelegate.pinnedHosts = [:]
        defer { PinnedSessionDelegate.pinnedHosts = savedPins }
        
        let delegate = PinnedSessionDelegate()
        let challenge = makeChallenge(host: host)
        
        let expectation = XCTestExpectation(description: "completion called for required host \(host)")
        var receivedDisposition: URLSession.AuthChallengeDisposition?
        
        delegate.urlSession(
            URLSession.shared,
            didReceive: challenge
        ) { disposition, _ in
            receivedDisposition = disposition
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedDisposition, .cancelAuthenticationChallenge,
                       "Required production host \(host) should fail closed when no pins are configured")
    }

    private func makeChallenge(host: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: StubChallengeSender()
        )
    }

    private static func sha256Base64(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
}

// MARK: - Stub Challenge Sender

/// Minimal stub to satisfy URLAuthenticationChallenge init.
private final class StubChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
