import XCTest
@testable import ManifoldCloudCore
import ManifoldInference

/// H1 — credentialed requests to unpinned non-loopback hosts fail closed by default.
final class CredentialedHostTrustGateTests: XCTestCase {

    private var savedConfig: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        savedConfig = ManifoldConfiguration.shared
        PinnedSessionDelegate.loadDefaultPins()
    }

    override func tearDown() {
        ManifoldConfiguration.shared = savedConfig
        super.tearDown()
    }

    func test_unpinnedProductionHost_withCredentials_rejectedByDefault() {
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        let url = URL(string: "https://api.custom-llm.example/v1")!
        XCTAssertThrowsError(
            try CredentialedHostTrustGate.check(url: url, hasCredentials: true)
        ) { error in
            guard case CloudBackendError.unpinnedCredentialedHost(let host) = error else {
                return XCTFail("expected unpinnedCredentialedHost, got \(error)")
            }
            XCTAssertEqual(host, "api.custom-llm.example")
        }
    }

    func test_unpinnedHost_withoutCredentials_allowed() throws {
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        let url = URL(string: "https://api.custom-llm.example/v1")!
        try CredentialedHostTrustGate.check(url: url, hasCredentials: false)
    }

    func test_allowUnpinnedOptIn_permitsCredentialedUnpinnedHost() throws {
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: true)
        let url = URL(string: "https://api.custom-llm.example/v1")!
        try CredentialedHostTrustGate.check(url: url, hasCredentials: true)
    }

    func test_pinnedProductionHost_allowsCredentials() throws {
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        // Default pin set covers api.openai.com
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        try CredentialedHostTrustGate.check(url: url, hasCredentials: true)
    }

    func test_loopback_allowsCredentialsWithoutPins() throws {
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        for raw in ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"] {
            let url = URL(string: raw)!
            try CredentialedHostTrustGate.check(url: url, hasCredentials: true)
        }
    }

    func test_rfc6761TestHosts_exempt() throws {
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        let url = URL(string: "https://claude-\(UUID().uuidString).test/v1")!
        try CredentialedHostTrustGate.check(url: url, hasCredentials: true)
    }

    func test_specialUseHostClassifier() {
        XCTAssertTrue(CredentialedHostTrustGate.isTestOrLocalSpecialUseHost("localhost"))
        XCTAssertTrue(CredentialedHostTrustGate.isTestOrLocalSpecialUseHost("foo.localhost"))
        XCTAssertTrue(CredentialedHostTrustGate.isTestOrLocalSpecialUseHost("openai-abc.test"))
        XCTAssertTrue(CredentialedHostTrustGate.isTestOrLocalSpecialUseHost("test"))
        XCTAssertFalse(CredentialedHostTrustGate.isTestOrLocalSpecialUseHost("api.openai.com"))
        XCTAssertFalse(CredentialedHostTrustGate.isTestOrLocalSpecialUseHost("example.com"))
    }

    func test_loopbackFullRange_allowsCredentials() throws {
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        let url = URL(string: "http://127.0.0.2:8080")!
        try CredentialedHostTrustGate.check(url: url, hasCredentials: true)
    }

    /// Live-path sabotage check: `pinnedData` must invoke the gate. Uses a
    /// resolver stub so DNS pre-flight passes with a public IP and the gate
    /// is the first fail-closed check (no real network).
    func test_pinnedData_invokesCredentialedHostGate() async {
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        let previousResolver = DNSRebindingGuard._resolverForTesting
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] } // example.com public
        defer { DNSRebindingGuard._resolverForTesting = previousResolver }

        var request = URLRequest(url: URL(string: "https://api.custom-llm.example/v1")!)
        request.setValue("Bearer sk-test", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        do {
            _ = try await ConnectAddressPinningDelegate.pinnedData(for: request, on: session)
            XCTFail("expected unpinnedCredentialedHost before network")
        } catch let error as CloudBackendError {
            guard case .unpinnedCredentialedHost = error else {
                return XCTFail("expected unpinnedCredentialedHost, got \(error)")
            }
        } catch {
            XCTFail("expected CloudBackendError, got \(error)")
        }
    }
}
