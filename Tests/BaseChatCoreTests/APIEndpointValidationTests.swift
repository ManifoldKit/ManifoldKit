import XCTest
@testable import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference

/// Unit tests for the typed `APIEndpoint.validate()` API.
///
/// These tests pin the mapping between URL input and the specific
/// `APIEndpointValidationReason` returned, so the settings UI can render
/// a useful message instead of a generic "Incomplete" label.
final class APIEndpointValidationTests: XCTestCase {

    private var endpointIDs: [String] = []

    override func tearDown() {
        super.tearDown()
        for id in endpointIDs {
            try? KeychainService.delete(account: id)
        }
        endpointIDs.removeAll()
    }

    private func makeEndpoint(baseURL: String, provider: APIProvider = .custom) -> APIEndpoint {
        let endpoint = APIEndpoint(name: "Test", provider: provider, baseURL: baseURL)
        endpointIDs.append(endpoint.id.uuidString)
        return endpoint
    }

    // `Result<Void, _>` is not `Equatable` because `Void` is not, so we pattern
    // match in helpers rather than using `XCTAssertEqual`.
    private func assertSuccess(
        _ endpoint: APIEndpoint,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if case .failure(let reason) = endpoint.validate() {
            XCTFail("Expected .success, got .failure(\(reason))", file: file, line: line)
        }
    }

