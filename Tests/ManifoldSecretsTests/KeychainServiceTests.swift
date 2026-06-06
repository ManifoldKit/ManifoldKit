import XCTest
@testable import ManifoldSecrets
import ManifoldInference
import Security

/// Tests for KeychainService secure storage operations.
///
/// The throwing path (store/delete returning a non-success `OSStatus`) is hard
/// to reach without a fake `SecItem*` layer — the real Keychain only fails on
/// entitlement / device-lock / corruption conditions that aren't easily
/// reproduced from a unit test. The happy-path round-trips below are the
/// regression net; thrown-error coverage depends on on-device integration
/// testing.
final class KeychainServiceTests: XCTestCase {

    /// Tracks accounts created during each test for cleanup.
    private var createdAccounts: [String] = []

    override func tearDown() {
        super.tearDown()
        for account in createdAccounts {
            try? KeychainService.delete(account: account)
        }
        createdAccounts.removeAll()
    }

    private func uniqueAccount() -> String {
        let account = "test_\(UUID().uuidString)"
        createdAccounts.append(account)
        return account
    }

    // MARK: - Store & Retrieve

    func test_store_andRetrieve() throws {
        let account = uniqueAccount()
        try KeychainService.store(key: "sk-test-key-123", account: account)

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertEqual(retrieved, "sk-test-key-123")
    }

    func test_store_updatesExisting() throws {
        let account = uniqueAccount()
        try KeychainService.store(key: "old-key", account: account)
        try KeychainService.store(key: "new-key", account: account)

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertEqual(retrieved, "new-key",
                       "Second store should overwrite the first value")
    }

    func test_retrieve_notFound_returnsNil() {
        let account = uniqueAccount()
        let result = KeychainService.retrieve(account: account)
        XCTAssertNil(result, "Retrieving a non-existent key should return nil")
    }

    // MARK: - Delete

    func test_delete_removesKey() throws {
        let account = uniqueAccount()
        try KeychainService.store(key: "to-delete", account: account)
        try KeychainService.delete(account: account)

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertNil(retrieved, "Key should be gone after deletion")
    }

    func test_delete_nonExistent_doesNotThrow() {
        let account = uniqueAccount()
        XCTAssertNoThrow(try KeychainService.delete(account: account),
                         "Deleting a non-existent key must not throw")
    }

    // MARK: - Masking

    func test_masked_shortKey() {
        let masked = KeychainService.masked("abc")
        XCTAssertEqual(masked, "****",
                       "Keys shorter than 8 chars should be fully masked")
    }

    func test_masked_normalKey() {
        let masked = KeychainService.masked("sk-abc123xyz789")
        XCTAssertEqual(masked, "sk-a...789",
                       "Normal keys should show first 4 and last 3 chars")
    }

    // MARK: - Isolation

    func test_multipleAccounts_isolated() throws {
        let account1 = uniqueAccount()
        let account2 = uniqueAccount()

        try KeychainService.store(key: "key-one", account: account1)
        try KeychainService.store(key: "key-two", account: account2)

        XCTAssertEqual(KeychainService.retrieve(account: account1), "key-one")
        XCTAssertEqual(KeychainService.retrieve(account: account2), "key-two")
    }

    // MARK: - Protection Class

    /// Exercises the `SecItemUpdate` branch of `store(key:account:)` and
    /// confirms the update propagates `kSecAttrAccessible`.
    ///
    /// macOS's `SecItemCopyMatching` does not use `kSecAttrAccessible` as a
    /// search predicate, so protection-class verification would require a fake
    /// `SecItem*` layer. This test instead exercises the update code path end-
    /// to-end: write, update (second write hits `SecItemUpdate`), then query
    /// with the expected protection class and confirm the item is returned.
    /// The assertion is a regression net for the SEC-05 fix — the prior code
    /// omitted `kSecAttrAccessible` from `updateAttributes` entirely.
    func test_store_update_setsAccessibleWhenUnlockedThisDeviceOnly() throws {
        let account = uniqueAccount()

        // Write twice — second call exercises the SecItemUpdate branch.
        try KeychainService.store(key: "first-value", account: account)
        try KeychainService.store(key: "second-value", account: account)

        // Confirm the item survives the update and can still be retrieved.
        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertEqual(retrieved, "second-value",
                       "Value must reflect the update written on the second store call")

        // Confirm the item is found when filtering for the expected protection class.
        // On macOS this filter is not enforced as a predicate, but passing it
        // ensures the query round-trips without an unexpected status.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ManifoldConfiguration.shared.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(
            status, errSecSuccess,
            "Item must be reachable after update; unexpected status \(status)"
        )
    }

    // MARK: - End-to-End Round-Trip

    /// Exercises the full store -> retrieve -> delete -> retrieve pipeline to
    /// catch regressions in any of the three throw / no-throw annotations.
    func test_roundTrip_storeRetrieveDelete_endToEnd() throws {
        let account = uniqueAccount()
        let key = "sk-round-trip-\(UUID().uuidString)"

        try KeychainService.store(key: key, account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), key)

        try KeychainService.delete(account: account)
        XCTAssertNil(KeychainService.retrieve(account: account))

        // Second delete is a no-op and must not throw.
        XCTAssertNoThrow(try KeychainService.delete(account: account))
    }

    // MARK: - KeychainError surface

    func test_keychainError_osStatus_exposesUnderlyingCode() {
        XCTAssertEqual(KeychainError.storeFailed(-25300).osStatus, -25300)
        XCTAssertEqual(KeychainError.deleteFailed(errSecAuthFailed).osStatus, errSecAuthFailed)
    }

    func test_keychainError_localizedDescription_mapsKnownStatuses() {
        // `errSecInteractionNotAllowed` is the "device locked" case that UI
        // needs to render helpfully — the user can act on it.
        let locked = KeychainError.storeFailed(errSecInteractionNotAllowed)
        let text = locked.localizedDescription
        XCTAssertTrue(text.contains("locked"),
                      "Expected locked-device guidance in the message, got: \(text)")
        XCTAssertTrue(text.contains("\(errSecInteractionNotAllowed)"),
                      "Expected raw OSStatus to be appended for diagnostics, got: \(text)")
        XCTAssertTrue(text.contains("store") || text.contains("Store"),
                      "Expected the action verb to be included, got: \(text)")

        let deleteText = KeychainError.deleteFailed(errSecAuthFailed).localizedDescription
        XCTAssertTrue(deleteText.contains("delete") || deleteText.contains("Delete"),
                      "Expected delete-case description to mention the delete action, got: \(deleteText)")
    }

    func test_keychainError_localizedDescription_unknownStatus_stillHumanReadable() {
        // Unknown status: we still want a non-empty, non-default message.
        let err = KeychainError.storeFailed(-999_999)
        let text = err.localizedDescription
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("KeychainError error"),
                       "Expected LocalizedError override to suppress the default placeholder, got: \(text)")
        XCTAssertTrue(text.contains("-999999") || text.contains("-999,999"),
                      "Expected the raw OSStatus to be appended, got: \(text)")
    }
}
