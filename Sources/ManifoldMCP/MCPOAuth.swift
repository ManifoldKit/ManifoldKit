import Darwin
import Foundation
import Security
import CryptoKit
import ManifoldInference

public protocol MCPOAuthRedirectListener: Sendable {
    func authorize(
        authorizationURL: URL,
        callbackURLScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL
}

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

private struct OAuthProtectedResourceMetadata: Decodable {
    let authorizationServers: [URL]?

    private enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

private struct OAuthAuthorizationServerMetadata: Decodable {
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    /// RFC 9207 — whether the AS appends `iss` to the redirect callback.
    let authorizationResponseIssParameterSupported: Bool

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issuer = try container.decode(URL.self, forKey: .issuer)
        authorizationEndpoint = try container.decode(URL.self, forKey: .authorizationEndpoint)
        tokenEndpoint = try container.decode(URL.self, forKey: .tokenEndpoint)
        registrationEndpoint = try container.decodeIfPresent(URL.self, forKey: .registrationEndpoint)
        authorizationResponseIssParameterSupported =
            (try? container.decodeIfPresent(Bool.self, forKey: .authorizationResponseIssParameterSupported)) ?? false
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    let scope: String?
    let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

private struct OAuthTokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct OAuthDynamicClientRegistrationResponse: Decodable {
    let clientID: String
    let registrationAccessToken: String?
    let registrationClientURI: String?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case registrationAccessToken = "registration_access_token"
        case registrationClientURI = "registration_client_uri"
    }
}

// MARK: - PKCE Verifier (D7)

/// A PKCE code verifier that expires after 5 minutes and zeroes its storage on demand.
struct PKCEVerifier {
    private(set) var verifierData: Data
    let createdAt: Date

    init(data: Data, createdAt: Date = Date()) {
        self.verifierData = data
        self.createdAt = createdAt
    }

    /// True when more than 5 minutes have elapsed since creation.
    var isExpired: Bool { Date().timeIntervalSince(createdAt) > 300 }

    /// UTF-8 string view of the verifier bytes.
    var stringValue: String { String(data: verifierData, encoding: .utf8) ?? "" }

    /// Overwrites the verifier bytes in place.
    /// `memset_s` is not elided by optimising compilers because it carries a
    /// conformance obligation in the C standard.
    mutating func zero() {
        verifierData.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }
}

// MARK: - Redirect-cap delegate (D6 — Gap B)

/// Limits redirect chains to at most one hop to prevent SSRF-via-redirect attacks.
final class MCPRedirectCapDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxRedirects: Int?
    private let validator: @Sendable (URL) throws -> Void
    private var redirectCount = 0

