import XCTest
@testable import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference

/// Security-focused coverage for `APIEndpoint.isValid`.
///
/// Guards against SSRF via user-configured custom endpoints that could pivot
/// into the LAN, link-local metadata services (e.g. AWS IMDS at
/// 169.254.169.254), or non-HTTP schemes (`file://`, `ftp://`, `data:`).
final class CustomEndpointValidationTests: XCTestCase {

    private var endpointIDs: [String] = []

    override func tearDown() {
        super.tearDown()
        for id in endpointIDs {
            try? KeychainService.delete(account: id)
        }
        endpointIDs.removeAll()
    }

    private func makeEndpoint(baseURL: String) -> APIEndpoint {
        let endpoint = APIEndpoint(name: "Test", provider: .custom, baseURL: baseURL)
        endpointIDs.append(endpoint.id.uuidString)
        return endpoint
    }

    private func assertAccepted(
        _ url: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let endpoint = makeEndpoint(baseURL: url)
        XCTAssertTrue(
            endpoint.isValid,
            "Expected \(url) to be accepted but isValid returned false",
            file: file,
            line: line
        )
    }

    private func assertRejected(
        _ url: String,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let endpoint = makeEndpoint(baseURL: url)
        XCTAssertFalse(
            endpoint.isValid,
            "Expected \(url) to be rejected (\(reason)) but isValid returned true",
            file: file,
            line: line
        )
    }

    // MARK: - Accepted URLs

    func test_accepts_publicHTTPS() {
        assertAccepted("https://api.openai.com")
    }

    func test_accepts_localhostOllama() {
        assertAccepted("http://localhost:11434")
    }

    func test_accepts_loopbackIPv4() {
        assertAccepted("http://127.0.0.1:8080")
    }

    func test_accepts_loopbackIPv6() {
        assertAccepted("http://[::1]:8080")
    }

    func test_accepts_httpsLoopback() {
        // Loopback over HTTPS (self-signed dev setups) is legitimate.
        assertAccepted("https://localhost:11434")
    }

    // MARK: - Rejected: private IPv4 (RFC1918)

    func test_rejects_rfc1918_192_168() {
        assertRejected("http://192.168.1.1", reason: "RFC1918 192.168/16")
    }

    func test_rejects_rfc1918_10_x() {
        assertRejected("http://10.0.0.1", reason: "RFC1918 10/8")
    }

    func test_rejects_rfc1918_172_20() {
        assertRejected("http://172.20.0.1", reason: "RFC1918 172.16/12")
    }

    func test_rejects_rfc1918_over_https() {
        // HTTPS does not redeem a private-range target — the device is still
        // being turned into a LAN proxy.
        assertRejected("https://192.168.1.1", reason: "RFC1918 even over HTTPS")
    }

    func test_rejects_imds_over_https() {
        assertRejected("https://169.254.169.254", reason: "IMDS even over HTTPS")
    }

    func test_rejects_ipv6ULA_over_https() {
        assertRejected("https://[fc00::1]", reason: "IPv6 ULA even over HTTPS")
    }

    func test_rejects_ipv4MappedLoopback_over_https() {
        assertRejected("https://[::ffff:127.0.0.1]", reason: "IPv4-mapped loopback over HTTPS")
    }

    // MARK: - Rejected: link-local (IMDS)

    func test_rejects_imds() {
        assertRejected("http://169.254.169.254", reason: "AWS/GCP/Azure IMDS")
    }

    func test_rejects_linkLocalRange() {
        assertRejected("http://169.254.1.1", reason: "link-local 169.254/16")
    }

    // MARK: - Rejected: IPv6 private / link-local

    func test_rejects_ipv6ULA() {
        assertRejected("http://[fc00::1]:80", reason: "IPv6 ULA fc00::/7")
    }

    func test_rejects_ipv6FD() {
        assertRejected("http://[fd12:3456:789a::1]:80", reason: "IPv6 ULA fd00::/8")
    }

    func test_rejects_ipv6LinkLocal() {
        assertRejected("http://[fe80::1]:80", reason: "IPv6 link-local fe80::/10")
    }

