import XCTest
@testable import ManifoldSecrets
import ManifoldInference

/// Integration tests for KeychainService using the REAL system Keychain.
///
/// These tests exercise actual SecItem operations against the macOS/iOS Keychain.
/// Each test uses a unique service name to avoid cross-test and cross-run conflicts.
/// May need to be skipped on CI environments without Keychain access.
final class KeychainIntegrationTests: XCTestCase {

    /// Unique service name scoped to this test run to avoid conflicts.
    private var testServiceName: String!

    /// Accounts created during the test, cleaned up in tearDown.
    private var createdAccounts: [String] = []

    /// Original configuration, restored in tearDown.
    private var originalConfig: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        originalConfig = ManifoldConfiguration.shared

        // Use a unique service name per test run to avoid Keychain collisions.
        testServiceName = "com.manifoldkit.tests.keychain.\(UUID().uuidString)"

        // Configure ManifoldKit to use our test service name.
        var config = ManifoldConfiguration.shared
        config.bundleIdentifier = testServiceName
        ManifoldConfiguration.shared = config
    }

    override func tearDown() {
        // Clean up all Keychain entries created during the test.
        for account in createdAccounts {
            try? KeychainService.delete(account: account)
        }
        createdAccounts.removeAll()

        // Restore original configuration.
        ManifoldConfiguration.shared = originalConfig
        originalConfig = nil
        testServiceName = nil
        super.tearDown()
    }

    private func uniqueAccount() -> String {
        let account = "test_\(UUID().uuidString)"
        createdAccounts.append(account)
        return account
    }

    // MARK: - Write → Read → Verify Round-Trip

    func test_writeReadVerify_roundTrip() throws {
        let account = uniqueAccount()
        let apiKey = "sk-test-abc123def456ghi789"

        try KeychainService.store(key: apiKey, account: account)

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertEqual(retrieved, apiKey, "Retrieved key should match stored key exactly")
    }

    // MARK: - Write → Delete → Read Returns Nil

    func test_writeDeleteRead_returnsNil() throws {
        let account = uniqueAccount()

        try KeychainService.store(key: "temporary-key", account: account)
        try KeychainService.delete(account: account)

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertNil(retrieved, "Key should be nil after deletion")
    }

    // MARK: - Overwrite Existing Key

    func test_overwriteExistingKey() throws {
        let account = uniqueAccount()

        try KeychainService.store(key: "original-value", account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), "original-value")

        try KeychainService.store(key: "updated-value", account: account)
        XCTAssertEqual(
            KeychainService.retrieve(account: account), "updated-value",
            "Second store should overwrite the first value"
        )
    }

    // MARK: - Read Non-Existent Key Returns Nil

    func test_readNonExistentKey_returnsNil() {
        let account = uniqueAccount()
        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertNil(retrieved, "Retrieving a never-stored key should return nil")
    }

    // MARK: - Store and Retrieve API Key-Like Strings

    func test_storeAndRetrieve_openAIStyleKey() throws {
        let account = uniqueAccount()
        let key = "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJ"

        try KeychainService.store(key: key, account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), key)
    }

    func test_storeAndRetrieve_anthropicStyleKey() throws {
        let account = uniqueAccount()
        let key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-AAAAAA"

        try KeychainService.store(key: key, account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), key)
    }

    func test_storeAndRetrieve_keyWithSpecialCharacters() throws {
        let account = uniqueAccount()
        let key = "key/with+special=chars&more%20stuff"

        try KeychainService.store(key: key, account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), key)
    }

    func test_storeAndRetrieve_emptyString() throws {
        let account = uniqueAccount()
        let key = ""

        try KeychainService.store(key: key, account: account)
        XCTAssertEqual(
            KeychainService.retrieve(account: account), key,
            "Empty string should round-trip through Keychain"
        )
    }

    // MARK: - Multiple Accounts Are Isolated

    func test_multipleAccounts_doNotInterfere() throws {
        let account1 = uniqueAccount()
        let account2 = uniqueAccount()
        let account3 = uniqueAccount()

        try KeychainService.store(key: "key-one", account: account1)
        try KeychainService.store(key: "key-two", account: account2)
        try KeychainService.store(key: "key-three", account: account3)

        XCTAssertEqual(KeychainService.retrieve(account: account1), "key-one")
        XCTAssertEqual(KeychainService.retrieve(account: account2), "key-two")
        XCTAssertEqual(KeychainService.retrieve(account: account3), "key-three")

        // Deleting one should not affect others.
        try KeychainService.delete(account: account2)
        XCTAssertEqual(KeychainService.retrieve(account: account1), "key-one")
        XCTAssertNil(KeychainService.retrieve(account: account2))
        XCTAssertEqual(KeychainService.retrieve(account: account3), "key-three")
    }
}
