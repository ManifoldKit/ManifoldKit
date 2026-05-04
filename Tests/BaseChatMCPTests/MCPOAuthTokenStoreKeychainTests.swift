#if MCP
import XCTest
import Security
@testable import BaseChatMCP

final class MCPOAuthTokenStoreKeychainTests: XCTestCase {
    private struct CleanupItem {
        let serviceName: String
        let account: String
    }

    private var cleanupItems: [CleanupItem] = []

    override func tearDown() {
        super.tearDown()
        for item in cleanupItems {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.serviceName,
                kSecAttrAccount as String: item.account,
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
        cleanupItems.removeAll()
    }

    func test_keychain_roundTrip_writeReadDelete() async throws {
        let serviceName = "BaseChatKit.tests.mcp.oauth.\(UUID().uuidString)"
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
        let serviceName = "BaseChatKit.tests.mcp.oauth.\(UUID().uuidString)"
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
        let serviceName = "BaseChatKit.tests.mcp.oauth.\(UUID().uuidString)"
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
#endif
