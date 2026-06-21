import XCTest
import ManifoldSecrets
@testable import ManifoldUIModelManagement

/// Covers the edit-path Keychain rollback (`APIEndpointEditorView.rollbackKeychainKey`).
///
/// The edit path writes the new API key to the Keychain *before* updating the
/// record. If the record update throws, the just-written key would be orphaned
/// unless rolled back — the create path already cleans up, the edit path used to
/// silently leak. These tests pin the rollback contract:
///
/// - no prior key → the orphaned key is deleted, leaving nothing behind;
/// - a prior key existed → it is restored (the overwrite is undone), so editing
///   a key and then failing to save doesn't destroy the user's existing key.
///
/// Uses a real Keychain account (unique per test) — `KeychainService` works
/// under `swift test` on macOS (see `ManifoldSecretsTests`).
final class APIEndpointEditorKeychainRollbackTests: XCTestCase {

    private var account: String!

    override func setUp() {
        super.setUp()
        account = "manifoldkit.test.endpoint-rollback.\(UUID().uuidString)"
    }

    override func tearDown() {
        // Best-effort cleanup so a failed assertion never leaks a Keychain item.
        try? KeychainService.delete(account: account)
        account = nil
        super.tearDown()
    }

    /// No prior key: a failed update must delete the freshly written key,
    /// leaving the Keychain with no orphan.
    func testRollbackDeletesOrphanedKeyWhenNoPriorKey() throws {
        // Simulate the edit path having just written a new key with no prior one.
        try KeychainService.store(key: "sk-newly-written", account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), "sk-newly-written")

        APIEndpointEditorView.rollbackKeychainKey(account: account, priorKey: nil)

        XCTAssertNil(
            KeychainService.retrieve(account: account),
            "Orphaned key must be removed when there was no prior key to restore."
        )
    }

    /// Prior key existed: a failed update must restore it (undo the overwrite),
    /// so a failed edit never destroys the user's existing key.
    func testRollbackRestoresPriorKey() throws {
        // The user's existing key, then the edit overwrites it with a new one.
        try KeychainService.store(key: "sk-original", account: account)
        try KeychainService.store(key: "sk-overwritten", account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), "sk-overwritten")

        APIEndpointEditorView.rollbackKeychainKey(account: account, priorKey: "sk-original")

        XCTAssertEqual(
            KeychainService.retrieve(account: account),
            "sk-original",
            "A failed edit must restore the prior key rather than leaving the overwrite."
        )
    }

    /// An empty prior key is treated as "no prior key" — the orphan is deleted,
    /// not re-stored as an empty value.
    func testRollbackTreatsEmptyPriorKeyAsNoKey() throws {
        try KeychainService.store(key: "sk-newly-written", account: account)

        APIEndpointEditorView.rollbackKeychainKey(account: account, priorKey: "")

        XCTAssertNil(
            KeychainService.retrieve(account: account),
            "An empty prior key must be treated as no key — delete the orphan."
        )
    }
}