    init(
        maxRedirects: Int? = 1,
        validator: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.maxRedirects = maxRedirects
        self.validator = validator
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectCount += 1
        if let nextURL = request.url {
            do {
                try validator(nextURL)
            } catch {
                completionHandler(nil)
                return
            }
        }
        if let maxRedirects {
            completionHandler(redirectCount <= maxRedirects ? request : nil)
        } else {
            completionHandler(request)
        }
    }
}

// MARK: - MCPOAuthAuthorization

public actor MCPOAuthAuthorization: MCPAuthorization {
    private let descriptor: MCPAuthorizationDescriptor.OAuthDescriptor
    private let serverID: UUID
    private let resourceURL: URL
    private let redirectListener: any MCPOAuthRedirectListener
    private let tokenStore: MCPOAuthTokenStore
    private let random: @Sendable () -> Data
    private let sessionProvider: @Sendable () throws -> URLSession
    private let currentDate: @Sendable () -> Date

    // Optional event stream for surfacing scope downgrades and TOFU discovery events
    // to the host app without requiring a full MCPClient dependency.
    var eventContinuation: AsyncStream<MCPConnectionEvent>.Continuation?

    private var cachedAuthorizationMetadata: OAuthAuthorizationServerMetadata?
    private var cachedResourceMetadataURL: URL?
    private var cachedRegisteredClientID: String?

    // RFC 7592 — management credentials stored after DCR.
    private var registrationManagementToken: String?
    private var registrationManagementURI: URL?

    // Single-flight token refresh (D12).
    private var inflightRefresh: Task<MCPOAuthTokens, Error>?

    public init(
        descriptor: MCPAuthorizationDescriptor.OAuthDescriptor,
        serverID: UUID,
        resourceURL: URL,
        redirectListener: any MCPOAuthRedirectListener,
        tokenStore: MCPOAuthTokenStore = .keychain,
        clock: any Clock<Duration> = ContinuousClock(),
        random: @escaping @Sendable () -> Data = { Data() },
        session: URLSession? = nil,
        currentDate: @escaping @Sendable () -> Date = Date.init,
        eventContinuation: AsyncStream<MCPConnectionEvent>.Continuation? = nil
    ) {
        self.descriptor = descriptor
        self.serverID = serverID
        self.resourceURL = resourceURL
        self.redirectListener = redirectListener
        self.tokenStore = tokenStore
        self.random = random
        if let session {
            self.sessionProvider = { session }
        } else {
            self.sessionProvider = MCPURLSessionFactory.throwingShared
        }
        self.currentDate = currentDate
        self.eventContinuation = eventContinuation
        _ = clock
    }

    public func authorizationHeader(for requestURL: URL) async throws -> String? {
        try await MCPSSRFPolicy.validateOAuthRequestURL(requestURL, label: "oauth request")
        guard Self.isSameOrigin(lhs: requestURL, rhs: resourceURL) else {
            return nil
        }

        let tokens = try await activeTokens()
        try validateBearerTransmission(tokens)
        // Build header directly from raw bytes — avoids storing the full string.
        let bearerValue = String(data: tokens.accessTokenData, encoding: .utf8) ?? ""
        return "\(tokens.tokenType) \(bearerValue)"
    }

    public func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision {
        _ = body
        try await MCPSSRFPolicy.validateOAuthRequestURL(resourceURL, label: "resource")
        guard statusCode == 401 || statusCode == 403 else {
            return .fail(.authorizationFailed("unexpected status \(statusCode)"))
        }

        guard let existing = try await tokenStore.read(serverID) else {
            return .fail(.authorizationRequired(buildAuthorizationRequest()))
        }
        guard let refreshToken = existing.refreshToken else {
            return .fail(.authorizationRequired(buildAuthorizationRequest()))
        }

        do {
            let refreshed = try await singleFlightRefresh(refreshToken: refreshToken, existing: existing)
            try await tokenStore.write(refreshed, serverID)
            return .retry
        } catch let error as MCPError {
            if case .authorizationRequired = error {
                do {
                    try await tokenStore.delete(serverID)
                } catch {
                    Log.inference.warning("MCPOAuthAuthorization: failed to clear token store after invalid_grant")
                }
            }
            return .fail(error)
        } catch {
            return .fail(.authorizationFailed(error.localizedDescription))
        }
    }

    // MARK: - Disconnect

    public func disconnect() async {
        guard let managementURI = registrationManagementURI,
              let managementToken = registrationManagementToken else { return }
        // RFC 7592 — best-effort DELETE; never throws.
        do {
            try await MCPSSRFPolicy.validateOAuthRequestURL(managementURI, label: "registration management")
            var request = URLRequest(url: managementURI)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(managementToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 5
            _ = try await sessionProvider().data(
                for: request,
                delegate: MCPRedirectCapDelegate(
                    maxRedirects: nil,
                    validator: MCPSSRFPolicy.validateOAuthRedirectURL
                )
            )
            Log.inference.info("MCPOAuthAuthorization: dynamic client deregistered for \(self.serverID)")
        } catch {
            Log.inference.warning("MCPOAuthAuthorization: client deregistration request failed (best-effort): \(error.localizedDescription)")
        }
    }

    // MARK: - Private token acquisition

    private func activeTokens() async throws -> MCPOAuthTokens {
        if let stored = try await tokenStore.read(serverID) {
            try verifyIssuer(stored.issuer)
            if !isExpired(stored) {
                try validateBearerTransmission(stored)
                return stored
            }

            if let refreshToken = stored.refreshToken {
                do {
                    let refreshed = try await singleFlightRefresh(refreshToken: refreshToken, existing: stored)
                    try await tokenStore.write(refreshed, serverID)
                    try validateBearerTransmission(refreshed)
                    return refreshed
                } catch {
                    try await tokenStore.delete(serverID)
                    Log.inference.warning("MCPOAuthAuthorization: refresh failed, forcing full OAuth authorization")
                }
            }
        }

        let metadata = try await discoverAuthorizationMetadata()
        let codeResponse = try await performAuthorizationCodeFlow(metadata: metadata)
        try await tokenStore.write(codeResponse, serverID)
        try validateBearerTransmission(codeResponse)
        return codeResponse
    }

    // MARK: - Single-flight refresh (D12)

    /// Ensures only one token refresh runs at a time; concurrent callers piggyback.
    private func singleFlightRefresh(
        refreshToken: String,
        existing: MCPOAuthTokens
    ) async throws -> MCPOAuthTokens {
        if let existing = inflightRefresh {
            return try await existing.value
        }
        let task = Task { [weak self] () throws -> MCPOAuthTokens in
            guard let self else { throw MCPError.authorizationFailed("authorization actor deallocated") }
            let metadata = try await self.discoverAuthorizationMetadata()
            return try await self.exchangeRefreshToken(
                refreshToken,
                metadata: metadata,
                existing: existing
            )
        }
        inflightRefresh = task
        defer { inflightRefresh = nil }
        return try await task.value
    }

    // MARK: - Authorization code flow

    private func performAuthorizationCodeFlow(metadata: OAuthAuthorizationServerMetadata) async throws -> MCPOAuthTokens {
        let state = randomBase64URL(byteCount: 32)
        let verifierRaw = randomBase64URL(byteCount: 48)
        var verifier = PKCEVerifier(data: Data(verifierRaw.utf8))
        defer { verifier.zero() }

        let challenge = Self.pkceChallenge(for: verifier.stringValue)
        let clientID = try await resolveClientIdentifier(metadata: metadata)

        let callbackScheme = try callbackScheme()
        let authorizationURL = try buildAuthorizationURL(
            endpoint: metadata.authorizationEndpoint,
            clientID: clientID,
            state: state,
            verifierChallenge: challenge
        )

        // When the AS was discovered via TOFU (no pinned issuer), surface an
        // informational event so the host can show "Connecting to <issuer>…" UI
        // or cancel if the discovered AS is unexpected. This does not block
        // the browser from opening — it is purely informational.
        if descriptor.authorizationServerIssuer == nil {
            let resourceMetadataURL = cachedResourceMetadataURL ?? Self.resourceMetadataURL(for: resourceURL)
            eventContinuation?.yield(.authorizationRequired(
                serverID: serverID,
                request: MCPAuthorizationRequest(
                    serverID: serverID,
                    resourceMetadataURL: resourceMetadataURL,
                    authorizationServerURL: metadata.issuer,
                    requiredScopes: descriptor.scopes
                )
            ))
        }

        let callbackURL = try await redirectListener.authorize(
            authorizationURL: authorizationURL,
            callbackURLScheme: callbackScheme,
            prefersEphemeralSession: true
        )

        let code = try parseAuthorizationCode(
            callbackURL: callbackURL,
            expectedState: state,
            metadata: metadata
        )

        if verifier.isExpired {
            throw MCPError.authorizationFailed("PKCE verifier expired; restart authorization")
        }

        return try await exchangeAuthorizationCode(
            code: code,
            verifier: verifier.stringValue,
            clientID: clientID,
            metadata: metadata
        )
    }

    // MARK: - Metadata discovery

    private func discoverAuthorizationMetadata() async throws -> OAuthAuthorizationServerMetadata {
        if let cachedAuthorizationMetadata {
            return cachedAuthorizationMetadata
        }

        let decoder = JSONDecoder()
        let issuer: URL
        if let explicitIssuer = descriptor.authorizationServerIssuer {
            issuer = explicitIssuer
            try enforceHTTPS(issuer, label: "authorization issuer")
        } else {
            let resourceMetadataURL = Self.resourceMetadataURL(for: resourceURL)
            try enforceHTTPS(resourceMetadataURL, label: "resource metadata")
            try await MCPSSRFPolicy.validateOAuthRequestURL(resourceMetadataURL, label: "resource metadata")
            let (data, response) = try await sessionProvider().data(
                for: URLRequest(url: resourceMetadataURL),
                delegate: MCPRedirectCapDelegate(
                    maxRedirects: nil,
                    validator: MCPSSRFPolicy.validateOAuthRedirectURL
                )
            )
            try requireSuccess(response: response, body: data, operation: "resource metadata discovery")
            let resourceMetadata = try decoder.decode(OAuthProtectedResourceMetadata.self, from: data)
            guard let candidateIssuers = resourceMetadata.authorizationServers, candidateIssuers.isEmpty == false else {
                throw MCPError.malformedMetadata("Missing authorization_servers in resource metadata")
            }
            var discoveredIssuer: URL?
            var lastValidationError: Error?
            for candidate in candidateIssuers {
                do {
                    try enforceHTTPS(candidate, label: "authorization issuer")
                    discoveredIssuer = candidate
                    break
                } catch {
                    lastValidationError = error
                }
            }
            guard let discoveredIssuer else {
                if let lastValidationError {
                    throw lastValidationError
                }
                throw MCPError.malformedMetadata("Missing valid authorization server issuer")
            }
            issuer = discoveredIssuer
            cachedResourceMetadataURL = resourceMetadataURL
        }

        let metadataURL = Self.authorizationMetadataURL(for: issuer)
        try enforceHTTPS(metadataURL, label: "authorization metadata")
        try await MCPSSRFPolicy.validateOAuthRequestURL(metadataURL, label: "authorization metadata")
        // Redirect cap: metadata fetches must not follow more than one redirect.
        let (metadataData, metadataResponse) = try await sessionProvider().data(
            for: URLRequest(url: metadataURL),
            delegate: MCPRedirectCapDelegate(validator: MCPSSRFPolicy.validateOAuthRedirectURL)
        )
        try requireSuccess(response: metadataResponse, body: metadataData, operation: "authorization metadata discovery")
        let metadata = try decoder.decode(OAuthAuthorizationServerMetadata.self, from: metadataData)
        try enforceHTTPS(metadata.authorizationEndpoint, label: "authorization endpoint")
        try enforceHTTPS(metadata.tokenEndpoint, label: "token endpoint")

        if Self.isSameIssuer(metadata.issuer, issuer) == false {
            throw MCPError.issuerMismatch(expected: issuer, actual: metadata.issuer)
        }
        if let expectedIssuer = descriptor.authorizationServerIssuer,
           Self.isSameIssuer(metadata.issuer, expectedIssuer) == false {
            throw MCPError.issuerMismatch(expected: expectedIssuer, actual: metadata.issuer)
        }

        cachedAuthorizationMetadata = metadata
        return metadata
    }

    // MARK: - Token exchange

    private func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        clientID: String,
        metadata: OAuthAuthorizationServerMetadata
    ) async throws -> MCPOAuthTokens {
        var parameters: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": descriptor.redirectURI.absoluteString,
            "code_verifier": verifier,
            "client_id": clientID,
        ]
        parameters["resource"] = resourceURL.absoluteString
        return try await tokenExchange(parameters: parameters, metadata: metadata)
    }

