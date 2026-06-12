import XCTest
@testable import ManifoldCloudCore
import ManifoldInference

/// Connect-time DNS-rebinding TOCTOU — cloud transport stack.
///
/// `DNSRebindingGuard.validate(url:)` resolves the endpoint hostname with its own
/// `getaddrinfo` query *before* the request and fails closed on a private address.
/// But `URLSession.bytes(for:)` / `data(for:)` re-resolve the hostname with a
/// *separate* query at connect time. An attacker controlling DNS returns a public
/// IP to the guard's pre-flight query (so the check passes) and a private IP to
/// URLSession's query — reaching internal hosts despite the pre-flight check.
///
/// These tests exercise the connect-time pin in ``ConnectAddressPinningDelegate``,
/// which inspects the address URLSession *actually* connected to
/// (`URLSessionTaskTransactionMetrics.remoteAddress`) and blocks it if private.
/// `URLSessionTaskMetrics` has no public initializer, so we drive the decision
/// point — `classifyConnectedAddress(_:for:)` — directly. That function is the
/// sole gate between an observed connected address and the
/// `CloudBackendError.blockedAddress` the transport throws.
///
/// This is the cloud-side sibling of `MCPConnectedAddressGuardTests` (PR #1748).
final class ConnectAddressPinningDelegateTests: XCTestCase {

    // MARK: - The TOCTOU is closed: guard saw public, connection went private

    func test_connectionToPrivateAddress_isBlocked_evenWhenHostIsPublicName() {
        // Pre-flight resolved `api.example.com` to a public IP (the attacker's
        // first answer); URLSession then connected to a private/reserved address.
        // The connect-time pin must classify that as a block.
        let publicHostURL = URL(string: "https://api.example.com/v1/chat/completions")!

        let blockedAddresses = [
            "169.254.169.254",  // link-local / cloud IMDS
            "127.0.0.1",        // loopback
            "10.0.0.5",         // RFC1918
            "192.168.1.20",     // RFC1918
            "172.16.4.4",       // RFC1918
            "100.64.0.1",       // carrier-grade NAT / cloud-internal
            "::1",              // IPv6 loopback
            "fd00::1",          // IPv6 unique-local
            "fe80::1",          // IPv6 link-local
            "::ffff:127.0.0.1", // IPv4-mapped loopback
            "64:ff9b::a00:5"    // NAT64-embedded RFC1918
        ]

        for address in blockedAddresses {
            let category = ConnectAddressPinningDelegate.classifyConnectedAddress(address, for: publicHostURL)
            XCTAssertNotNil(
                category,
                "Connection to \(address) for a public hostname must be blocked (DNS rebinding TOCTOU)"
            )
        }
    }

    // MARK: - Legitimate public connections still pass

    func test_connectionToPublicAddress_isAllowed() {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        // 93.184.216.34 is example.com's public IP — must not be blocked.
        XCTAssertNil(
            ConnectAddressPinningDelegate.classifyConnectedAddress("93.184.216.34", for: url),
            "A public connected address must not be blocked"
        )
    }

    // MARK: - Explicit localhost servers bypass the pin (Ollama, LM Studio)

    func test_explicitLocalhostURL_bypassesConnectedAddressPin() {
        // An explicitly configured local server (http://127.0.0.1 — e.g. Ollama)
        // connecting to 127.0.0.1 is legitimate — the pin must not block it. This
        // mirrors the isLocalhostURL bypass in DNSRebindingGuard.
        let localhostURL = URL(string: "http://127.0.0.1:11434/api/tags")!
        XCTAssertNil(
            ConnectAddressPinningDelegate.classifyConnectedAddress("127.0.0.1", for: localhostURL),
            "Explicitly configured localhost server must bypass the connected-address pin"
        )

        let localhostNameURL = URL(string: "http://localhost:11434/api/tags")!
        XCTAssertNil(
            ConnectAddressPinningDelegate.classifyConnectedAddress("127.0.0.1", for: localhostNameURL),
            "localhost name must bypass the connected-address pin"
        )

        let ipv6LoopbackURL = URL(string: "http://[::1]:11434/api/tags")!
        XCTAssertNil(
            ConnectAddressPinningDelegate.classifyConnectedAddress("::1", for: ipv6LoopbackURL),
            "Explicitly configured ::1 server must bypass the connected-address pin"
        )
    }

    // MARK: - Non-localhost host connecting to loopback is still an attack

    func test_publicHostConnectingToLoopback_isBlocked() {
        // A remote domain that connects to 127.0.0.1 is a rebinding attack even
        // though 127.0.0.1 is loopback — only an *explicitly configured* localhost
        // URL bypasses, not any connection that happens to land on loopback.
        let url = URL(string: "https://totally-legit.example.com/v1/chat/completions")!
        XCTAssertNotNil(
            ConnectAddressPinningDelegate.classifyConnectedAddress("127.0.0.1", for: url),
            "A public hostname connecting to loopback must be blocked (rebinding attack)"
        )
    }

    // MARK: - IPv6 zone identifier on the connected address is handled

    func test_connectedAddressWithIPv6ZoneID_isClassified() {
        // remoteAddress can carry a zone identifier (fe80::1%en0). PrivateIPClassifier
        // strips the zone, so a zoned link-local address must still classify as blocked.
        let url = URL(string: "https://api.example.com/v1/chat/completions")!
        XCTAssertNotNil(
            ConnectAddressPinningDelegate.classifyConnectedAddress("fe80::1%en0", for: url),
            "A zoned IPv6 link-local connected address must be blocked"
        )
    }
}
