import XCTest
@testable import ManifoldInference

/// Tests for the shared IP-address classification logic in ``PrivateIPClassifier``.
///
/// These tests pin every blocked range and the allowed-public boundary so that a
/// future change to `classifyIPv4` or `classifyIPv6` is immediately visible.
/// They also cover ``PrivateIPClassifier/isLocalhostURL(_:)`` and the trailing-dot
/// FQDN normalisation used for bypass prevention.
final class PrivateIPClassifierTests: XCTestCase {

    // MARK: - isLocalhostURL

    func test_isLocalhostURL_localhost_isTrue() {
        XCTAssertTrue(PrivateIPClassifier.isLocalhostURL(URL(string: "http://localhost:11434")!))
    }

    func test_isLocalhostURL_127_0_0_1_isTrue() {
        XCTAssertTrue(PrivateIPClassifier.isLocalhostURL(URL(string: "http://127.0.0.1:8080")!))
    }

    func test_isLocalhostURL_ipv6Loopback_isTrue() {
        XCTAssertTrue(PrivateIPClassifier.isLocalhostURL(URL(string: "http://[::1]:11434")!))
    }

    func test_isLocalhostURL_publicIP_isFalse() {
        XCTAssertFalse(PrivateIPClassifier.isLocalhostURL(URL(string: "https://1.1.1.1")!))
    }

    func test_isLocalhostURL_privateIP_isFalse() {
        XCTAssertFalse(PrivateIPClassifier.isLocalhostURL(URL(string: "https://192.168.1.1")!))
    }

    func test_isLocalhostURL_broadLoopback_127_0_0_2_isFalse() {
        // Broader 127.x.x.x other than 127.0.0.1 must not be treated as localhost.
        XCTAssertFalse(PrivateIPClassifier.isLocalhostURL(URL(string: "http://127.0.0.2:8080")!))
    }

    // MARK: - isLoopbackHost (SEC-17)

    func test_isLoopbackHost_localhost_isTrue() {
        XCTAssertTrue(PrivateIPClassifier.isLoopbackHost("localhost"))
    }

    func test_isLoopbackHost_127_0_0_1_isTrue() {
        XCTAssertTrue(PrivateIPClassifier.isLoopbackHost("127.0.0.1"))
    }

    func test_isLoopbackHost_127_0_0_2_isTrue() {
        // SEC-17: full 127.0.0.0/8 must be loopback, not just 127.0.0.1.
        XCTAssertTrue(PrivateIPClassifier.isLoopbackHost("127.0.0.2"))
    }

    func test_isLoopbackHost_127_255_255_255_isTrue() {
        XCTAssertTrue(PrivateIPClassifier.isLoopbackHost("127.255.255.255"))
    }

    func test_isLoopbackHost_ipv6Loopback_isTrue() {
        XCTAssertTrue(PrivateIPClassifier.isLoopbackHost("::1"))
    }

    func test_isLoopbackHost_caseInsensitive() {
        XCTAssertTrue(PrivateIPClassifier.isLoopbackHost("LOCALHOST"))
    }

    func test_isLoopbackHost_128_0_0_1_isFalse() {
        // Off-by-one: first non-loopback /8.
        XCTAssertFalse(PrivateIPClassifier.isLoopbackHost("128.0.0.1"))
    }

    func test_isLoopbackHost_126_255_255_255_isFalse() {
        // Off-by-one: last address before loopback /8.
        XCTAssertFalse(PrivateIPClassifier.isLoopbackHost("126.255.255.255"))
    }

    func test_isLoopbackHost_privateIP_isFalse() {
        XCTAssertFalse(PrivateIPClassifier.isLoopbackHost("192.168.1.1"))
    }

    func test_isLoopbackHost_publicIP_isFalse() {
        XCTAssertFalse(PrivateIPClassifier.isLoopbackHost("1.1.1.1"))
    }

    func test_isLoopbackHost_emptyString_isFalse() {
        XCTAssertFalse(PrivateIPClassifier.isLoopbackHost(""))
    }

    // MARK: - classifyIPLiteral: Allowed Addresses

