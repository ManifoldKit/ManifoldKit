import Foundation
import ManifoldInference

public protocol MCPOAuthRedirectListener: Sendable {
    func authorize(
        authorizationURL: URL,
        callbackURLScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL
}

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

    /// Wiring point for `MCPClient.connect(_:authorization:)`: connects this
    /// authorization's event stream to the client's `connectionEventContinuation`
    /// so `.authorizationRequired` / `.scopeDowngraded` events (raised during
    /// token acquisition/refresh, see `performAuthorizationCodeFlow` and
    /// `OAuthTokenExchange.exchangeRefreshToken`) reach `MCPClient.connectionEvents`
    /// instead of being dropped. `eventContinuation` otherwise defaults to `nil`
    /// and nothing connects it post-init — `MCPClient`'s stream is the
    /// canonical path only when the caller hasn't already wired one up
    /// itself. Non-destructive: a caller that supplied its own
    /// `eventContinuation` at construction time (to observe this
    /// authorization directly, independent of any `MCPClient`) keeps
    /// receiving events on that stream — `attach` never silently reroutes it.
    func attach(eventContinuation continuation: AsyncStream<MCPConnectionEvent>.Continuation) {
        guard eventContinuation == nil else { return }
        self.eventContinuation = continuation
    }

    public func authorizationHeader(for requestURL: URL) async throws -> String? {
        try await MCPSSRFPolicy.validateOAuthRequestURL(requestURL, label: "oauth request")
        guard OAuthSecurity.isSameOrigin(lhs: requestURL, rhs: resourceURL) else {
            return nil
        }

        let tokens = try await activeTokens()
        try OAuthTokenExchange.validateBearerTransmission(tokens)
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
                    Log.inference.warning("MCPOAuthAuthorization: failed to clear token store after invalid_grant (\(error.localizedDescription))")
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
            // Management URI is a fixed endpoint — redirects are not expected and would be
            // a sign of misconfiguration or a hostile network. Allow zero.
            _ = try await sessionProvider().data(
                for: request,
                delegate: MCPRedirectCapDelegate(
                    maxRedirects: 0,
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
                try OAuthTokenExchange.validateBearerTransmission(stored)
                return stored
            }

            if let refreshToken = stored.refreshToken {
                do {
                    let refreshed = try await singleFlightRefresh(refreshToken: refreshToken, existing: stored)
                    try await tokenStore.write(refreshed, serverID)
                    try OAuthTokenExchange.validateBearerTransmission(refreshed)
                    return refreshed
                } catch {
                    try await tokenStore.delete(serverID)
                    Log.inference.warning("MCPOAuthAuthorization: refresh failed, forcing full OAuth authorization (\(error.localizedDescription))")
                }
            }
        }

        let metadata = try await discoverAuthorizationMetadata()
        let codeResponse = try await performAuthorizationCodeFlow(metadata: metadata)
        try await tokenStore.write(codeResponse, serverID)
        try OAuthTokenExchange.validateBearerTransmission(codeResponse)
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
        let state = try randomBase64URL(byteCount: 32)
        let verifierRaw = try randomBase64URL(byteCount: 48)
        var verifier = PKCEVerifier(data: Data(verifierRaw.utf8))
        defer { verifier.zero() }

        let challenge = OAuthSecurity.pkceChallenge(for: verifier.stringValue)
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
            let resourceMetadataURL = cachedResourceMetadataURL ?? OAuthSecurity.resourceMetadataURL(for: resourceURL)
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

        let result = try await AuthorizationServerDiscovery.discover(
            descriptor: descriptor,
            resourceURL: resourceURL,
            sessionProvider: sessionProvider
        )
        cachedAuthorizationMetadata = result.metadata
        if let resourceMetadataURL = result.resourceMetadataURL {
            cachedResourceMetadataURL = resourceMetadataURL
        }
        return result.metadata
    }

    // MARK: - Token exchange

