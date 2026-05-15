import Foundation

struct OAuthProtectedResourceMetadata: Decodable {
    let authorizationServers: [URL]?

    private enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

struct OAuthAuthorizationServerMetadata: Decodable {
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

struct OAuthDynamicClientRegistrationResponse: Decodable {
    let clientID: String
    let registrationAccessToken: String?
    let registrationClientURI: String?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case registrationAccessToken = "registration_access_token"
        case registrationClientURI = "registration_client_uri"
    }
}


struct AuthorizationServerDiscovery {
    struct Result {
        let metadata: OAuthAuthorizationServerMetadata
        let resourceMetadataURL: URL?
    }

    static func discover(
        descriptor: MCPAuthorizationDescriptor.OAuthDescriptor,
        resourceURL: URL,
        sessionProvider: @Sendable () throws -> URLSession
    ) async throws -> Result {
        let decoder = JSONDecoder()
        let issuer: URL
        let discoveredResourceMetadataURL: URL?

        if let explicitIssuer = descriptor.authorizationServerIssuer {
            issuer = explicitIssuer
            try OAuthSecurity.enforceHTTPS(issuer, label: "authorization issuer")
            discoveredResourceMetadataURL = nil
        } else {
            let resourceMetadataURL = OAuthSecurity.resourceMetadataURL(for: resourceURL)
            try OAuthSecurity.enforceHTTPS(resourceMetadataURL, label: "resource metadata")
            try await MCPSSRFPolicy.validateOAuthRequestURL(resourceMetadataURL, label: "resource metadata")
            let (data, response) = try await sessionProvider().data(
                for: URLRequest(url: resourceMetadataURL),
                delegate: MCPRedirectCapDelegate(
                    maxRedirects: 3,
                    validator: MCPSSRFPolicy.validateOAuthRedirectURL
                )
            )
            try OAuthSecurity.requireSuccess(response: response, body: data, operation: "resource metadata discovery")
            let resourceMetadata = try decoder.decode(OAuthProtectedResourceMetadata.self, from: data)
            guard let candidateIssuers = resourceMetadata.authorizationServers, candidateIssuers.isEmpty == false else {
                throw MCPError.malformedMetadata("Missing authorization_servers in resource metadata")
            }
            var discoveredIssuer: URL?
            var lastValidationError: Error?
            for candidate in candidateIssuers {
                do {
                    try OAuthSecurity.enforceHTTPS(candidate, label: "authorization issuer")
                    discoveredIssuer = candidate
                    break
                } catch {
                    lastValidationError = error
                }
            }
            guard let validIssuer = discoveredIssuer else {
                if let lastValidationError {
                    throw lastValidationError
                }
                throw MCPError.malformedMetadata("Missing valid authorization server issuer")
            }
            issuer = validIssuer
            discoveredResourceMetadataURL = resourceMetadataURL
        }

        let metadataURL = OAuthSecurity.authorizationMetadataURL(for: issuer)
        try OAuthSecurity.enforceHTTPS(metadataURL, label: "authorization metadata")
        try await MCPSSRFPolicy.validateOAuthRequestURL(metadataURL, label: "authorization metadata")
        let (metadataData, metadataResponse) = try await sessionProvider().data(
            for: URLRequest(url: metadataURL),
            delegate: MCPRedirectCapDelegate(validator: MCPSSRFPolicy.validateOAuthRedirectURL)
        )
        try OAuthSecurity.requireSuccess(response: metadataResponse, body: metadataData, operation: "authorization metadata discovery")
        let metadata = try decoder.decode(OAuthAuthorizationServerMetadata.self, from: metadataData)
        try OAuthSecurity.enforceHTTPS(metadata.authorizationEndpoint, label: "authorization endpoint")
        try OAuthSecurity.enforceHTTPS(metadata.tokenEndpoint, label: "token endpoint")

        if OAuthSecurity.isSameIssuer(metadata.issuer, issuer) == false {
            throw MCPError.issuerMismatch(expected: issuer, actual: metadata.issuer)
        }
        if let expectedIssuer = descriptor.authorizationServerIssuer,
           OAuthSecurity.isSameIssuer(metadata.issuer, expectedIssuer) == false {
            throw MCPError.issuerMismatch(expected: expectedIssuer, actual: metadata.issuer)
        }

        return Result(metadata: metadata, resourceMetadataURL: discoveredResourceMetadataURL)
    }
}
