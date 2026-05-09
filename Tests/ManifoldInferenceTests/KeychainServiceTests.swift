import XCTest
@testable import ManifoldInference

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
