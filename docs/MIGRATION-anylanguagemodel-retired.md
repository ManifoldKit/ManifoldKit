# Migration: `ManifoldAnyLanguageModel` retired

**Audience:** consumer
**Status:** living

**This is a breaking change.** The `ManifoldAnyLanguageModel` product — the
bridge to HuggingFace's [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel)
package — has been removed outright ([#2435](https://github.com/ManifoldKit/ManifoldKit/issues/2435)).
`import ManifoldAnyLanguageModel` no longer compiles, and the external
`AnyLanguageModel` package has left the dependency resolution graph
(`Package.resolved`) entirely.

> **If your app depends on ManifoldKit via `.package(path:)` (an unpinned
> local checkout), a version tag does not insulate you from this** — you
> reach this break on your next rebuild, not on your next deliberate version
> bump. Check for `import ManifoldAnyLanguageModel` or `AnyLanguageModelBackend`
> before pulling the latest core commit.

## Why

Two independent reasons, either one sufficient on its own:

1. **Zero adoption.** The bridge had no importers anywhere in `Sources/` and no
   hits across ManifoldKit's screened consumer apps. A product nobody uses
   does not earn a third-party dependency edge, however well-maintained that
   dependency is.
2. **Dependency coupling.** The bridge's public surface named `any
   LanguageModel` — a protocol owned by the external, pre-1.0 `AnyLanguageModel`
   package. Its stability could only ever track that upstream package's
   release cadence, never ManifoldKit's own. It was already documented as
   semver-exempt for exactly this reason (`docs/API-DESIGN.md` § 7,
   `docs/PRODUCTION-READINESS.md` § 3a) before this retirement made the
   question moot.

This is **not** a statement that `huggingface/AnyLanguageModel` itself is
unhealthy — it is actively maintained. It is a statement that ManifoldKit
shipping a product nobody used, coupled to someone else's pre-1.0 surface, was
not worth the maintenance cost.

## What changed

| Removed | Replacement |
|---------|-------------|
| `import ManifoldAnyLanguageModel` | Nothing to import — see below. |
| `AnyLanguageModelBackend` | `OpenAIBackend` (`ManifoldCloudSaaS`, re-exported by the `ManifoldKit` umbrella), configured via an `APIEndpointRecord` with `provider: .custom`. |
| `AnyLanguageModelURLResolver` / `gemini://…?apiKey=…`-style URL scheme configuration | `APIEndpointRecord(name:provider:baseURL:modelName:)` + `KeychainService.store(key:account:)` — the same 5-step cloud endpoint flow every other custom/self-hosted provider already uses. |
| `AnyLanguageModelBridgeCapabilities` / `AnyLanguageModelBridgeError` | N/A — `OpenAIBackend` reports its own `BackendCapabilities` and throws `CloudBackendError` / `RetryExhaustedError` (both already `BackendError`-conforming). |
| The external `AnyLanguageModel` package (`Package.swift` dependency) | Removed entirely; no replacement dependency needed. |

Every provider the bridge named — Gemini, xAI, Groq, Mistral, OpenRouter — is
an **OpenAI-compatible endpoint**. ManifoldKit already has a native OpenAI
client; the bridge's only job was routing to providers `OpenAIBackend` can
already reach directly.

## How to migrate

### Before (no longer compiles)

```swift,no-build:ManifoldAnyLanguageModel was retired in #2435 — this module no longer exists
import ManifoldAnyLanguageModel

let backend = AnyLanguageModelBackend()
// configured via a gemini://MODEL?apiKey=KEY-shaped URL passed to
// AnyLanguageModelURLResolver.resolve(_:)
```

### After: configure the provider as a custom OpenAI-compatible endpoint

```swift
import ManifoldKit

func addGeminiEndpoint(bootstrap: ManifoldBootstrap, vm: ChatViewModel) async throws {
    // 1. Build the record. `.custom` is the same provider case every
    //    self-hosted / non-native endpoint uses (LM Studio, a proxy, …).
    let endpoint = APIEndpointRecord(
        name: "Gemini",
        provider: .custom,
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        modelName: "gemini-2.0-flash"
    )

    // 2. Store the API key in the Keychain (throws on failure).
    try KeychainService.store(key: "GEMINI_API_KEY", account: endpoint.keychainAccount)

    // 3. Persist the endpoint via the bootstrap's EndpointStore.
    try await bootstrap.endpointStore.insertEndpoint(endpoint)

    // 4. Route the chat view model to the new backend.
    await vm.loadCloudEndpoint(endpoint)
}
```

Swap `baseURL` for the provider you need — xAI (`https://api.x.ai/v1`), Groq
(`https://api.groq.com/openai/v1`), Mistral (`https://api.mistral.ai/v1`), or
OpenRouter (`https://openrouter.ai/api/v1`) — and `modelName` for that
provider's model identifier. This is the same 5-step flow documented in
[AGENTS.md → Cloud backend setup](../AGENTS.md#cloud-backend-setup) for every
other cloud endpoint; there is no bridge-specific API to learn.

## What you gain, not just what you lose

The replacement path is **more** capable than the bridge was, not less. The
retired bridge advertised a conservative capability floor —
`supportsToolCalling: false`, `supportsStructuredOutput: false`,
`supportsThinking: false`, `supportsNativeJSONMode: false`
(`AnyLanguageModelCapabilities.swift`, pre-retirement) — and fail-closed on
anything past plain-text chat. `OpenAIBackend` reports `supportsToolCalling:
true` and `supportsStructuredOutput: true`
(`Sources/ManifoldCloudSaaS/OpenAIBackend.swift:170-171`), and every
`ManifoldCloudCore`-backed family gets certificate pinning, retry with
backoff, circuit breaking, and latest-wins cancellation the bridge never had.

## The one genuine loss

The bridge could talk to Gemini's **native** API surface directly (not just
its OpenAI-compatible shim) with no third party in the request path. That
native surface was text-only in the bridge anyway (no reasoning-token
streaming — the bridge advertised `supportsThinking = false`), so the
practical capability gap is narrow: a consumer that specifically needed
"Gemini, and nothing routes through an OpenAI-shaped client" loses that
framing, not any concrete feature. Everything else — tool calling, structured
output, streaming — is strictly better on the replacement path.
