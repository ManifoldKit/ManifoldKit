# Cloud OAuth / Token Rotation with `TokenProvider`

`TokenProvider` is the protocol that lets `SSECloudBackend` work with
short-lived credentials — OAuth access tokens, JWTs, or any credential that
may expire and needs silent refresh. The backend calls `token()` on every
outbound request, so the implementation can refresh transparently without the
caller noticing.

---

## 1. When to use `TokenProvider` vs static API keys

| Scenario | Recommended approach |
|---|---|
| Long-lived API key stored in Keychain | `configure(baseURL:keychainAccount:modelName:)` |
| Server-issued short-lived JWT / OAuth token | `TokenProvider` + `configure(baseURL:tokenProvider:modelName:)` |
| Multi-tenant app where each user has a separate token | `TokenProvider` with per-user token storage |
| Proxy server that vends session tokens to mobile clients | `TokenProvider` that calls your proxy's `/token` endpoint |

Static Keychain-backed keys are simpler and avoid the overhead of an async
hop on every request. Reserve `TokenProvider` for credentials that rotate —
if you put a static key behind a `TokenProvider`, you gain nothing.

---

## 2. Implementing `TokenProvider`

`TokenProvider` is declared in `ManifoldCloudCore` and re-exported through
`ManifoldCloud` and the `ManifoldKit` umbrella. You only need to import the
module your target already depends on.

```swift,no-build
import ManifoldCloudCore // or ManifoldKit / ManifoldCloud

public protocol TokenProvider: Sendable {
    /// Returns a valid bearer token. May perform a network round-trip to
    /// refresh an expired token before returning.
    func token() async throws -> String
}
```

**Minimal conforming example** — reads from an in-memory store with a
simulated refresh:

```swift,no-build
import Foundation
import ManifoldCloudCore

/// Stores a token in memory and refreshes it via a network call when expired.
actor MyOAuthTokenProvider: TokenProvider {
    private var accessToken: String
    private var expiresAt: Date

    init(initialToken: String, expiresAt: Date) {
        self.accessToken = initialToken
        self.expiresAt = expiresAt
    }

    func token() async throws -> String {
        if Date.now < expiresAt {
            return accessToken
        }
        // Token expired — refresh from your auth server.
        let refreshed = try await fetchNewToken()
        self.accessToken = refreshed.token
        self.expiresAt = refreshed.expiresAt
        return refreshed.token
    }

    private struct TokenResponse {
        let token: String
        let expiresAt: Date
    }

    private func fetchNewToken() async throws -> TokenResponse {
        // Replace with a real URLSession call to your OAuth token endpoint.
        TokenResponse(token: "new-token-\(UUID())", expiresAt: Date.now.addingTimeInterval(3600))
    }
}
```

**Server-proxy pattern** — each call hits your own backend, which
validates the user session and mints a short-lived token for the upstream AI
provider. This keeps the upstream API key entirely off the device:

```swift,no-build
import Foundation
import ManifoldCloudCore

struct ProxyTokenProvider: TokenProvider {
    let proxyURL: URL
    let sessionCookie: String // your app's own auth credential

    func token() async throws -> String {
        var request = URLRequest(url: proxyURL.appendingPathComponent("/ai-token"))
        request.setValue("session=\(sessionCookie)", forHTTPHeaderField: "Cookie")
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = try JSONDecoder().decode(TokenResponse.self, from: data)
        return body.token
    }

    private struct TokenResponse: Decodable { let token: String }
}
```

---

## 3. Wiring via `SSECloudBackend.configure(tokenProvider:)`

`configure(baseURL:tokenProvider:modelName:)` is the `SSECloudBackend` overload
that installs a `TokenProvider`. It replaces any previously set API key or
Keychain account — only one credential source is active at a time.

**Anthropic `ClaudeBackend` example:**

```swift,no-build
import ManifoldCloud
import ManifoldCloudCore

// 1. Build the provider. The actor serialises concurrent refresh calls.
let tokenProvider = MyOAuthTokenProvider(
    initialToken: "sk-ant-...",     // boot token from your auth flow
    expiresAt: Date.now.addingTimeInterval(3600)
)

// 2. Construct the backend.
let backend = ClaudeBackend()

// 3. Configure it with the token provider.
backend.configure(
    baseURL: URL(string: "https://api.anthropic.com")!,
    tokenProvider: tokenProvider,
    modelName: "claude-opus-4-5"
)

// 4. Load it (marks `isModelLoaded = true`).
try await backend.loadModel(from: nil, plan: .init(modelInfo: .init(id: "claude-opus-4-5")))
```

From this point, every call to `backend.generate(prompt:systemPrompt:config:)`
will call `tokenProvider.token()` before building the outbound HTTP request.
If the token has expired, `token()` refreshes it transparently.

**Tip:** Use `ManifoldBootstrap` with a custom `InferenceService` when you
want token rotation inside the full SwiftData-backed stack:

```swift,no-build
import ManifoldKit
import ManifoldCloud
import ManifoldCloudCore

let tokenProvider = MyOAuthTokenProvider(...)
let backend = ClaudeBackend()
backend.configure(
    baseURL: URL(string: "https://api.anthropic.com")!,
    tokenProvider: tokenProvider,
    modelName: "claude-opus-4-5"
)

let inferenceService = InferenceService()
inferenceService.register(backend)

let kit = try ManifoldBootstrap(
    configuration: ManifoldConfiguration(bundleIdentifier: "com.example.MyApp"),
    inferenceService: inferenceService
)
```

---

## 4. Thread safety

`TokenProvider.token()` is called from within `SSECloudBackend`'s internal
async context — the call may arrive from any actor or cooperative thread. Your
implementation must be safe to call concurrently from multiple contexts.

The recommended patterns:

- **`actor`** — Swift actors serialise access automatically. This is the
  simplest choice when your token cache involves mutable state (expiry
  timestamps, stored tokens). See the `MyOAuthTokenProvider` example above.
- **Value type + Keychain** — If your token refresh is entirely stateless
  (e.g. you always call a remote endpoint), a `struct` that conforms to both
  `TokenProvider` and `Sendable` works without an actor.

Avoid `@unchecked Sendable` on a class with unprotected mutable state — two
concurrent `token()` calls could interleave the expiry check and the refresh
assignment, causing a double-refresh or a stale token to be returned.

---

## Relationship to Keychain-backed configuration

`configure(baseURL:tokenProvider:modelName:)` and
`configure(baseURL:keychainAccount:modelName:)` are mutually exclusive. Calling
either one clears the other:

```swift,no-build
// Sets token provider; clears any prior Keychain account.
backend.configure(baseURL: url, tokenProvider: myProvider, modelName: model)

// Sets Keychain account; clears any prior token provider.
backend.configure(baseURL: url, keychainAccount: "com.example.claude-key", modelName: model)
```

The internal resolution order in `resolveTokenAsync()` is:
1. `TokenProvider.token()` (async, may refresh)
2. Keychain-backed `SecureBytes` (sync)
3. Ephemeral API key (sync, test use only)

Only the first configured source is used.
