# Migration: pre-1.0 deprecation shims deleted

**Audience:** consumer
**Status:** living

**This is a breaking change.** Every `@available(*, deprecated …)` declaration
in `Sources/` has been removed. AGENTS.md § "Public API design policy (pre-1.0)"
says *"pre-1.0, delete — don't deprecate"*: deprecation is a post-1.0 tool for
giving consumers a migration window, and before 1.0 there is no stability
promise to protect. Nine shims had accumulated against that rule because
nothing enforced it; `DeprecationShimAuditTest` now does.

Most removed declarations were already naming their own replacement in their
deprecation message; the table below is that message, made load-bearing. The
exception is `SeedModelError`, which has no replacement because nothing could
ever throw it.

## What to change

| Removed | Replacement |
|---|---|
| `BackendCapabilities.streamsToolCallArgumentDeltas` | `BackendCapabilities.streamsToolCallArguments` — the stored property, the codable key, and the name every backend already used. |
| `TurnUsageRecord` (typealias) | `TurnUsage`. |
| `MCPOAuthTokens.accessToken` (`String`) | `MCPOAuthTokens.accessTokenData` (`Data`). Convert with `String(data:encoding:)` only at a UI or protocol boundary — the point of the `Data` form is to shorten the window in which the token lives as a heap `String`. |
| `CloudBackendError.timeout(Duration)` | `InferenceError.idleTimeout`. The idle-timeout wrapper (`GenerationStream`) serves local backends too, so the failure is backend-neutral; the cloud-specific case had not been thrown by the framework for some time. |
| `SeedModelError` (whole type) | Nothing. See below. |
| `StorageManagementView()` | `StorageManagementView(modelRegistry:)` — pass `chatViewModel.modelRegistry`. |
| `ModelManagementSheet(initialTab:recommendedModelIDs:recommendationTitle:recommendationMessage:)` | The same initializer **with** `modelRegistry:` as its first argument. |
| `OllamaBackend.init(urlSession:)` | **Nothing — it stays `public` and keeps working.** Only its deprecation warning is gone. Registering via `OllamaBackends.register(with:)` / `quickStart()` is still preferred, and `makeChecked(urlSession:)` is the kill-switch-safe factory, but neither is now forced on you. |

## Three of these deserve more than a table row

### `SeedModelError` was removed entirely, not just its case

The type had exactly one case, `huggingFaceTraitNotAvailable`, documented as
unreachable since v0.48 (the `HuggingFace` trait retired; the download
machinery is always compiled in). It was **never thrown anywhere** — its only
references were its own declaration and its own `errorDescription` switch.

It had survived the inert-surface audit because
`Tests/APIFreezeTests/inert-surface-allowlist.txt` exempted it with the reason
*"host-facing error — thrown by `quickStart(seed:)`; caught downstream"*, which
was not true. The allowlist entry is removed with the type. If you have a
`catch let error as SeedModelError` arm, delete it: nothing could reach it.

### `OllamaBackend.makeChecked(urlSession:)` is **not** removed — its deprecation was a bug

`makeChecked` carried a deprecation whose message read *"…or use
`makeChecked(urlSession:)` for kill-switch-safe construction"* — pointing at
itself. It was a copy of the neighbouring initializer's attribute, and the
sibling `OpenAIBackend.makeChecked` was never deprecated. A consumer who
followed the initializer's own migration advice therefore got a warning telling
them to do the thing they had just done.

`makeChecked` is the recommended construction path and is now un-deprecated.
**If you migrated away from it because of that warning, migrate back.**

### `OllamaBackend.init(urlSession:)` keeps working — nothing to migrate

Its deprecation objected to *bypassing registration*, not to a missing
replacement, so there was nothing to migrate *to*: registration is a preference,
not a substitute for an initializer. The warning is removed and the initializer
stays `public`.

An earlier draft of this change demoted it to `package`. That was wrong and was
reverted during review: `FiresideEvalCore` calls `OllamaBackend(urlSession:)`
directly inside a compiled `#if Ollama`, and AGENTS.md § "Public API design
policy (pre-1.0)" states that the `package` default "does NOT apply to anything
a … consumer app consumes directly — those surfaces must stay `public`, full
stop." Narrowing it needs its own change, screened with
`scripts/api-demotion-screen.sh` and landed in lockstep with that consumer —
not a drive-by inside a shim sweep.

## Why the code got smaller than the table suggests

Deleting the two SwiftUI initializers orphaned an entire second construction
path: `RegistrySource.environment` and a private `EnvironmentBridge` view in
each of `StorageManagementView` and `ModelManagementSheet`, whose only writers
were those initializers. Both views now store a `ModelRegistry` directly. A
read path with no writer is dead code (Principle 10), so it went with them.

## Enforcement

`DeprecationShimAuditTest` (in `ManifoldCoreTests`) fails on any
`@available(*, deprecated …)` under `Sources/`. It is deliberately
zero-tolerance with **no allowlist** — an allowlist is exactly how the
inert-surface audit was defeated above. Platform availability
(`@available(macOS 26, *)`) is untouched. When the project reaches 1.0 and
deprecation becomes the correct tool, that audit is deleted or inverted in the
same PR that changes the policy.