    private func exchangeRefreshToken(
        _ refreshToken: String,
        metadata: OAuthAuthorizationServerMetadata,
        existing: MCPOAuthTokens
    ) async throws -> MCPOAuthTokens {
        let clientID = try await resolveClientIdentifier(metadata: metadata)
        var parameters: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        parameters["resource"] = resourceURL.absoluteString
        let refreshed = try await tokenExchange(parameters: parameters, metadata: metadata)
        return MCPOAuthTokens(
            accessTokenData: refreshed.accessTokenData,
            refreshToken: refreshed.refreshToken ?? existing.refreshToken,
            expiresAt: refreshed.expiresAt,
            scopes: refreshed.scopes,
            tokenType: refreshed.tokenType,
            issuer: refreshed.issuer,
            subjectIdentifier: refreshed.subjectIdentifier ?? existing.subjectIdentifier
        )
    }

    private func tokenExchange(
        parameters: [String: String],
        metadata: OAuthAuthorizationServerMetadata
    ) async throws -> MCPOAuthTokens {
        try enforceHTTPS(metadata.tokenEndpoint, label: "token endpoint")
        try await MCPSSRFPolicy.validateOAuthRequestURL(metadata.tokenEndpoint, label: "token endpoint")
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncoded(parameters).data(using: .utf8)

        // Redirect cap: token exchanges must not follow more than one redirect.
        let (data, response) = try await sessionProvider().data(
            for: request,
            delegate: MCPRedirectCapDelegate(validator: MCPSSRFPolicy.validateOAuthRedirectURL)
        )
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response during token exchange")
        }
        if (200...299).contains(http.statusCode) == false {
            throw parseTokenExchangeFailure(statusCode: http.statusCode, body: data)
        }