    func test_publicIP_1_1_1_1_isNil() {
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("1.1.1.1"))
    }

    func test_publicIP_8_8_8_8_isNil() {
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("8.8.8.8"))
    }

    func test_publicIP_93_184_216_34_isNil() {
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("93.184.216.34"))
    }

    func test_dnsName_returnsNil() {
        // DNS names are not IP literals — they must not be classified here.
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("api.openai.com"))
    }

    // MARK: - classifyIPLiteral: RFC1918 Private Ranges

    func test_rfc1918_10_0_0_0_isPrivate() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("10.0.0.0"), .privateHost)
    }

    func test_rfc1918_10_255_255_255_isPrivate() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("10.255.255.255"), .privateHost)
    }

    func test_rfc1918_172_16_0_0_isPrivate() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("172.16.0.0"), .privateHost)
    }

    func test_rfc1918_172_31_255_255_isPrivate() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("172.31.255.255"), .privateHost)
    }

    func test_rfc1918_172_32_0_0_isNil() {
        // 172.32.x.x is outside RFC1918 — should be allowed.
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("172.32.0.0"))
    }

    func test_rfc1918_172_15_255_255_isNil() {
        // 172.15.x.x is outside RFC1918 — should be allowed.
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("172.15.255.255"))
    }

    func test_rfc1918_192_168_0_0_isPrivate() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("192.168.0.0"), .privateHost)
    }

    func test_rfc1918_192_168_255_255_isPrivate() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("192.168.255.255"), .privateHost)
    }

    // MARK: - classifyIPLiteral: CGNAT / Shared Address Space (RFC 6598)

    func test_cgnat_100_64_0_1_isPrivate() {
        // 100.64.0.1 is inside the RFC 6598 Shared Address Space (100.64.0.0/10).
        // Carrier-grade NAT and cloud-internal infrastructure use this range;
        // it must not be reachable from production network calls.
        // Sabotage: removing the 100.64/10 check from classifyIPv4 would return nil here.
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("100.64.0.1"), .privateHost)
    }

    func test_cgnat_100_127_255_255_isPrivate() {
        // Last address in the 100.64.0.0/10 block.
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("100.127.255.255"), .privateHost)
    }

    func test_cgnat_boundary_100_63_255_255_isNil() {
        // 100.63.x.x is just outside the block and must be allowed.
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("100.63.255.255"))
    }

    func test_cgnat_boundary_100_128_0_0_isNil() {
        // 100.128.x.x is just outside the block and must be allowed.
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("100.128.0.0"))
    }

    // MARK: - classifyIPLiteral: Link-Local

    func test_linkLocal_169_254_0_0_isLinkLocal() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("169.254.0.0"), .linkLocalHost)
    }

    func test_linkLocal_awsIMDS_isLinkLocal() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("169.254.169.254"), .linkLocalHost)
    }

    func test_linkLocal_169_254_255_255_isLinkLocal() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("169.254.255.255"), .linkLocalHost)
    }

    func test_adjacent_169_253_x_isNil() {
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("169.253.255.255"))
    }

    // MARK: - classifyIPLiteral: Loopback and Reserved

    func test_loopback_127_0_0_1_isMulticastReserved() {
        // 127.0.0.1 IS blocked as a resolved address. Callers apply isLocalhostURL first
        // for URL validation; DNS-resolved 127.0.0.1 from a remote domain is always an attack.
        // Sabotage: changing `if a == 127 { return .multicastReserved }` to allow 127.0.0.1
        // would cause this test to fail.
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("127.0.0.1"), .multicastReserved)
    }

    func test_loopback_127_0_0_2_isMulticastReserved() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("127.0.0.2"), .multicastReserved)
    }

    func test_zeroAddress_0_0_0_0_isMulticastReserved() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("0.0.0.0"), .multicastReserved)
    }

    func test_multicast_224_0_0_1_isMulticastReserved() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("224.0.0.1"), .multicastReserved)
    }

    func test_multicast_239_255_255_255_isMulticastReserved() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("239.255.255.255"), .multicastReserved)
    }

    func test_reserved_240_0_0_0_isMulticastReserved() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("240.0.0.0"), .multicastReserved)
    }

    func test_broadcast_255_255_255_255_isMulticastReserved() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("255.255.255.255"), .multicastReserved)
    }

    // MARK: - classifyIPLiteral: IPv6

    func test_ipv6_loopback_isMulticastReserved() {
        // ::1 resolved from DNS is an attack. isLocalhostURL handles the http://[::1] case.
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("::1"), .multicastReserved)
    }

    func test_ipv6_uniqueLocal_fd00_isBlocked() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("fd00::1"), .ipv6UniqueLocal)
    }

    func test_ipv6_uniqueLocal_fc00_isBlocked() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("fc00::1"), .ipv6UniqueLocal)
    }

    func test_ipv6_linkLocal_fe80_isBlocked() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("fe80::1"), .linkLocalHost)
    }

    func test_ipv6_linkLocal_withZoneID_isBlocked() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("fe80::1%en0"), .linkLocalHost)
    }

    func test_ipv6_mappedIPv4_192_168_isBlocked() {
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("::ffff:192.168.1.1"), .ipv4MappedLoopback)
    }

    func test_ipv6_publicAddress_2001_db8_isNil() {
        // 2001:db8::/32 is documentation range, but not explicitly blocked.
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("2001:db8::1"))
    }

    // MARK: - Trailing Dot Normalisation (FQDN bypass prevention)

    func test_trailingDot_privateIPv4_isBlocked() {
        // `192.168.1.1.` resolves identically to `192.168.1.1` — must not bypass.
        // Sabotage: removing the trailing-dot strip from classifyIPLiteral causes this to return nil.
        XCTAssertEqual(PrivateIPClassifier.classifyIPLiteral("192.168.1.1."), .privateHost)
    }

    func test_trailingDot_publicIP_isNil() {
        XCTAssertNil(PrivateIPClassifier.classifyIPLiteral("1.1.1.1."))
    }
}
