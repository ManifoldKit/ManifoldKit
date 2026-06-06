import XCTest
@testable import ManifoldSecrets
import ManifoldInference

/// Tests for the boot-time Keychain reaper (`allAccounts` and `sweep`).
///
/// Each test uses a unique service name so parallel test runs cannot collide
/// on the shared framework namespace. See `KeychainIntegrationTests` for the
/// pattern this builds on.
final class KeychainServiceSweepTests: XCTestCase {

    private var testServiceName: String!
    private var originalConfig: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        originalConfig = ManifoldConfiguration.shared

        testServiceName = "com.manifoldkit.tests.reaper.\(UUID().uuidString)"
        var config = ManifoldConfiguration.shared
        config.bundleIdentifier = testServiceName
        ManifoldConfiguration.shared = config
    }

    override func tearDown() {
        // Belt-and-braces: sweep the namespace clean before releasing it.
        // `sweep` swallows individual delete failures, so a leftover item
        // can't trip tearDown.
        _ = KeychainService.sweep(validAccounts: [])

        ManifoldConfiguration.shared = originalConfig
        originalConfig = nil
        testServiceName = nil
        super.tearDown()
    }

    // MARK: - allAccounts

    func test_allAccounts_emptyNamespace_returnsEmpty() {
        XCTAssertEqual(KeychainService.allAccounts(), [])
    }

    func test_allAccounts_returnsStoredAccounts() throws {
        let a = UUID().uuidString
        let b = UUID().uuidString
        let c = UUID().uuidString

        try KeychainService.store(key: "k1", account: a)
        try KeychainService.store(key: "k2", account: b)
        try KeychainService.store(key: "k3", account: c)

        let accounts = Set(KeychainService.allAccounts())
        XCTAssertEqual(accounts, [a, b, c])
    }

    // MARK: - sweep

    func test_sweep_emptyNamespace_returnsZero() {
        let reaped = KeychainService.sweep(validAccounts: [])
        XCTAssertEqual(reaped, 0)
    }

    func test_sweep_emptyValidSet_removesEverything() throws {
        let a = UUID().uuidString
        let b = UUID().uuidString
        try KeychainService.store(key: "k1", account: a)
        try KeychainService.store(key: "k2", account: b)

        let reaped = KeychainService.sweep(validAccounts: [])

        XCTAssertEqual(reaped, 2)
        XCTAssertEqual(KeychainService.allAccounts(), [])
        XCTAssertNil(KeychainService.retrieve(account: a))
        XCTAssertNil(KeychainService.retrieve(account: b))
    }

    func test_sweep_preservesValidAccountsAndRemovesOrphans() throws {
        let keep1 = UUID().uuidString
        let keep2 = UUID().uuidString
        let orphan1 = UUID().uuidString
        let orphan2 = UUID().uuidString

        try KeychainService.store(key: "valid1", account: keep1)
        try KeychainService.store(key: "valid2", account: keep2)
        try KeychainService.store(key: "orphan1", account: orphan1)
        try KeychainService.store(key: "orphan2", account: orphan2)

        let reaped = KeychainService.sweep(validAccounts: [keep1, keep2])

        XCTAssertEqual(reaped, 2, "Only the two orphans should be reaped")

        XCTAssertEqual(KeychainService.retrieve(account: keep1), "valid1")
        XCTAssertEqual(KeychainService.retrieve(account: keep2), "valid2")
        XCTAssertNil(KeychainService.retrieve(account: orphan1))
        XCTAssertNil(KeychainService.retrieve(account: orphan2))
    }

    func test_sweep_allAccountsValid_returnsZero() throws {
        let a = UUID().uuidString
        let b = UUID().uuidString
        try KeychainService.store(key: "k1", account: a)
        try KeychainService.store(key: "k2", account: b)

        let reaped = KeychainService.sweep(validAccounts: [a, b])

        XCTAssertEqual(reaped, 0)
        XCTAssertEqual(Set(KeychainService.allAccounts()), [a, b])
    }

    func test_sweep_validSetContainsUnknownAccount_isIgnored() throws {
        let real = UUID().uuidString
        let notStored = UUID().uuidString
        try KeychainService.store(key: "real", account: real)

        // validAccounts may contain accounts that were never in the Keychain
        // (e.g. an endpoint row without a stored key). Sweep should ignore them.
        let reaped = KeychainService.sweep(validAccounts: [real, notStored])

        XCTAssertEqual(reaped, 0)
        XCTAssertEqual(KeychainService.retrieve(account: real), "real")
    }
}