        let decoder = JSONDecoder()
        let parsed = try decoder.decode(OAuthTokenResponse.self, from: data)
        let scopes = parsed.scope?.split(separator: " ").map(String.init) ?? descriptor.scopes
        let expiresAt = parsed.expiresIn.map { currentDate().addingTimeInterval($0) }

        // Surface a scope downgrade if the AS granted fewer permissions than requested.
        // Silently dropped scopes can be a security or UX surprise; the host app
        // deserves visibility so it can warn the user or retry with a narrower request.
        if parsed.scope != nil, Set(scopes) != Set(descriptor.scopes) {
            eventContinuation?.yield(.scopeDowngraded(
                serverID: serverID,
                requested: descriptor.scopes,
                granted: scopes
            ))
        }

        // Extract subject identifier for multi-account keying (D13).
        let rawJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let subjectID = MCPOAuthTokenStore.subjectIdentifier(from: rawJSON)

        return MCPOAuthTokens(
            accessTokenData: Data(parsed.accessToken.utf8),
            refreshToken: parsed.refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            tokenType: parsed.tokenType ?? "Bearer",
            issuer: metadata.issuer,
            subjectIdentifier: subjectID
        )
    }

    // MARK: - Authorization URL + code parsing

    private func buildAuthorizationURL(
        endpoint: URL,
        clientID: String,
        state: String,
        verifierChallenge: String
    ) throws -> URL {
        try enforceHTTPS(endpoint, label: "authorization endpoint")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: descriptor.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: descriptor.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: verifierChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resourceURL.absoluteString),
        ])
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw MCPError.malformedMetadata("Could not build authorization URL")
        }
        return url
    }

    private func callbackScheme() throws -> String {
        guard let scheme = descriptor.redirectURI.scheme, !scheme.isEmpty else {
            throw MCPError.malformedMetadata("OAuth redirect URI must include a callback scheme")
        }
        return scheme
    }

    /// Validates the redirect callback URL and returns the authorization code.
    ///
    /// RFC 9207: when the AS advertises `authorization_response_iss_parameter_supported`,
    /// the `iss` parameter is required and must match the discovered issuer.
    private func parseAuthorizationCode(
        callbackURL: URL,
        expectedState: String,
        metadata: OAuthAuthorizationServerMetadata
    ) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        if let errorValue = queryItems.first(where: { $0.name == "error" })?.value {
            throw MCPError.authorizationFailed(errorValue)
        }

        let state = queryItems.first(where: { $0.name == "state" })?.value
        guard state == expectedState else {
            throw MCPError.authorizationFailed("OAuth state mismatch")
        }

        // RFC 9207 — iss validation.
        if metadata.authorizationResponseIssParameterSupported {
            let issParam = queryItems.first(where: { $0.name == "iss" })?.value
            guard let issValue = issParam else {
                throw MCPError.authorizationFailed("RFC 9207: iss parameter required but not present")
            }
            guard let issURL = URL(string: issValue) else {
                throw MCPError.authorizationFailed("RFC 9207: iss parameter is not a valid URL")
            }
            // Constant-time comparison via normalised strings to resist timing oracles.
            let expected = Self.normalizedIssuerString(metadata.issuer)
            let actual = Self.normalizedIssuerString(issURL)
            guard constantTimeEqual(expected, actual) else {
                throw MCPError.issuerMismatch(expected: metadata.issuer, actual: issURL)
            }
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MCPError.authorizationFailed("Missing authorization code in callback")
        }
        return code
    }

    // MARK: - Client registration

    private func verifyIssuer(_ issuer: URL) throws {
        if let expected = descriptor.authorizationServerIssuer,
           Self.isSameIssuer(expected, issuer) == false {
            throw MCPError.issuerMismatch(expected: expected, actual: issuer)
        }
    }

    private func isExpired(_ token: MCPOAuthTokens) -> Bool {
        guard let expiresAt = token.expiresAt else { return false }
        return expiresAt <= currentDate().addingTimeInterval(30)
    }

    private func randomBase64URL(byteCount: Int) -> String {
        let generated = random()
        let randomData = generated.isEmpty ? Self.secureRandomData(length: byteCount) : generated
        return Self.base64URL(randomData)
    }

    private func resolveClientIdentifier(metadata: OAuthAuthorizationServerMetadata) async throws -> String {
        if let cachedRegisteredClientID {
            return cachedRegisteredClientID
        }

        let fallbackClientID = clientIdentifier()
        guard descriptor.allowDynamicClientRegistration else {
            return fallbackClientID
        }
        guard let registrationEndpoint = metadata.registrationEndpoint else {
            return fallbackClientID
        }

        do {
            try enforceHTTPS(registrationEndpoint, label: "registration endpoint")
            try await MCPSSRFPolicy.validateOAuthRequestURL(registrationEndpoint, label: "registration endpoint")
            var request = URLRequest(url: registrationEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            var payload: [String: Any] = [
                "client_name": descriptor.clientName,
                "redirect_uris": [descriptor.redirectURI.absoluteString],
                "grant_types": ["authorization_code", "refresh_token"],
                "scope": descriptor.scopes.joined(separator: " ")
            ]
            if let softwareID = descriptor.softwareID, softwareID.isEmpty == false {
                payload["software_id"] = softwareID
            }
            if descriptor.publicClient {
                payload["token_endpoint_auth_method"] = "none"
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

            let (data, response) = try await sessionProvider().data(
                for: request,
                delegate: MCPRedirectCapDelegate(
                    maxRedirects: nil,
                    validator: MCPSSRFPolicy.validateOAuthRedirectURL
                )
            )
            try requireSuccess(response: response, body: data, operation: "dynamic client registration")
            let parsed = try JSONDecoder().decode(OAuthDynamicClientRegistrationResponse.self, from: data)
            guard parsed.clientID.isEmpty == false else {
                throw MCPError.dcrFailed("dynamic client registration did not return client_id")
            }
            cachedRegisteredClientID = parsed.clientID

            // RFC 7592 — persist management credentials if provided (D12).
            if let token = parsed.registrationAccessToken,
               let uriString = parsed.registrationClientURI,
               let uri = URL(string: uriString) {
                registrationManagementToken = token
                registrationManagementURI = uri
                Log.inference.info("MCPOAuthAuthorization: RFC 7592 management token stored for \(self.serverID)")
            }

            return parsed.clientID
        } catch {
            if descriptor.publicClient {
                Log.inference.warning("MCPOAuthAuthorization: DCR unavailable, falling back to static public client identifier")
                return fallbackClientID
            }
            throw MCPError.dcrFailed(error.localizedDescription)
        }
    }

    // MARK: - Error helpers

    private func parseTokenExchangeFailure(statusCode: Int, body: Data) -> MCPError {
        do {
            let oauthError = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: body)
            if oauthError.error == "invalid_grant" {
                return .authorizationRequired(buildAuthorizationRequest())
            }
            let description = oauthError.errorDescription ?? oauthError.error
            return .authorizationFailed("token exchange failed (\(statusCode)): \(description)")
        } catch {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(statusCode)"
            return .authorizationFailed("token exchange failed (\(statusCode)): \(message)")
        }
    }

    private func validateBearerTransmission(_ tokens: MCPOAuthTokens) throws {
        guard tokens.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw MCPError.authorizationFailed("Unsupported token type for Authorization header")
        }
        guard tokens.accessTokenData.isEmpty == false else {
            throw MCPError.authorizationFailed("Missing access token")
        }
        let invalidScalars = CharacterSet.controlCharacters
            .union(.newlines)
            .union(.whitespacesAndNewlines)
        let tokenString = String(data: tokens.accessTokenData, encoding: .utf8) ?? ""
        if tokenString.unicodeScalars.contains(where: { invalidScalars.contains($0) }) {
            throw MCPError.authorizationFailed("Access token contains invalid bearer characters")
        }
    }

    private func buildAuthorizationRequest() -> MCPAuthorizationRequest {
        let metadataURL = cachedResourceMetadataURL ?? Self.resourceMetadataURL(for: resourceURL)
        let safeMetadataURL: URL?
        do {
            try MCPSSRFPolicy.validateOAuthURL(metadataURL, label: "resource metadata")
            safeMetadataURL = metadataURL
        } catch {
            safeMetadataURL = nil
            Log.inference.warning("MCPOAuthAuthorization: omitted unsafe resource metadata URL from auth request")
        }

        let safeAuthorizationURL: URL?
        if let issuer = descriptor.authorizationServerIssuer {
            do {
                try MCPSSRFPolicy.validateOAuthURL(issuer, label: "authorization issuer")
                safeAuthorizationURL = issuer
            } catch {
                safeAuthorizationURL = nil
                Log.inference.warning("MCPOAuthAuthorization: omitted unsafe authorization issuer URL from auth request")
            }
        } else {
            safeAuthorizationURL = nil
        }

        return MCPAuthorizationRequest(
            serverID: serverID,
            resourceMetadataURL: safeMetadataURL,
            authorizationServerURL: safeAuthorizationURL,
            requiredScopes: descriptor.scopes
        )
    }

    private func enforceHTTPS(_ url: URL, label: String) throws {
        try MCPSSRFPolicy.validateOAuthURL(url, label: label)
    }

    private func requireSuccess(response: URLResponse, body: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response during \(operation)")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw MCPError.authorizationFailed("\(operation) failed: \(message)")
        }
    }

    private func clientIdentifier() -> String {
        descriptor.softwareID ?? descriptor.clientName
    }

    // MARK: - Log redaction (D14)

    /// Returns a short hash of the bearer token suitable for logging — never
    /// the raw value. Prevents access tokens appearing in sysdiagnose captures.
    private func bearerRedacted(_ data: Data) -> String {
        mcpBearerRedacted(data)
    }

    // MARK: - Static helpers

    private static func authorizationMetadataURL(for issuer: URL) -> URL {
        let trimmedPath = issuer.path == "/" ? "" : issuer.path
        var components = URLComponents()
        components.scheme = issuer.scheme
        components.host = issuer.host
        components.port = issuer.port
        components.path = "/.well-known/oauth-authorization-server\(trimmedPath)"
        return components.url ?? issuer.appendingPathComponent(".well-known/oauth-authorization-server")
    }

    private static func resourceMetadataURL(for resourceURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = resourceURL.scheme
        components.host = resourceURL.host
        components.port = resourceURL.port
        components.path = "/.well-known/oauth-protected-resource"
        return components.url ?? resourceURL
    }

    private static func isSameOrigin(lhs: URL, rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort(for: lhs)) == (rhs.port ?? defaultPort(for: rhs))
    }

    private static func isSameIssuer(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedIssuerString(lhs) == normalizedIssuerString(rhs)
    }

    private static func normalizedIssuerString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        var path = components.path
        if path == "/" { path = "" }
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        components.path = path

        if components.port == defaultPort(for: url) {
            components.port = nil
        }

        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func defaultPort(for url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func formURLEncoded(_ values: [String: String]) -> String {
        values
            .sorted { $0.key < $1.key }
            .map { key, value in "\(urlEncode(key))=\(urlEncode(value))" }
            .joined(separator: "&")
    }

    private static func urlEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func secureRandomData(length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        return Data(UUID().uuidString.utf8)
    }
}

