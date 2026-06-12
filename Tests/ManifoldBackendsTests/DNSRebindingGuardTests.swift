import XCTest
@testable import ManifoldBackends
@testable import ManifoldCloudCore
import ManifoldInference

/// Tests for the DNS-rebinding mitigation implemented in ``DNSRebindingGuard``.
///
/// The guard is the request-layer complement to `APIEndpoint.validate()`: while
/// validate() blocks IP-literal addresses at configuration time, this guard blocks
/// domain names that resolve to private/reserved IPs at connect time.
///
/// Tests use the `_resolverForTesting` seam so no real DNS queries are issued.
final class DNSRebindingGuardTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func tearDown() {
        // Always clear the testing seam so it doesn't bleed into other tests.
        DNSRebindingGuard._resolverForTesting = nil
        super.tearDown()
    }

    // MARK: - Localhost Bypass

    func test_localhostURL_alwaysPasses() async throws {
        // Sabotage check: removing the isLocalhostURL guard causes this to throw.
        try await DNSRebindingGuard.validate(url: URL(string: "http://localhost:11434")!)
    }

    func test_127_0_0_1_URL_alwaysPasses() async throws {
        try await DNSRebindingGuard.validate(url: URL(string: "http://127.0.0.1:8080")!)
    }

    func test_ipv6Loopback_URL_alwaysPasses() async throws {
        try await DNSRebindingGuard.validate(url: URL(string: "http://[::1]:11434")!)
    }

    // MARK: - IP Literal Blocking (no DNS resolution needed)

    func test_rfc1918_10_block_isBlocked() async {
        await assertBlocked(url: "https://10.0.0.1/api")
    }

    func test_rfc1918_172_16_block_isBlocked() async {
        await assertBlocked(url: "https://172.16.0.1/api")
    }

    func test_rfc1918_192_168_block_isBlocked() async {
        await assertBlocked(url: "https://192.168.1.100/api")
    }

    func test_linkLocal_awsIMDS_isBlocked() async {
        await assertBlocked(url: "https://169.254.169.254/latest/meta-data")
    }

    func test_multicast_isBlocked() async {
        await assertBlocked(url: "https://224.0.0.1/api")
    }

    func test_reserved_240_block_isBlocked() async {
        await assertBlocked(url: "https://240.0.0.1/api")
    }

    func test_ipv6UniqueLocal_isBlocked() async {
        await assertBlocked(url: "https://[fd00::1]/api")
    }

    func test_ipv6LinkLocal_isBlocked() async {
        await assertBlocked(url: "https://[fe80::1]/api")
    }

    func test_ipv4MappedIPv6_isBlocked() async {
        await assertBlocked(url: "https://[::ffff:192.168.1.1]/api")
    }

    // MARK: - Public IP Literal Allowed

    func test_publicIP_1_1_1_1_isAllowed() async throws {
        // Cloudflare DNS — a well-known public address.
        // Sabotage check: removing the nil-return path in classifyIPLiteral causes this to throw.
        try await DNSRebindingGuard.validate(url: URL(string: "https://1.1.1.1/api")!)
    }

    func test_publicIP_8_8_8_8_isAllowed() async throws {
        try await DNSRebindingGuard.validate(url: URL(string: "https://8.8.8.8/api")!)
    }

    // MARK: - DNS Resolution: Allowed Resolutions

    func test_dnsName_resolvingToPublicIP_isAllowed() async throws {
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] } // example.com
        try await DNSRebindingGuard.validate(url: URL(string: "https://api.example.com/v1")!)
    }

    func test_dnsName_resolvingToMultiplePublicIPs_isAllowed() async throws {
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"] }
        try await DNSRebindingGuard.validate(url: URL(string: "https://api.example.com/v1")!)
    }

    func test_knownProductionHost_openAI_isAllowed() async throws {
        // api.openai.com — certificate pinning also applies, but the guard should pass.
        DNSRebindingGuard._resolverForTesting = { _ in ["104.18.6.192", "104.18.7.192"] }
        try await DNSRebindingGuard.validate(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
    }

    // MARK: - DNS Resolution: Blocked Resolutions (Rebinding Scenarios)

    func test_dnsName_resolvingToPrivateIP_isBlocked() async {
        DNSRebindingGuard._resolverForTesting = { _ in ["192.168.1.1"] }
        await assertBlocked(url: "https://evil.example.com/api")
    }

    func test_dnsName_resolvingToLinkLocal_awsIMDS_isBlocked() async {
        DNSRebindingGuard._resolverForTesting = { _ in ["169.254.169.254"] }
        await assertBlocked(url: "https://rebind.attacker.com/api")
    }

    func test_dnsName_resolvingToLoopback_127_0_0_1_isBlocked() async {
        // A non-localhost URL that resolves to loopback is a rebinding attack.
        DNSRebindingGuard._resolverForTesting = { _ in ["127.0.0.1"] }
        await assertBlocked(url: "https://evil.example.com/api")
    }

    func test_dnsName_resolvingToIPv6Loopback_isBlocked() async {
        DNSRebindingGuard._resolverForTesting = { _ in ["::1"] }
        await assertBlocked(url: "https://evil.example.com/api")
    }

    func test_dnsName_mixedResults_onePrivate_isBlocked() async {
        // Even a single private address in a mixed result set should block.
        // Sabotage check: requiring ALL addresses to be private (instead of ANY) causes
        // this test to pass when it should not, missing the attack vector.
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34", "10.0.0.1"] }
        await assertBlocked(url: "https://evil.example.com/api")
    }

    func test_dnsName_resolvingToIPv6UniqueLocal_isBlocked() async {
        DNSRebindingGuard._resolverForTesting = { _ in ["fd12:3456:789a::1"] }
        await assertBlocked(url: "https://evil.example.com/api")
    }

    // MARK: - Error Type

    func test_blockedAddress_error_isNonRetryable() async {
        DNSRebindingGuard._resolverForTesting = { _ in ["192.168.1.1"] }
        do {
            try await DNSRebindingGuard.validate(url: URL(string: "https://evil.example.com/api")!)
            XCTFail("Expected blockedAddress error to be thrown")
        } catch let error as CloudBackendError {
            XCTAssertFalse(error.isRetryable,
                           "blockedAddress errors must not be retried — the address is still private")
            if case .blockedAddress = error {
                // correct case
            } else {
                XCTFail("Expected .blockedAddress, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_blockedAddress_errorDescription_isNonEmpty() async {
        DNSRebindingGuard._resolverForTesting = { _ in ["169.254.169.254"] }
        do {
            try await DNSRebindingGuard.validate(url: URL(string: "https://evil.example.com/api")!)
            XCTFail("Expected error")
        } catch let error as CloudBackendError {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Resolution Failure (fail-closed)

    func test_unresolvedHostname_isBlocked() async {
        // Resolution failure must block — an attacker can arrange SERVFAIL for
        // the guard's query, then serve a private IP to URLSession's next
        // resolver query (TTL-0 / SERVFAIL pattern), bypassing the guard if it
        // fails open. Sabotage: returning [] (not nil) here causes this to pass,
        // exposing the bypass.
        DNSRebindingGuard._resolverForTesting = { _ in nil }
        await assertBlocked(url: "https://does-not-exist.invalid/api")
    }

    func test_nodataResolution_passes() async throws {
        // A seam returning [] means "resolved successfully but no addresses" —
        // no blocked address was found, so the guard passes.
        // (In production getaddrinfo never returns success with zero addresses,
        // but the seam distinguishes NODATA from failure explicitly.)
        DNSRebindingGuard._resolverForTesting = { _ in [] }
        try await DNSRebindingGuard.validate(url: URL(string: "https://api.example.com/v1")!)
    }

    func test_hostlessURL_isBlocked() async {
        // A URL with no host (e.g. file://, data:) must not silently pass.
        // Sabotage: changing `throw` to `return` in the guard lets these through.
        await assertBlocked(url: "file:///etc/passwd")
    }

    // MARK: - Helpers

    private func assertBlocked(
        url urlString: String,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        guard let url = URL(string: urlString) else {
            XCTFail("Invalid test URL: \(urlString)", file: file, line: line)
            return
        }
        do {
            try await DNSRebindingGuard.validate(url: url)
            XCTFail(
                "Expected DNSRebindingGuard to block \(urlString) but it passed",
                file: file,
                line: line
            )
        } catch let error as CloudBackendError {
            if case .blockedAddress = error {
                // Expected — test passes.
            } else {
                XCTFail(
                    "Expected .blockedAddress but got \(error) for \(urlString)",
                    file: file,
                    line: line
                )
            }
        } catch {
            XCTFail(
                "Unexpected error type \(error) for \(urlString)",
                file: file,
                line: line
            )
        }
    }
}
