import XCTest
@testable import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference

/// Tests for APIProvider enum and APIEndpoint model.
///
/// `test_keychainService_replacesApiKeyProperty` writes to the Keychain via
/// `APIEndpoint.setAPIKey(_:)`, which routes to `KeychainService.store`. Per
/// KeychainNamespaceIsolationAuditTest (#2416), that means this whole class
/// must scope `ManifoldConfiguration.shared` in `setUp` — a per-account
/// `endpointIDs` cleanup alone isn't enough isolation, since the write still
/// lands in the shared default namespace that any other default-configuration
/// bootstrap batched into the same `swift test --parallel` invocation can
/// sweep.
final class APIEndpointTests: XCTestCase {

    /// Track keychain accounts for cleanup.
    private var endpointIDs: [String] = []
    private var originalConfig: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        originalConfig = ManifoldConfiguration.shared
        var config = ManifoldConfiguration.shared
        config.bundleIdentifier = "com.manifoldkit.tests.apiendpoint.\(UUID().uuidString)"
        ManifoldConfiguration.shared = config
    }

    override func tearDown() {
        for id in endpointIDs {
            try? KeychainService.delete(account: id)
        }
        endpointIDs.removeAll()
        ManifoldConfiguration.shared = originalConfig
        originalConfig = nil
        super.tearDown()
    }

    private func makeEndpoint(
        provider: APIProvider,
        baseURL: String? = nil,
        modelName: String? = nil
    ) -> APIEndpoint {
        let endpoint = APIEndpoint(name: "Test", provider: provider, baseURL: baseURL, modelName: modelName)
        endpointIDs.append(endpoint.id.uuidString)
        return endpoint
    }

    // MARK: - APIProvider

    func test_init_setsDefaults() {
        let endpoint = makeEndpoint(provider: .openAI)
        XCTAssertEqual(endpoint.provider, .openAI)
        XCTAssertEqual(endpoint.baseURL, "https://api.openai.com")
        XCTAssertEqual(endpoint.modelName, "gpt-4o-mini")
        XCTAssertTrue(endpoint.isEnabled)
    }

    func test_provider_roundTrip() {
        let endpoint = makeEndpoint(provider: .claude)
        XCTAssertEqual(endpoint.provider, .claude)

        endpoint.provider = .ollama
        XCTAssertEqual(endpoint.provider, .ollama)
        // Raw values are stable opaque codes since v0.68 (Wave 2 A1), not display strings.
        XCTAssertEqual(endpoint.providerRawValue, "ollama")
    }

    func test_provider_allCases_haveDefaultURL() {
        for provider in APIProvider.allCases {
            XCTAssertFalse(provider.defaultBaseURL.isEmpty,
                           "\(provider) should have a non-empty default URL")
        }
    }

    func test_provider_requiresAPIKey() {
        XCTAssertTrue(APIProvider.openAI.requiresAPIKey)
        XCTAssertTrue(APIProvider.claude.requiresAPIKey)
        XCTAssertTrue(APIProvider.custom.requiresAPIKey)
        XCTAssertFalse(APIProvider.ollama.requiresAPIKey)
        XCTAssertFalse(APIProvider.lmStudio.requiresAPIKey)
    }

    // MARK: - isValid

    func test_isValid_validHTTPS() {
        let endpoint = makeEndpoint(provider: .openAI, baseURL: "https://api.openai.com")
        XCTAssertTrue(endpoint.isValid, "Valid HTTPS URL should pass structural validation")
    }

    func test_isValid_httpLocalhost_valid() {
        let endpoint = makeEndpoint(provider: .ollama, baseURL: "http://localhost:11434")
        // Ollama doesn't require API key
        XCTAssertTrue(endpoint.isValid,
                      "HTTP localhost should be valid (exempt from HTTPS requirement)")
    }

    func test_isValid_httpRemote_invalid() {
        let endpoint = makeEndpoint(provider: .ollama, baseURL: "http://example.com")
        XCTAssertFalse(endpoint.isValid,
                       "HTTP non-localhost should be invalid")
    }

    func test_isValid_structuralOnly_ignoresAPIKey() {
        let endpoint = makeEndpoint(provider: .openAI, baseURL: "https://api.openai.com")
        // isValid is now structural-only — no API key check
        XCTAssertTrue(endpoint.isValid,
                      "isValid should pass for valid URL regardless of API key presence")
    }

    func test_keychainService_replacesApiKeyProperty() throws {
        let endpoint = makeEndpoint(provider: .openAI, baseURL: "https://api.openai.com")
        XCTAssertNil(KeychainService.retrieve(account: endpoint.keychainAccount),
                     "No key stored yet")

        try endpoint.setAPIKey("sk-test-key")
        XCTAssertEqual(KeychainService.retrieve(account: endpoint.keychainAccount), "sk-test-key",
                       "KeychainService.retrieve should replace the old .apiKey property")
    }

    func test_requiresAPIKey_availableOnProvider() {
        XCTAssertTrue(APIProvider.openAI.requiresAPIKey,
                      "OpenAI provider should declare it requires an API key")
        XCTAssertFalse(APIProvider.ollama.requiresAPIKey,
                       "Ollama provider should not require an API key")
    }

    func test_isValid_ollamaNoKey_valid() {
        let endpoint = makeEndpoint(provider: .ollama, baseURL: "http://localhost:11434")
        XCTAssertTrue(endpoint.isValid,
                      "Ollama without API key should be valid")
    }
}
