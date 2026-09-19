# Migration: `ManifoldAnyLanguageModel` retired

**Audience:** consumer
**Status:** living

**This is a breaking change.** The `ManifoldAnyLanguageModel` product — the
bridge to HuggingFace's [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel)
package — has been removed outright ([#2435](https://github.com/ManifoldKit/ManifoldKit/issues/2435)).
`import ManifoldAnyLanguageModel` no longer compiles, and the external
`AnyLanguageModel` package has left the dependency resolution graph
(`Package.resolved`) entirely. The `ManifoldCapability.providerBridge` enum
case that named this capability in `FeatureMatrix.swift` is also gone — a
`switch` over `ManifoldCapability` that lists it explicitly no longer
compiles.

> **If your app depends on ManifoldKit via `.package(path:)` (an unpinned
> local checkout), a version tag does not insulate you from this** — you
> reach this break on your next rebuild, not on your next deliberate version
> bump. Check for `import ManifoldAnyLanguageModel`, `AnyLanguageModelBackend`,
> or `ManifoldCapability.providerBridge` before pulling the latest core commit.

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
| `AnyLanguageModelBackend` | `OpenAIBackend` (`ManifoldCloudSaaS`, re-exported by the `ManifoldKit` umbrella), configured via an `APIEndpointRecord` with `provider: .custom`. Reaches xAI, Groq, Mistral, and OpenRouter directly; does **not** reach Gemini's own endpoint (see below). |
| `AnyLanguageModelURLResolver` / `gemini://…?apiKey=…`-style URL scheme configuration | `APIEndpointRecord(name:provider:baseURL:modelName:)` + `KeychainService.store(key:account:)` — the same 5-step cloud endpoint flow every other custom/self-hosted provider already uses. |
| `AnyLanguageModelBridgeCapabilities` / `AnyLanguageModelBridgeError` | N/A — `OpenAIBackend` reports its own `BackendCapabilities` and throws `CloudBackendError` / `RetryExhaustedError` (both already `BackendError`-conforming). |
| `ManifoldCapability.providerBridge` | N/A — the case named a capability that no longer exists. A `switch` that lists it explicitly needs the case removed, not replaced. |
| The external `AnyLanguageModel` package (`Package.swift` dependency) | Removed entirely; no replacement dependency needed. |

## Gemini is a special case — read this before you copy the recipe below

Four of the five providers the bridge named — **xAI, Groq, Mistral,
OpenRouter** — are OpenAI-compatible endpoints reachable through
`OpenAIBackend` today. **Gemini's own OpenAI-compatible endpoint is not**,
and no `baseURL` value fixes this:

`OpenAIBackend.buildRequest` hardcodes the completions path — every request
goes to `baseURL.appendingPathComponent("v1/chat/completions")`
(`Sources/ManifoldCloudSaaS/OpenAIBackend.swift:317`), with no way to
override the suffix. That path shape matches xAI, Groq, Mistral, and
OpenRouter's OpenAI-compatible APIs, all of which serve
`<base>/v1/chat/completions`. Gemini's OpenAI-compatible API does not: it
serves `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions`
— there is no `/v1` segment before `chat/completions`, so no `baseURL` you
configure can produce that exact path through the fixed `v1/chat/completions`
suffix.

**The fix is not "adjust the base URL" — there is no base URL that works.**
Reach Gemini models through **OpenRouter** instead, which proxies Gemini
alongside its other models and *is* reachable through `OpenAIBackend`
(`modelName: "google/gemini-2.0-flash-001"` or similar — check
[OpenRouter's model list](https://openrouter.ai/models) for the current
identifier). This is a genuine, if narrow, capability loss from the retired
bridge — see "The one genuine loss" below.

## How to migrate

### Before (no longer compiles)

```swift,no-build:ManifoldAnyLanguageModel was retired in #2435 — this module no longer exists
import ManifoldAnyLanguageModel

let backend = AnyLanguageModelBackend()
// configured via a gemini://MODEL?apiKey=KEY-shaped URL passed to
// AnyLanguageModelURLResolver.resolve(_:)
```

### After: configure the provider as a custom OpenAI-compatible endpoint

Worked example below uses **OpenRouter** — the base URL every other provider
in this doc follows the same shape, just with a different host (see the
table after the snippet). Note the base URL carries **no** `/v1` suffix:
`OpenAIBackend` appends `v1/chat/completions` itself, so a base URL that
already ends in `/v1` doubles up and 404s.

```swift
import ManifoldKit

func addOpenRouterEndpoint(bootstrap: ManifoldBootstrap, vm: ChatViewModel) async throws {
    // 1. Build the record. `.custom` is the same provider case every
    //    self-hosted / non-native endpoint uses (LM Studio, a proxy, …).
    //    NOTE: no trailing /v1 — OpenAIBackend appends `v1/chat/completions`.
    let endpoint = APIEndpointRecord(
        name: "OpenRouter",
        provider: .custom,
        baseURL: "https://openrouter.ai/api",
        modelName: "openai/gpt-4o-mini"
    )

    // 2. Store the API key in the Keychain (throws on failure).
    try KeychainService.store(key: "sk-or-v1-...", account: endpoint.keychainAccount)

    // 3. Persist the endpoint via the bootstrap's EndpointStore.
    try await bootstrap.endpointStore.insertEndpoint(endpoint)

    // 4. Certificate pinning is NOT automatic for this host — see the next
    //    section. Skipping this step does NOT fail here or at step 5: both
    //    loadModel and loadCloudEndpoint below only check that a baseURL is
    //    configured and never touch the network. The pinning gate fires on
    //    the FIRST GENERATION REQUEST (the first sendMessage), not at load —
    //    so an app that skips this step looks fully configured until a user
    //    actually sends a message.

    // 5. Route the chat view model to the new backend. loadCloudEndpoint is
    //    NOT throws — a load failure is reported via the view model's own
    //    error state, not by throwing here.
    await vm.loadCloudEndpoint(endpoint)
}
```

Other providers follow the identical shape — swap `baseURL` and `modelName`.
**No base URL below has a trailing `/v1`:**

| Provider | `baseURL` | Reaches Gemini too? |
|---|---|---|
| OpenRouter | `https://openrouter.ai/api` | Yes — `modelName` a Gemini model ID |
| xAI | `https://api.x.ai` | No |
| Groq | `https://api.groq.com/openai` | No |
| Mistral | `https://api.mistral.ai` | No |
| Gemini direct | *(not reachable — see above)* | — |

This is the same 5-step flow documented in
[AGENTS.reference.md → Cloud backend setup](../AGENTS.reference.md#cloud-backend-setup) for every
other cloud endpoint, plus one step none of AGENTS.md's built-in providers
need: pinning.

## Certificate pinning: required, not automatic

`CredentialedHostTrustGate` fail-closes any credentialed request to a
non-loopback host with no configured SPKI pins
(`Sources/ManifoldCloudCore/CredentialedHostTrustGate.swift`) —
`ManifoldConfiguration.allowUnpinnedCredentialedHosts` defaults to `false`.
`PinnedSessionDelegate`'s shipped default pin set covers exactly four hosts:
`api.openai.com`, `api.anthropic.com`, `api.jina.ai`, `api.cohere.com`
(`Sources/ManifoldCloudCore/PinnedSessionDelegate.swift`). **None of the
providers in this doc — OpenRouter, xAI, Groq, Mistral — are in that set.**

**Skipping this step does not fail at setup — it fails on the first message.**
Neither `OpenAIBackend.loadModel` nor `ChatViewModel.loadCloudEndpoint(_:)`
(which isn't `throws`; a load failure surfaces through the view model's own
error state, not a thrown error) ever touch the network or check pinning —
both only confirm a `baseURL` is configured. `CredentialedHostTrustGate` is
wired into `SSEGenerationTaskRunner`'s per-generation `validateEndpoint()`
step, called immediately before the connection opens for each request. So an
app that skips pinning looks fully configured through setup, and the first
`sendMessage` throws `CloudBackendError.unpinnedCredentialedHost` — see
`CloudBackendError.swift`'s `errorDescription` for the exact message.

Two ways to satisfy the gate, in order of preference.

**Option 1 — pin the host (recommended for production).** Extract the SPKI
SHA-256 hash of the provider's certificate chain — `PinnedSessionDelegate`'s
own doc comment documents the pipeline:

```bash
openssl s_client -connect openrouter.ai:443 </dev/null 2>/dev/null | \
  openssl x509 -pubkey -noout | \
  openssl pkey -pubin -outform DER | \
  openssl dgst -sha256 -binary | base64
```

**This command yields the LEAF certificate's pin.** Prefer pinning the
intermediate or root CA instead — leaf pins break on every certificate
renewal (60–90 days for most issuers); intermediate/root pins survive it,
because `PinnedSessionDelegate` checks every certificate in the chain against
the pin set, not just the leaf. To get the intermediate, add `-showcerts` to
`s_client` (it prints the full chain, leaf first), then run the `openssl x509
… | openssl pkey … | openssl dgst …` portion of the pipeline above against the
**second** certificate block, not the first. Pin more than one hash per host —
`PinnedSessionDelegate`'s own doc comment recommends at least one backup pin
to avoid lockout during rotation. Then, before any network request:

```swift,no-build:API-shape excerpt — the two <...> entries are placeholders for real openssl pipeline output, not literal Swift
import ManifoldCloudCore

PinnedSessionDelegate.pinnedHosts["openrouter.ai"] = [
    "<intermediate SPKI hash>",
    "<root SPKI hash — backup pin, avoids lockout on rotation>",
]
```

**Option 2 — opt out** (accepts residual DNS-rebinding risk — read
[`docs/RELIABILITY.md` § Certificate pinning](RELIABILITY.md#certificate-pinning)
first):

```swift,no-build:API-shape excerpt for assistants; intentionally terse, no imports or surrounding context
ManifoldConfiguration.shared.allowUnpinnedCredentialedHosts = true
```

## What you gain, not just what you lose

The replacement path is **more** capable than the bridge was on the axes that
matter to a turn loop. The retired bridge advertised a conservative
capability floor — `supportsToolCalling: false`, `supportsStructuredOutput:
false`, `supportsThinking: false`, `supportsNativeJSONMode: false`
(`AnyLanguageModelCapabilities.swift`, pre-retirement) — and fail-closed on
anything past plain-text chat. `OpenAIBackend` reports `supportsToolCalling:
true` and `supportsStructuredOutput: true`
(`Sources/ManifoldCloudSaaS/OpenAIBackend.swift:170-171`), and every
`ManifoldCloudCore`-backed family gets retry with backoff, circuit breaking,
and latest-wins cancellation the bridge never had. Certificate pinning is
**not** part of that "free" list — see above; it's a step the bridge also
never did (it had no pinning at all), but the replacement path makes you do
correctly rather than skip silently.

## The one genuine loss

The bridge could talk to Gemini's **native** API surface directly (via
`GeminiLanguageModel` in the upstream package) with no third party in the
request path. That native surface was text-only in the bridge anyway (no
reasoning-token streaming — the bridge advertised `supportsThinking = false`),
so the lost *capability* is narrow. But the lost *path* is real: Gemini now
requires routing through OpenRouter, a genuine third party between your app
and Google's endpoint, where the bridge's `gemini://` scheme talked to Google
directly. A consumer that specifically needs "Gemini, and nothing else in the
request path" has no ManifoldKit-native answer today. Everything else — tool
calling, structured output, streaming, and every non-Gemini provider the
bridge named — is strictly better on the replacement path.
