import Foundation
import ManifoldInference

struct OAuthTokenResponse: Decodable {
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

struct OAuthTokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}


struct OAuthTokenExchange {
    static func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        clientID: String,
        metadata: OAuthAuthorizationServerMetadata,
        descriptor: MCPAuthorizationDescriptor.OAuthDescriptor,
        resourceURL: URL,
        serverID: UUID,
        sessionProvider: @Sendable () throws -> URLSession,
        currentDate: @Sendable () -> Date,
        eventContinuation: AsyncStream<MCPConnectionEvent>.Continuation?,
        authorizationRequest: MCPAuthorizationRequest
    ) async throws -> MCPOAuthTokens {
        var parameters: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": descriptor.redirectURI.absoluteString,
            "code_verifier": verifier,
            "client_id": clientID,
        ]
        parameters["resource"] = resourceURL.absoluteString
        return try await tokenExchange(
            parameters: parameters,
            metadata: metadata,
            descriptor: descriptor,
            serverID: serverID,
            sessionProvider: sessionProvider,
            currentDate: currentDate,
            eventContinuation: eventContinuation,
            authorizationRequest: authorizationRequest
        )
    }

    static func exchangeRefreshToken(
        _ refreshToken: String,
        clientID: String,
        metadata: OAuthAuthorizationServerMetadata,
        existing: MCPOAuthTokens,
        descriptor: MCPAuthorizationDescriptor.OAuthDescriptor,
        resourceURL: URL,
        serverID: UUID,
        sessionProvider: @Sendable () throws -> URLSession,
        currentDate: @Sendable () -> Date,
        eventContinuation: AsyncStream<MCPConnectionEvent>.Continuation?,
        authorizationRequest: MCPAuthorizationRequest
    ) async throws -> MCPOAuthTokens {
        var parameters: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        parameters["resource"] = resourceURL.absoluteString
        let refreshed = try await tokenExchange(
            parameters: parameters,
            metadata: metadata,
            descriptor: descriptor,
            serverID: serverID,
            sessionProvider: sessionProvider,
            currentDate: currentDate,
            eventContinuation: eventContinuation,
            authorizationRequest: authorizationRequest
        )
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

    static func validateBearerTransmission(_ tokens: MCPOAuthTokens) throws {
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

    private static func tokenExchange(
        parameters: [String: String],
        metadata: OAuthAuthorizationServerMetadata,
        descriptor: MCPAuthorizationDescriptor.OAuthDescriptor,
        serverID: UUID,
        sessionProvider: @Sendable () throws -> URLSession,
        currentDate: @Sendable () -> Date,
        eventContinuation: AsyncStream<MCPConnectionEvent>.Continuation?,
        authorizationRequest: MCPAuthorizationRequest
    ) async throws -> MCPOAuthTokens {
        try OAuthSecurity.enforceHTTPS(metadata.tokenEndpoint, label: "token endpoint")
        try await MCPSSRFPolicy.validateOAuthRequestURL(metadata.tokenEndpoint, label: "token endpoint")
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthSecurity.formURLEncoded(parameters).data(using: .utf8)

        let (data, response) = try await sessionProvider().data(
            for: request,
            delegate: MCPRedirectCapDelegate(validator: MCPSSRFPolicy.validateOAuthRedirectURL)
        )
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response during token exchange")
        }
        if (200...299).contains(http.statusCode) == false {
            throw parseTokenExchangeFailure(statusCode: http.statusCode, body: data, authorizationRequest: authorizationRequest)
        }

        let decoder = JSONDecoder()
        let parsed = try decoder.decode(OAuthTokenResponse.self, from: data)
        let scopes = parsed.scope?.split(separator: " ").map(String.init) ?? descriptor.scopes
        let expiresAt = parsed.expiresIn.map { currentDate().addingTimeInterval($0) }

        if parsed.scope != nil, Set(scopes) != Set(descriptor.scopes) {
            eventContinuation?.yield(.scopeDowngraded(
                serverID: serverID,
                requested: descriptor.scopes,
                granted: scopes
            ))
        }

        let rawJSON: [String: Any]
        do {
            rawJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            Log.inference.warning("OAuthTokenExchange: token response subject metadata was not JSON decodable")
            rawJSON = [:]
        }
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

    private static func parseTokenExchangeFailure(
        statusCode: Int,
        body: Data,
        authorizationRequest: MCPAuthorizationRequest
    ) -> MCPError {
        do {
            let oauthError = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: body)
            if oauthError.error == "invalid_grant" {
                return .authorizationRequired(authorizationRequest)
            }
            let description = oauthError.errorDescription ?? oauthError.error
            return .authorizationFailed("token exchange failed (\(statusCode)): \(description)")
        } catch {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(statusCode)"
            return .authorizationFailed("token exchange failed (\(statusCode)): \(message)")
        }
    }
}
