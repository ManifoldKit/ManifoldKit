import Foundation
import Security
import ManifoldInference

public struct MCPOAuthTokens: Sendable, Codable, Equatable {
    /// Raw bytes of the access token. Prefer this over `accessToken` to minimise
    /// the window in which the token lives as a heap `String`.
    public let accessTokenData: Data

    /// String form of the access token. Kept for Codable compatibility and callers
    /// that need the raw string (e.g. logging with redaction).
    @available(*, deprecated, message: "Use accessTokenData (Data) instead of accessToken (String); convert with String(data:encoding:) only at UI or protocol boundaries.")
    public var accessToken: String {
        String(data: accessTokenData, encoding: .utf8) ?? ""
    }

    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let tokenType: String
    public let issuer: URL
    public let subjectIdentifier: String?

    // Primary initialiser — takes raw bytes.
    public init(
        accessTokenData: Data,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        tokenType: String = "Bearer",
        issuer: URL,
        subjectIdentifier: String? = nil
    ) {
        self.accessTokenData = accessTokenData
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.tokenType = tokenType
        self.issuer = issuer
        self.subjectIdentifier = subjectIdentifier
    }

    // Convenience initialiser for tests and code that still holds a String.
    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        tokenType: String = "Bearer",
        issuer: URL,
        subjectIdentifier: String? = nil
    ) {
        self.init(
            accessTokenData: Data(accessToken.utf8),
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            tokenType: tokenType,
            issuer: issuer,
            subjectIdentifier: subjectIdentifier
        )
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case accessTokenData
        case refreshToken
        case expiresAt
        case scopes
        case tokenType
        case issuer
        case subjectIdentifier
    }
}

public struct MCPOAuthTokenStore: Sendable {
    public typealias Read = @Sendable (UUID) async throws -> MCPOAuthTokens?
    public typealias Write = @Sendable (MCPOAuthTokens, UUID) async throws -> Void
    public typealias Delete = @Sendable (UUID) async throws -> Void

    public let read: Read
    public let write: Write
    public let delete: Delete

    public init(read: @escaping Read, write: @escaping Write, delete: @escaping Delete) {
        self.read = read
        self.write = write
        self.delete = delete
    }

    public static var keychain: MCPOAuthTokenStore { keychain() }

    public static func inMemory() -> MCPOAuthTokenStore {
        actor Storage {
            var values: [UUID: MCPOAuthTokens] = [:]
            func read(_ id: UUID) -> MCPOAuthTokens? { values[id] }
            func write(_ tokens: MCPOAuthTokens, _ id: UUID) { values[id] = tokens }
            func delete(_ id: UUID) { values.removeValue(forKey: id) }
        }
        let storage = Storage()
        return .init(
            read: { id in await storage.read(id) },
            write: { tokens, id in await storage.write(tokens, id) },
            delete: { id in await storage.delete(id) }
        )
    }

    public static func custom(
        read: @escaping Read,
        write: @escaping Write,
        delete: @escaping Delete
    ) -> MCPOAuthTokenStore {
        .init(read: read, write: write, delete: delete)
    }

    public static func keychain(
        configuration: MCPKeychainConfiguration = .init(),
        serviceName: String = "\(ManifoldConfiguration.shared.bundleIdentifier).mcp.oauth.tokens",
        accountNamespace: String = "mcp.oauth.server"
    ) -> MCPOAuthTokenStore {
        let accessGroup = configuration.accessGroup
        let accessibility = configuration.accessibility as String

        return .init(
            read: { serverID in
                let accountName = keychainAccount(serverID: serverID, namespace: accountNamespace)
                var query = baseKeychainQuery(serviceName: serviceName, account: accountName, accessGroup: accessGroup)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne

                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound {
                    return nil
                }
                guard status == errSecSuccess else {
                    Log.inference.error(
                        "MCPOAuthTokenStore.keychain read failed: status=\(status, privacy: .public) account=\(accountName, privacy: .private)"
                    )
                    throw keychainFailure(action: "read", status: status)
                }
                guard let data = result as? Data else {
                    throw MCPError.authorizationFailed("Failed to decode OAuth tokens in Keychain: unexpected payload")
                }
                do {
                    return try JSONDecoder().decode(MCPOAuthTokens.self, from: data)
                } catch {
                    throw MCPError.authorizationFailed("Failed to decode OAuth tokens from Keychain data: \(error.localizedDescription)")
                }
            },
            write: { tokens, serverID in
                let accountName = keychainAccount(serverID: serverID, namespace: accountNamespace)
                let encoded: Data
                do {
                    encoded = try JSONEncoder().encode(tokens)
                } catch {
                    throw MCPError.authorizationFailed("Failed to encode OAuth tokens for persistence: \(error.localizedDescription)")
                }

                let updateQuery = baseKeychainQuery(serviceName: serviceName, account: accountName, accessGroup: accessGroup)
                let updateAttributes: [String: Any] = [
                    kSecValueData as String: encoded,
                    kSecAttrAccessible as String: accessibility,
                ]
                let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
                if updateStatus == errSecSuccess {
                    return
                }
                guard updateStatus == errSecItemNotFound else {
                    Log.inference.error(
                        "MCPOAuthTokenStore.keychain update failed: status=\(updateStatus, privacy: .public) account=\(accountName, privacy: .private)"
                    )
                    throw keychainFailure(action: "update", status: updateStatus)
                }

                var addQuery = baseKeychainQuery(serviceName: serviceName, account: accountName, accessGroup: accessGroup)
                addQuery[kSecValueData as String] = encoded
                addQuery[kSecAttrAccessible as String] = accessibility
                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    Log.inference.error(
                        "MCPOAuthTokenStore.keychain add failed: status=\(addStatus, privacy: .public) account=\(accountName, privacy: .private)"
                    )
                    throw keychainFailure(action: "write", status: addStatus)
                }
            },
            delete: { serverID in
                let accountName = keychainAccount(serverID: serverID, namespace: accountNamespace)
                let query = baseKeychainQuery(serviceName: serviceName, account: accountName, accessGroup: accessGroup)
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    Log.inference.error(
                        "MCPOAuthTokenStore.keychain delete failed: status=\(status, privacy: .public) account=\(accountName, privacy: .private)"
                    )
                    throw keychainFailure(action: "delete", status: status)
                }
            }
        )
    }

    private static func keychainAccount(serverID: UUID, namespace: String) -> String {
        "\(namespace).\(serverID.uuidString.lowercased())"
    }

    private static func baseKeychainQuery(
        serviceName: String,
        account: String,
        accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func keychainFailure(action: String, status: OSStatus) -> MCPError {
        let description: String
        if let message = SecCopyErrorMessageString(status, nil) {
            description = message as String
        } else {
            description = "OSStatus \(status)"
        }
        return .authorizationFailed("Failed to \(action) OAuth tokens in Keychain: \(description) (\(status))")
    }

    /// Extracts a stable account identifier from a raw token response.
    /// Checks `sub`, `bot_id`, and `workspace_id` in that order.
    public static func subjectIdentifier(from tokenResponse: [String: Any]) -> String? {
        if let sub = tokenResponse["sub"] as? String, !sub.isEmpty { return sub }
        if let botID = tokenResponse["bot_id"] as? String, !botID.isEmpty { return botID }
        if let wsID = tokenResponse["workspace_id"] as? String, !wsID.isEmpty { return wsID }
        return nil
    }
}