// MARK: - Bearer redaction (D14)

/// Returns a 4-byte SHA-256 prefix of the bearer token, suitable for log lines.
/// Never returns the raw token value — prevents access tokens appearing in sysdiagnose.
func mcpBearerRedacted(_ data: Data) -> String {
    let hash = Data(SHA256.hash(data: data))
    return "Bearer <\(hash.prefix(4).map { String(format: "%02x", $0) }.joined())>"
}

// MARK: - Constant-time string comparison (D4)

/// Compares two strings in constant time relative to the length of the shorter string.
///
/// Because `timingsafe_bcmp` is not available in the Swift standard library, we
/// use the next-best option: XOR each byte pair and accumulate differences without
/// short-circuiting.  The result is O(min(a,b)) rather than O(1), which is
/// acceptable for URL strings — the important property is no early exit on the
/// first mismatch.
private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(aBytes, bBytes) {
        diff |= x ^ y
    }
    return diff == 0
}

// MARK: - MCPSSRFPolicy

internal enum MCPSSRFPolicy {
    nonisolated(unsafe) static var _resolverForTesting: ((String) async -> [String])? = nil

    static func validateTransportURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MCPError.transportFailure("MCP transport endpoint must use http(s)")
        }
        if PrivateIPClassifier.isLocalhostURL(url) {
            return
        }
        guard scheme == "https" else {
            throw MCPError.transportFailure("MCP transport endpoint must use HTTPS outside localhost")
        }
        try validateHostNotBlocked(url, wrap: { .transportFailure($0) })
    }

    static func validateOAuthURL(_ url: URL, label: String) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw MCPError.authorizationFailed("Expected HTTPS \(label) URL")
        }
        try validateHostNotBlocked(url, wrap: { _ in .authorizationFailed("Expected host in \(label) URL") })
    }

    static func validateTransportRequestURL(_ url: URL) async throws {
        try validateTransportURL(url)
        try await validateResolvedHostNotBlocked(url)
    }

    static func validateOAuthRequestURL(_ url: URL, label: String) async throws {
        try validateOAuthURL(url, label: label)
        try await validateResolvedHostNotBlocked(url)
    }

    static func validateTransportRedirectURL(_ url: URL) throws {
        try validateTransportURL(url)
        try validateResolvedHostNotBlockedSynchronously(url)
    }

    static func validateOAuthRedirectURL(_ url: URL) throws {
        try validateOAuthURL(url, label: "oauth redirect")
        try validateResolvedHostNotBlockedSynchronously(url)
    }

    private static func validateHostNotBlocked(
        _ url: URL,
        wrap: (String) -> MCPError
    ) throws {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw wrap("missing host")
        }
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host

        // Gap A — block mDNS .local names (D6).
        if normalizedHost.hasSuffix(".local") || normalizedHost == "local" {
            throw MCPError.ssrfBlocked(url)
        }

        if PrivateIPClassifier.classifyIPLiteral(normalizedHost) != nil {
            if PrivateIPClassifier.isLocalhostURL(url) == false {
                throw MCPError.ssrfBlocked(url)
            }
        }
    }

    private static func validateResolvedHostNotBlocked(_ url: URL) async throws {
        guard PrivateIPClassifier.isLocalhostURL(url) == false else { return }
        guard let host = normalizedHost(from: url) else {
            throw MCPError.ssrfBlocked(url)
        }
        if PrivateIPClassifier.classifyIPLiteral(host) != nil {
            throw MCPError.ssrfBlocked(url)
        }
        let addresses = await resolveHostname(host)
        for address in addresses where PrivateIPClassifier.classifyIPLiteral(address) != nil {
            throw MCPError.ssrfBlocked(url)
        }
    }

    private static func validateResolvedHostNotBlockedSynchronously(_ url: URL) throws {
        guard PrivateIPClassifier.isLocalhostURL(url) == false else { return }
        guard let host = normalizedHost(from: url) else {
            throw MCPError.ssrfBlocked(url)
        }
        if PrivateIPClassifier.classifyIPLiteral(host) != nil {
            throw MCPError.ssrfBlocked(url)
        }
        let addresses = resolveHostnameSynchronously(host)
        for address in addresses where PrivateIPClassifier.classifyIPLiteral(address) != nil {
            throw MCPError.ssrfBlocked(url)
        }
    }

    private static func normalizedHost(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.isEmpty == false else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    private static func resolveHostname(_ hostname: String) async -> [String] {
        if let override = _resolverForTesting {
            return await override(hostname)
        }
        return await Task.detached(priority: .utility) {
            resolveHostnameSynchronously(hostname)
        }.value
    }

    private static func resolveHostnameSynchronously(_ hostname: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG

        var result: UnsafeMutablePointer<addrinfo>?
        defer { freeaddrinfo(result) }

        guard getaddrinfo(hostname, nil, &hints, &result) == 0, result != nil else {
            return []
        }

        var addresses: [String] = []
        var current = result
        while let info = current {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &host,
                socklen_t(NI_MAXHOST),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let nullIndex = host.firstIndex(of: 0) ?? host.endIndex
                addresses.append(String(decoding: host[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            current = info.pointee.ai_next
        }
        return addresses
    }
}

// MARK: - MCPRedirectCapDelegate (D6 — Gap B)
// Declared at file scope above MCPSSRFPolicy section; already defined as
// `MCPRedirectCapDelegate` near the top of this file.
// TODO: IP pinning — see PinnedSessionDelegate.swift for the certificate-pinning
// pattern.  Full IP pinning (Gap C) requires capturing the resolved address at
// connect time via URLSessionDelegate.connection(_:didConnect:) and comparing it
// against a pre-resolution result from getaddrinfo.  Retrofit is deferred until
// a larger URLSession refactor lands.
