# OAuth flow

Use ``MCPOAuthAuthorization`` when `MCPServerDescriptor.authorization` is `.oauth`.

## Wiring

```swift,no-build
import ManifoldMCP

let descriptor = MCPAuthorizationDescriptor.OAuthDescriptor(
    clientName: "ManifoldKit",
    scopes: ["tools:read", "tools:write"],
    redirectURI: URL(string: "basechat://oauth/callback")!,
    authorizationServerIssuer: URL(string: "https://auth.example.com")
)

let authorization = MCPOAuthAuthorization(
    descriptor: descriptor,
    serverID: UUID(),
    resourceURL: URL(string: "https://resource.example.com/mcp")!,
    redirectListener: redirectListener,
    tokenStore: .keychain
)
```

Pass it to `connect`:

```swift,no-build
let source = try await MCPClient().connect(serverDescriptor, authorization: authorization)
```

## Runtime sequence

1. Load stored tokens from ``MCPOAuthTokenStore``.
2. If valid, attach `Authorization` only for same-origin HTTPS requests.
3. If expired and refresh token exists, refresh via token endpoint.
4. If no valid token, run Authorization Code + PKCE via ``MCPOAuthRedirectListener``.
5. Persist new tokens and retry.

On 401/403, `handleUnauthorized` attempts refresh and returns `.retry` or `.fail`.
If refresh fails with OAuth `invalid_grant`, stored tokens are cleared and the caller receives an `authorizationRequired` request to force a clean re-consent flow.

## Discovery and validation

`MCPOAuthAuthorization` can discover:

- resource metadata: `/.well-known/oauth-protected-resource`
- authorization metadata: `/.well-known/oauth-authorization-server`

It enforces HTTPS for issuer, authorization endpoint, token endpoint, and rejects issuer mismatches (`MCPError.issuerMismatch`).
For public clients with `allowDynamicClientRegistration = true`, it attempts DCR when `registration_endpoint` is published, and safely falls back to static client identity if DCR is unavailable.
