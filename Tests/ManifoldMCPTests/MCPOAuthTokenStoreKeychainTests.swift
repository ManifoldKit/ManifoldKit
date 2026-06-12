import XCTest
import Security
@testable import ManifoldMCP

final class MCPOAuthTokenStoreKeychainTests: XCTestCase {
    private struct CleanupItem {
        let serviceName: String
        let account: String
    }

    private var cleanupItems: [CleanupItem] = []

    override func tearDown() {
        super.tearDown()
        for item in cleanupItems {
            for account in [item.account, "\(item.account).refresh"] {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: item.serviceName,
                    kSecAttrAccount as String: account,
                ]
                _ = SecItemDelete(query as CFDictionary)
            }
        }
        cleanupItems.removeAll()
    }

    private func itemExists(serviceName: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Verifies an item is reachable when queried with a specific
    /// `kSecAttrAccessible` filter. On macOS, `SecItemCopyMatching` does not
    /// enforce `kSecAttrAccessible` as a predicate (documented in
    /// `KeychainServiceTests` line 106), so on the macOS test lane this is a
    /// smoke check that the query round-trips. On iOS, the predicate is
    /// applied and the success confirms the item was written with the
    /// expected accessibility class.
    private func itemExists(serviceName: String, account: String, accessibility: CFString) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: accessibility,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func test_keychain_roundTrip_writeReadDelete() async throws {
        let serviceName = "ManifoldKit.tests.mcp.oauth.\(UUID().uuidString)"
        let namespace = "auth-worker.\(UUID().uuidString)"
        let serverID = UUID()
        trackCleanup(serviceName: serviceName, namespace: namespace, serverID: serverID)

        let store = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespace)
        let expected = makeTokens(accessToken: "persisted-token")

        try await store.write(expected, serverID)
        let readBack = try await store.read(serverID)
        XCTAssertEqual(readBack, expected)

        try await store.delete(serverID)
        let afterDelete = try await store.read(serverID)
        XCTAssertNil(afterDelete)
    }

    func test_keychain_accountNamespace_isolatesServerEntries() async throws {
        let serviceName = "ManifoldKit.tests.mcp.oauth.\(UUID().uuidString)"
        let serverID = UUID()
        let namespaceA = "auth-worker.a.\(UUID().uuidString)"
        let namespaceB = "auth-worker.b.\(UUID().uuidString)"
        trackCleanup(serviceName: serviceName, namespace: namespaceA, serverID: serverID)
        trackCleanup(serviceName: serviceName, namespace: namespaceB, serverID: serverID)

        let storeA = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespaceA)
        let storeB = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespaceB)

        try await storeA.write(makeTokens(accessToken: "namespace-a-token"), serverID)
        try await storeB.write(makeTokens(accessToken: "namespace-b-token"), serverID)

        let readA = try await storeA.read(serverID)
        let readB = try await storeB.read(serverID)
        XCTAssertEqual(String(data: readA?.accessTokenData ?? Data(), encoding: .utf8), "namespace-a-token")
        XCTAssertEqual(String(data: readB?.accessTokenData ?? Data(), encoding: .utf8), "namespace-b-token")
    }

    func test_keychain_read_surfacesDecodingFailures() async {
        let serviceName = "ManifoldKit.tests.mcp.oauth.\(UUID().uuidString)"
        let namespace = "auth-worker.\(UUID().uuidString)"
        let serverID = UUID()
        trackCleanup(serviceName: serviceName, namespace: namespace, serverID: serverID)
        let account = "\(namespace).\(serverID.uuidString.lowercased())"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("not-json".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        _ = SecItemDelete(query as CFDictionary)
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)

        let store = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespace)

        do {
            _ = try await store.read(serverID)
            XCTFail("Expected Keychain read to fail on corrupted token payload")
        } catch let error as MCPError {
            guard case let .authorizationFailed(message) = error else {
                return XCTFail("Expected authorizationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("decode"), "Expected decode failure message, got: \(message)")
        } catch {
            XCTFail("Expected MCPError, got \(error)")
        }
    }

    private func trackCleanup(serviceName: String, namespace: String, serverID: UUID) {
        cleanupItems.append(
            .init(
                serviceName: serviceName,
                account: "\(namespace).\(serverID.uuidString.lowercased())"
            )
        )
    }

    // MARK: - SEC-26: refresh-token split

    func test_keychain_writesSplitItems_withDistinctAccessibilityClasses() async throws {
        let serviceName = "ManifoldKit.tests.mcp.oauth.\(UUID().uuidString)"
        let namespace = "auth-worker.\(UUID().uuidString)"
        let serverID = UUID()
        trackCleanup(serviceName: serviceName, namespace: namespace, serverID: serverID)
        let accessAccount = "\(namespace).\(serverID.uuidString.lowercased())"
        let refreshAccount = "\(accessAccount).refresh"

        let store = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespace)
        try await store.write(makeTokens(accessToken: "ac-split"), serverID)

        XCTAssertTrue(itemExists(serviceName: serviceName, account: accessAccount), "Access item must be present")
        XCTAssertTrue(itemExists(serviceName: serviceName, account: refreshAccount), "Refresh item must be present")

        // Filter-based accessibility-class smoke check. See helper docs for the macOS
        // caveat: the kSecAttrAccessible predicate is not enforced by the macOS legacy
        // keychain, so on the macOS lane this just confirms the query round-trips
        // without an unexpected status. On iOS the predicate IS enforced and these
        // assertions are real regression nets for the SEC-26 split.
        XCTAssertTrue(
            itemExists(serviceName: serviceName, account: accessAccount, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
            "Access token must be reachable under AfterFirstUnlockThisDeviceOnly (background refresh)"
        )
        XCTAssertTrue(
            itemExists(serviceName: serviceName, account: refreshAccount, accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly),
            "Refresh token must be reachable under stricter WhenUnlockedThisDeviceOnly"
        )
        // Negative cross-check: refresh item must NOT be reachable under the looser class.
        // On iOS this proves the split; on macOS the predicate is ignored so the assertion
        // is informational rather than enforced.
        #if os(iOS)
        XCTAssertFalse(
            itemExists(serviceName: serviceName, account: refreshAccount, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
            "Refresh item must NOT be filed under the looser AfterFirstUnlock class"
        )
        #endif
    }

    func test_keychain_omitsRefreshItem_whenRefreshTokenNil() async throws {
        let serviceName = "ManifoldKit.tests.mcp.oauth.\(UUID().uuidString)"
        let namespace = "auth-worker.\(UUID().uuidString)"
        let serverID = UUID()
        trackCleanup(serviceName: serviceName, namespace: namespace, serverID: serverID)
        let accessAccount = "\(namespace).\(serverID.uuidString.lowercased())"
        let refreshAccount = "\(accessAccount).refresh"

        let store = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespace)
        let tokens = MCPOAuthTokens(
            accessToken: "access-only",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 99),
            scopes: ["tools:read"],
            issuer: URL(string: "https://issuer.example.com")!
        )
        try await store.write(tokens, serverID)

        XCTAssertTrue(itemExists(serviceName: serviceName, account: accessAccount))
        XCTAssertFalse(itemExists(serviceName: serviceName, account: refreshAccount),
                       "Refresh item must not be written when refreshToken is nil")

        let readBack = try await store.read(serverID)
        XCTAssertNil(readBack?.refreshToken)
        XCTAssertEqual(String(data: readBack?.accessTokenData ?? Data(), encoding: .utf8), "access-only")
    }

    func test_keychain_loadReassemblesBothTokens() async throws {
        let serviceName = "ManifoldKit.tests.mcp.oauth.\(UUID().uuidString)"
        let namespace = "auth-worker.\(UUID().uuidString)"
        let serverID = UUID()
        trackCleanup(serviceName: serviceName, namespace: namespace, serverID: serverID)

        let store = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespace)
        let expected = makeTokens(accessToken: "reassemble-token")
        try await store.write(expected, serverID)

        let readBack = try await store.read(serverID)
        XCTAssertEqual(readBack, expected)
        XCTAssertEqual(readBack?.refreshToken, "refresh-reassemble-token")
    }

    func test_keychain_deleteRemovesBothItems() async throws {
        let serviceName = "ManifoldKit.tests.mcp.oauth.\(UUID().uuidString)"
        let namespace = "auth-worker.\(UUID().uuidString)"
        let serverID = UUID()
        trackCleanup(serviceName: serviceName, namespace: namespace, serverID: serverID)
        let accessAccount = "\(namespace).\(serverID.uuidString.lowercased())"
        let refreshAccount = "\(accessAccount).refresh"

        let store = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespace)
        try await store.write(makeTokens(accessToken: "to-be-deleted"), serverID)
        XCTAssertTrue(itemExists(serviceName: serviceName, account: accessAccount))
        XCTAssertTrue(itemExists(serviceName: serviceName, account: refreshAccount))

        try await store.delete(serverID)
        XCTAssertFalse(itemExists(serviceName: serviceName, account: accessAccount))
        XCTAssertFalse(itemExists(serviceName: serviceName, account: refreshAccount))

        let afterDelete = try await store.read(serverID)
        XCTAssertNil(afterDelete)
    }

    func test_keychain_overwritingWithNilRefresh_purgesPriorRefreshItem() async throws {
        let serviceName = "ManifoldKit.tests.mcp.oauth.\(UUID().uuidString)"
        let namespace = "auth-worker.\(UUID().uuidString)"
        let serverID = UUID()
        trackCleanup(serviceName: serviceName, namespace: namespace, serverID: serverID)
        let accessAccount = "\(namespace).\(serverID.uuidString.lowercased())"
        let refreshAccount = "\(accessAccount).refresh"

        let store = MCPOAuthTokenStore.keychain(serviceName: serviceName, accountNamespace: namespace)
        try await store.write(makeTokens(accessToken: "with-refresh"), serverID)
        XCTAssertTrue(itemExists(serviceName: serviceName, account: refreshAccount))

        let withoutRefresh = MCPOAuthTokens(
            accessToken: "no-refresh-now",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 100),
            scopes: ["tools:read"],
            issuer: URL(string: "https://issuer.example.com")!
        )
        try await store.write(withoutRefresh, serverID)

        XCTAssertTrue(itemExists(serviceName: serviceName, account: accessAccount))
        XCTAssertFalse(itemExists(serviceName: serviceName, account: refreshAccount),
                       "Re-writing with nil refresh must purge prior refresh item to avoid stale value")
    }

    private func makeTokens(accessToken: String) -> MCPOAuthTokens {
        .init(
            accessToken: accessToken,
            refreshToken: "refresh-\(accessToken)",
            expiresAt: Date(timeIntervalSince1970: 123_456),
            scopes: ["tools:read"],
            tokenType: "Bearer",
            issuer: URL(string: "https://issuer.example.com")!,
            subjectIdentifier: "subject-\(accessToken)"
        )
    }
}