    private func assertFailure(
        _ endpoint: APIEndpoint,
        _ expected: APIEndpointValidationReason,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        switch endpoint.validate() {
        case .success:
            XCTFail("Expected .failure(\(expected)), got .success", file: file, line: line)
        case .failure(let actual):
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    // MARK: - .success

    func test_validate_httpsRemote_success() {
        assertSuccess(makeEndpoint(baseURL: "https://api.openai.com"))
    }

    func test_validate_httpLocalhost_success() {
        assertSuccess(makeEndpoint(baseURL: "http://localhost:11434"))
    }

    func test_validate_http127_0_0_1_success() {
        assertSuccess(makeEndpoint(baseURL: "http://127.0.0.1:11434"))
    }

    func test_validate_httpIPv6Loopback_success() {
        assertSuccess(makeEndpoint(baseURL: "http://[::1]:11434"))
    }

    // MARK: - .emptyURL

    func test_validate_emptyBaseURL_emptyURL() {
        assertFailure(makeEndpoint(baseURL: ""), .emptyURL)
    }

    func test_validate_whitespaceOnlyBaseURL_emptyURL() {
        assertFailure(makeEndpoint(baseURL: "   \n\t "), .emptyURL)
    }

    // MARK: - .malformedURL

    func test_validate_noScheme_malformed() {
        assertFailure(makeEndpoint(baseURL: "api.openai.com"), .malformedURL)
    }

    func test_validate_schemeOnlyNoHost_malformed() {
        assertFailure(makeEndpoint(baseURL: "https://"), .malformedURL)
    }

    func test_validate_garbage_malformed() {
        // Spaces and control chars cannot be parsed into a URL.
        assertFailure(makeEndpoint(baseURL: "not a url at all \u{0007}"), .malformedURL)
    }

    // MARK: - .unsupportedScheme
    //
    // Only URLs that actually parse with a host reach the scheme check —
    // `file:///etc/passwd`, `data:…`, and `javascript:alert(1)` all fail earlier
    // as `.malformedURL` because `URL.host()` is nil for them. That's still a
    // rejection (`isValid == false`); we simply can't surface the scheme name.
    // Schemes like `ftp://` that include a host land in this branch.

    func test_validate_ftpScheme_unsupportedScheme() {
        assertFailure(makeEndpoint(baseURL: "ftp://example.com"), .unsupportedScheme("ftp"))
    }

    func test_validate_wsScheme_unsupportedScheme() {
        // WebSocket schemes are a plausible user mistake for a chat endpoint.
        assertFailure(makeEndpoint(baseURL: "ws://example.com"), .unsupportedScheme("ws"))
    }

    func test_validate_gopherScheme_unsupportedScheme() {
        assertFailure(makeEndpoint(baseURL: "gopher://example.com"), .unsupportedScheme("gopher"))
    }

    func test_validate_fileScheme_malformed() {
        // file:// has no host, so it fails the earlier parseability check
        // rather than reaching the scheme filter. The URL is still rejected;
        // `isValid` stays false.
        assertFailure(makeEndpoint(baseURL: "file:///etc/passwd"), .malformedURL)
    }

    func test_validate_dataScheme_malformed() {
        assertFailure(
            makeEndpoint(baseURL: "data:text/html;base64,PHNjcmlwdD4="),
            .malformedURL
        )
    }

    func test_validate_javascriptScheme_malformed() {
        assertFailure(makeEndpoint(baseURL: "javascript:alert(1)"), .malformedURL)
    }

    // MARK: - .insecureScheme

    func test_validate_httpRemote_insecureScheme() {
        assertFailure(makeEndpoint(baseURL: "http://example.com"), .insecureScheme)
    }

    func test_validate_httpRemoteWithPort_insecureScheme() {
        assertFailure(makeEndpoint(baseURL: "http://api.example.com:8080"), .insecureScheme)
    }

    // MARK: - .privateHost (RFC1918 private IPv4)

    func test_validate_rfc1918_192_168_privateHost() {
        assertFailure(makeEndpoint(baseURL: "https://192.168.1.1"), .privateHost)
    }

    func test_validate_rfc1918_10_x_privateHost() {
        assertFailure(makeEndpoint(baseURL: "https://10.0.0.1"), .privateHost)
    }

    func test_validate_rfc1918_172_20_privateHost() {
        assertFailure(makeEndpoint(baseURL: "https://172.20.0.1"), .privateHost)
    }

    func test_validate_rfc1918_trailingDot_privateHost() {
        // FQDN form with trailing dot resolves identically and must classify
        // the same way.
        assertFailure(makeEndpoint(baseURL: "https://192.168.1.1."), .privateHost)
    }

    // MARK: - .linkLocalHost (169.254/16 and fe80::/10)

    func test_validate_imds_linkLocalHost() {
        assertFailure(makeEndpoint(baseURL: "https://169.254.169.254"), .linkLocalHost)
    }

    func test_validate_linkLocalRange_linkLocalHost() {
        assertFailure(makeEndpoint(baseURL: "https://169.254.1.1"), .linkLocalHost)
    }

    func test_validate_ipv6LinkLocal_linkLocalHost() {
        assertFailure(makeEndpoint(baseURL: "https://[fe80::1]"), .linkLocalHost)
    }

    func test_validate_ipv6LinkLocal_uppercaseHex_linkLocalHost() {
        // URL.host() preserves original case for IPv6 literals — classifier
        // must lowercase before matching.
        assertFailure(makeEndpoint(baseURL: "https://[FE80::1]"), .linkLocalHost)
    }

    // MARK: - .ipv6UniqueLocal (fc00::/7)

    func test_validate_ipv6ULA_fc_ipv6UniqueLocal() {
        assertFailure(makeEndpoint(baseURL: "https://[fc00::1]"), .ipv6UniqueLocal)
    }

    func test_validate_ipv6ULA_fd_ipv6UniqueLocal() {
        // fd00::/8 is covered by the fc00::/7 prefix.
        assertFailure(makeEndpoint(baseURL: "https://[fd12:3456:789a::1]"), .ipv6UniqueLocal)
    }

    // MARK: - .ipv4MappedLoopback (::ffff:X)

    func test_validate_ipv4MappedLoopback_ipv4MappedLoopback() {
        assertFailure(
            makeEndpoint(baseURL: "https://[::ffff:127.0.0.1]"),
            .ipv4MappedLoopback
        )
    }

    func test_validate_ipv4MappedRFC1918_ipv4MappedLoopback() {
        // Mapped RFC1918 is classified as ipv4MappedLoopback — the whole
        // ::ffff:0:0/96 range is rejected as a single class.
        assertFailure(
            makeEndpoint(baseURL: "https://[::ffff:192.168.1.1]"),
            .ipv4MappedLoopback
        )
    }

    func test_validate_ipv4MappedLoopback_uppercaseHex_ipv4MappedLoopback() {
        assertFailure(
            makeEndpoint(baseURL: "https://[::FFFF:127.0.0.1]"),
            .ipv4MappedLoopback
        )
    }

    // MARK: - .multicastReserved (0/8, 127/8 non-loopback, 224/4, 240/4)

    func test_validate_zeroAddress_multicastReserved() {
        assertFailure(makeEndpoint(baseURL: "https://0.0.0.0"), .multicastReserved)
    }

    func test_validate_alternateLoopback_multicastReserved() {
        // 127.0.0.1 is the only accepted loopback; 127.0.0.2 etc. are
        // alternate-encoding SSRF bypass vectors.
        assertFailure(makeEndpoint(baseURL: "https://127.0.0.2"), .multicastReserved)
    }

    func test_validate_alternateLoopback_127_1_1_1_multicastReserved() {
        assertFailure(makeEndpoint(baseURL: "https://127.1.1.1"), .multicastReserved)
    }

    func test_validate_multicast_multicastReserved() {
        assertFailure(makeEndpoint(baseURL: "https://224.0.0.1"), .multicastReserved)
    }

    func test_validate_reservedRange_multicastReserved() {
        assertFailure(makeEndpoint(baseURL: "https://240.0.0.1"), .multicastReserved)
    }

    func test_validate_broadcast_multicastReserved() {
        assertFailure(makeEndpoint(baseURL: "https://255.255.255.255"), .multicastReserved)
    }

    // MARK: - isValid derivation

    func test_validate_isValid_derivedFromValidate_success() {
        let endpoint = makeEndpoint(baseURL: "https://api.openai.com")
        XCTAssertTrue(endpoint.isValid)
        if case .failure = endpoint.validate() {
            XCTFail("isValid was true but validate() returned .failure")
        }
    }

    func test_validate_isValid_derivedFromValidate_failure() {
        let endpoint = makeEndpoint(baseURL: "http://example.com")
        XCTAssertFalse(endpoint.isValid)
        if case .success = endpoint.validate() {
            XCTFail("isValid was false but validate() returned .success")
        }
    }

    func test_validate_isValid_false_for_privateHost() {
        // isValid must stay in sync with every new failure branch.
        let endpoint = makeEndpoint(baseURL: "https://192.168.1.1")
        XCTAssertFalse(endpoint.isValid)
    }

    // MARK: - LocalizedError messages

    func test_localizedDescription_emptyURL() {
        let reason = APIEndpointValidationReason.emptyURL
        XCTAssertEqual(reason.errorDescription, "Enter a server URL to continue.")
        // `localizedDescription` routes through LocalizedError.errorDescription.
        XCTAssertFalse(reason.localizedDescription.isEmpty)
    }

    func test_localizedDescription_malformedURL() {
        let reason = APIEndpointValidationReason.malformedURL
        XCTAssertNotNil(reason.errorDescription)
        let msg = reason.errorDescription ?? ""
        XCTAssertTrue(msg.contains("scheme") || msg.contains("valid"),
                      "Malformed URL message should mention scheme or validity: \(msg)")
    }

    func test_localizedDescription_unsupportedScheme() {
        let reason = APIEndpointValidationReason.unsupportedScheme("ftp")
        let msg = reason.errorDescription ?? ""
        XCTAssertTrue(msg.contains("ftp"),
                      "Unsupported-scheme message should surface the rejected scheme: \(msg)")
        XCTAssertTrue(msg.contains("https"),
                      "Unsupported-scheme message should point users at https: \(msg)")
    }

    func test_localizedDescription_insecureScheme() {
        let reason = APIEndpointValidationReason.insecureScheme
        XCTAssertNotNil(reason.errorDescription)
        let msg = reason.errorDescription ?? ""
        XCTAssertTrue(msg.contains("https"),
                      "Insecure scheme message should mention https: \(msg)")
    }

    func test_localizedDescription_privateHost() {
        let msg = APIEndpointValidationReason.privateHost.errorDescription ?? ""
        XCTAssertTrue(msg.contains("192.168") || msg.contains("10."),
                      "privateHost message should cite concrete RFC1918 ranges: \(msg)")
    }

    func test_localizedDescription_linkLocalHost() {
        let msg = APIEndpointValidationReason.linkLocalHost.errorDescription ?? ""
        XCTAssertTrue(msg.contains("169.254") || msg.contains("metadata"),
                      "linkLocalHost message should cite 169.254 or metadata context: \(msg)")
    }

    func test_localizedDescription_ipv6UniqueLocal() {
        let msg = APIEndpointValidationReason.ipv6UniqueLocal.errorDescription ?? ""
        XCTAssertTrue(msg.contains("fc00") || msg.lowercased().contains("ipv6"),
                      "ipv6UniqueLocal message should mention fc00 or IPv6: \(msg)")
    }

    func test_localizedDescription_ipv4MappedLoopback() {
        let msg = APIEndpointValidationReason.ipv4MappedLoopback.errorDescription ?? ""
        XCTAssertTrue(msg.contains("::ffff") || msg.lowercased().contains("mapped"),
                      "ipv4MappedLoopback message should describe the mapped form: \(msg)")
    }

    func test_localizedDescription_multicastReserved() {
        let msg = APIEndpointValidationReason.multicastReserved.errorDescription ?? ""
        XCTAssertTrue(msg.lowercased().contains("multicast") || msg.lowercased().contains("reserved"),
                      "multicastReserved message should describe the class: \(msg)")
    }

    // MARK: - Equatable

    func test_reason_equatable() {
        XCTAssertEqual(APIEndpointValidationReason.emptyURL, APIEndpointValidationReason.emptyURL)
        XCTAssertNotEqual(APIEndpointValidationReason.emptyURL, APIEndpointValidationReason.malformedURL)
        XCTAssertEqual(
            APIEndpointValidationReason.unsupportedScheme("ftp"),
            APIEndpointValidationReason.unsupportedScheme("ftp")
        )
        XCTAssertNotEqual(
            APIEndpointValidationReason.unsupportedScheme("ftp"),
            APIEndpointValidationReason.unsupportedScheme("file")
        )
    }
}