    private func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        clientID: String,
        metadata: OAuthAuthorizationServerMetadata
    ) async throws -> MCPOAuthTokens {
        try await OAuthTokenExchange.exchangeAuthorizationCode(
            code: code,
            verifier: verifier,
            clientID: clientID,
            metadata: metadata,
            descriptor: descriptor,
            resourceURL: resourceURL,
            serverID: serverID,
            sessionProvider: sessionProvider,
            currentDate: currentDate,
            eventContinuation: eventContinuation,
            authorizationRequest: buildAuthorizationRequest()
        )
    }

    private func exchangeRefreshToken(
        _ refreshToken: String,
        metadata: OAuthAuthorizationServerMetadata,
        existing: MCPOAuthTokens
    ) async throws -> MCPOAuthTokens {
        let clientID = try await resolveClientIdentifier(metadata: metadata)
        return try await OAuthTokenExchange.exchangeRefreshToken(
            refreshToken,
            clientID: clientID,
            metadata: metadata,
            existing: existing,
            descriptor: descriptor,
            resourceURL: resourceURL,
            serverID: serverID,
            sessionProvider: sessionProvider,
            currentDate: currentDate,
            eventContinuation: eventContinuation,
            authorizationRequest: buildAuthorizationRequest()
        )
    }

    // MARK: - Authorization URL + code parsing

    private func buildAuthorizationURL(
        endpoint: URL,
        clientID: String,
        state: String,
        verifierChallenge: String
    ) throws -> URL {
        try OAuthSecurity.enforceHTTPS(endpoint, label: "authorization endpoint")
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
            let expected = OAuthSecurity.normalizedIssuerString(metadata.issuer)
            let actual = OAuthSecurity.normalizedIssuerString(issURL)
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
           OAuthSecurity.isSameIssuer(expected, issuer) == false {
            throw MCPError.issuerMismatch(expected: expected, actual: issuer)
        }
    }

    private func isExpired(_ token: MCPOAuthTokens) -> Bool {
        guard let expiresAt = token.expiresAt else { return false }
        return expiresAt <= currentDate().addingTimeInterval(30)
    }

    private func randomBase64URL(byteCount: Int) throws -> String {
        let generated = random()
        let randomData = generated.isEmpty ? try OAuthSecurity.secureRandomData(length: byteCount) : generated
        return OAuthSecurity.base64URL(randomData)
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
            try OAuthSecurity.enforceHTTPS(registrationEndpoint, label: "registration endpoint")
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
            try OAuthSecurity.requireSuccess(response: response, body: data, operation: "dynamic client registration")
            let parsed = try JSONDecoder().decode(OAuthDynamicClientRegistrationResponse.self, from: data)
            guard parsed.clientID.isEmpty == false else {
                throw MCPError.dcrFailed("dynamic client registration did not return client_id")
            }
            cachedRegisteredClientID = parsed.clientID

            // RFC 7592 — persist management credentials if provided (D12).
            // Validate both the URI (SSRF) and token (bearer-safe chars) at storage time so
            // disconnect() never operates on untrusted values even if its own check is bypassed.
            if let token = parsed.registrationAccessToken,
               let uriString = parsed.registrationClientURI,
               let uri = URL(string: uriString) {
                do {
                    try await MCPSSRFPolicy.validateOAuthRequestURL(uri, label: "registration management URI")
                    let invalidScalars = CharacterSet.controlCharacters
                        .union(.newlines)
                        .union(.whitespacesAndNewlines)
                    guard !token.unicodeScalars.contains(where: { invalidScalars.contains($0) }) else {
                        throw MCPError.dcrFailed("registration_access_token contains invalid bearer characters")
                    }
                    registrationManagementToken = token
                    registrationManagementURI = uri
                    Log.inference.info("MCPOAuthAuthorization: RFC 7592 management token stored for \(self.serverID)")
                } catch {
                    Log.inference.warning("MCPOAuthAuthorization: RFC 7592 management credentials rejected (\(error.localizedDescription)); client deregistration will be skipped")
                }
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

    private func buildAuthorizationRequest() -> MCPAuthorizationRequest {
        let metadataURL = cachedResourceMetadataURL ?? OAuthSecurity.resourceMetadataURL(for: resourceURL)
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

    private func clientIdentifier() -> String {
        descriptor.softwareID ?? descriptor.clientName
    }
}
