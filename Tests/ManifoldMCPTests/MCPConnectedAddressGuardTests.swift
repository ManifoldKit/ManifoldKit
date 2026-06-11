#if MCP
import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldInference

/// Gap C — DNS-rebinding TOCTOU.
///
/// `MCPSSRFPolicy.validateResolvedHostNotBlocked` resolves the hostname with its
/// own `getaddrinfo` query at check time. `URLSession.bytes(for:)` / `data(for:)`
/// re-resolve the hostname with a *separate* query at connect time. An attacker
/// controlling DNS returns a public IP to the guard's query (so the pre-flight
/// check passes) and a private IP to URLSession's query — reaching internal hosts.
///
/// These tests exercise the connect-time pin in `MCPRedirectCapDelegate`, which
/// inspects the address URLSession *actually* connected to
/// (`URLSessionTaskTransactionMetrics.remoteAddress`) and blocks it if private.
/// `URLSessionTaskMetrics` has no public initializer, so we drive the decision
/// point — `classifyConnectedAddress(_:for:)` — directly. That function is the
/// sole gate between an observed connected address and the
/// `MCPError.ssrfBlocked` the transport throws.
final class MCPConnectedAddressGuardTests: XCTestCase {

    // MARK: - The TOCTOU is closed: guard saw public, connection went private

    func test_connectionToPrivateAddress_isBlocked_evenWhenHostIsPublicName() {
        // Pre-flight resolved `mcp.example.com` to a public IP (the attacker's
        // first answer); URLSession then connected to 169.254.169.254 (cloud IMDS).
        // The connect-time pin must classify that as a block.
        let publicHostURL = URL(string: "https://mcp.example.com/mcp")!

        let blockedAddresses = [
            "169.254.169.254", // link-local / cloud IMDS
            "127.0.0.1",       // loopback
            "10.0.0.5",        // RFC1918
            "192.168.1.20",    // RFC1918
            "172.16.4.4",      // RFC1918
            "::1",             // IPv6 loopback
            "fd00::1",         // IPv6 unique-local
            "::ffff:127.0.0.1" // IPv4-mapped loopback
        ]

        for address in blockedAddresses {
            let category = MCPRedirectCapDelegate.classifyConnectedAddress(address, for: publicHostURL)
            XCTAssertNotNil(
                category,
                "Connection to \(address) for a public hostname must be blocked (DNS rebinding TOCTOU)"
            )
        }
    }

    // MARK: - Legitimate public connections still pass

    func test_connectionToPublicAddress_isAllowed() {
        let url = URL(string: "https://mcp.example.com/mcp")!
        // 93.184.216.34 is example.com's public IP — must not be blocked.
        XCTAssertNil(
            MCPRedirectCapDelegate.classifyConnectedAddress("93.184.216.34", for: url),
            "A public connected address must not be blocked"
        )
    }

    // MARK: - Explicit localhost servers bypass the pin

    func test_explicitLocalhostURL_bypassesConnectedAddressPin() {
        // An explicitly configured local MCP server (http://127.0.0.1) connecting
        // to 127.0.0.1 is legitimate — the pin must not block it. This mirrors the
        // isLocalhostURL bypass in MCPSSRFPolicy.
        let localhostURL = URL(string: "http://127.0.0.1:3000/mcp")!
        XCTAssertNil(
            MCPRedirectCapDelegate.classifyConnectedAddress("127.0.0.1", for: localhostURL),
            "Explicitly configured localhost server must bypass the connected-address pin"
        )

        let localhostNameURL = URL(string: "http://localhost:3000/mcp")!
        XCTAssertNil(
            MCPRedirectCapDelegate.classifyConnectedAddress("127.0.0.1", for: localhostNameURL),
            "localhost name must bypass the connected-address pin"
        )
    }

    // MARK: - Non-localhost host connecting to loopback is still an attack

    func test_publicHostConnectingToLoopback_isBlocked() {
        // A remote domain that connects to 127.0.0.1 is a rebinding attack even
        // though 127.0.0.1 is loopback — only an *explicitly configured* localhost
        // URL bypasses, not any connection that happens to land on loopback.
        let url = URL(string: "https://totally-legit.example.com/mcp")!
        XCTAssertNotNil(
            MCPRedirectCapDelegate.classifyConnectedAddress("127.0.0.1", for: url),
            "A public hostname connecting to loopback must be blocked (rebinding attack)"
        )
    }
}
#endif