    func test_rejects_ipv4MappedLoopback() {
        // Would otherwise bypass the IPv4 loopback-allowlist check.
        assertRejected("http://[::ffff:127.0.0.1]:80", reason: "IPv4-mapped loopback")
    }

    func test_rejects_ipv4MappedRFC1918() {
        assertRejected("http://[::ffff:192.168.1.1]:80", reason: "IPv4-mapped RFC1918")
    }

    // MARK: - Rejected: uppercase IPv6 hex

    func test_rejects_ipv6LinkLocal_uppercaseHex() {
        // URL.host() preserves original case for IPv6 literals. The classifier
        // must lowercase before matching or FE80::1 would bypass the fe80::/10
        // rule.
        assertRejected("https://[FE80::1]", reason: "uppercase IPv6 link-local")
    }

    func test_rejects_ipv4MappedLoopback_uppercaseHex() {
        assertRejected("https://[::FFFF:127.0.0.1]", reason: "uppercase IPv4-mapped loopback")
    }

    // MARK: - Rejected: trailing-dot FQDN bypass

    func test_rejects_rfc1918_trailingDot() {
        // `192.168.1.1.` resolves identically to `192.168.1.1` on every
        // mainstream resolver. Without trailing-dot normalisation it would
        // parse as a DNS name and slip through under HTTPS.
        assertRejected("https://192.168.1.1.", reason: "RFC1918 with trailing dot")
    }

    func test_rejects_imds_trailingDot() {
        assertRejected("https://169.254.169.254.", reason: "IMDS with trailing dot")
    }

    // MARK: - Rejected: non-http schemes

    func test_rejects_fileScheme() {
        assertRejected("file:///etc/passwd", reason: "file://")
    }

    func test_rejects_ftpScheme() {
        assertRejected("ftp://example.com", reason: "ftp://")
    }

    func test_rejects_dataScheme() {
        assertRejected("data:text/html;base64,PHNjcmlwdD4=", reason: "data:")
    }

    func test_rejects_javascriptScheme() {
        assertRejected("javascript:alert(1)", reason: "javascript:")
    }

    // MARK: - Rejected: reserved / multicast / broadcast

    func test_rejects_zeroAddress() {
        assertRejected("http://0.0.0.0", reason: "0.0.0.0/8 this-host")
    }

    func test_rejects_multicast() {
        assertRejected("http://224.0.0.1", reason: "224.0.0.0/4 multicast")
    }

    func test_rejects_reservedRange() {
        assertRejected("http://240.0.0.1", reason: "240.0.0.0/4 reserved")
    }

    func test_rejects_broadcast() {
        assertRejected("http://255.255.255.255", reason: "limited broadcast")
    }

    // MARK: - Rejected: alternate loopback encodings

    func test_rejects_loopbackRangeNon127001() {
        // 127.0.0.1 is explicitly allowed by isLocalhost, but the rest of
        // 127/8 is a common SSRF bypass surface and is blocked.
        assertRejected("http://127.0.0.2", reason: "alternate loopback")
    }

    func test_rejects_loopback127_1_1_1() {
        assertRejected("http://127.1.1.1", reason: "alternate loopback")
    }

    // MARK: - Rejected: non-HTTPS public host

    func test_rejects_httpPublicHost() {
        // Plain HTTP to a remote DNS name is rejected — only loopback is
        // exempt from the HTTPS requirement.
        assertRejected("http://api.openai.com", reason: "non-HTTPS public host")
    }

    // MARK: - Rejected: structurally invalid

    func test_rejects_empty() {
        assertRejected("", reason: "empty URL")
    }

    func test_rejects_missingScheme() {
        assertRejected("api.openai.com", reason: "no scheme")
    }

    // MARK: - DNS names (out of scope)

    func test_acceptsPublicDNSName() {
        // DNS rebinding mitigation is explicitly out of scope for this layer.
        // The validator cannot resolve synchronously, so a DNS name that could
        // *resolve* to a private range still passes the structural check as
        // long as it uses HTTPS.
        assertAccepted("https://api.example.com")
    }
}
