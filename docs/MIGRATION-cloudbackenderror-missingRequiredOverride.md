# Migration: `CloudBackendError` gains `missingRequiredOverride`; vocabulary growth policy declared

**Audience:** consumer
**Status:** living

**This is a breaking change** for any exhaustive `switch` statement over
`CloudBackendError` outside this package (`ManifoldKit`'s own three
exhaustive switches — `category`, `errorDescription`, `isRetryable` — were
updated in the same PR that added the case).

## Why

`SSECloudBackend.buildRequest(...)`'s base implementation used to `fatalError`
when a subclass forgot to override it — a crash rather than a compile error,
because `SSECloudBackend` is `open` and no companion package (manifold-mlx,
manifold-llama) subclasses it, so nothing catches a missing override at
build time. The fix makes the base implementation throw instead (it was
already `throws`, so this needed no signature change) — but it initially
threw the existing `CloudBackendError.invalidURL`, which is semantically
wrong: `errorDescription` for `.invalidURL` reads "Invalid server URL: …",
which sends an integrator hunting their `baseURL` configuration instead of
their subclass's missing override. A missing override is a
programmer/integration error, not a malformed URL.

`CloudBackendError` was already carrying an unassessed growth policy — it
sat in `public_enum_freeze_allowlist.txt` (the "assessed but deliberately
unannotated yet" set from the #2208 enum-growth sweep) rather than a
"Vocabulary freeze" or "Vocabulary growth" doc-comment marker. Adding a case
here forced that assessment: `CloudBackendError` grows over time as new
provider-specific failure modes are added (`quotaExceeded`,
`providerOverloaded`, `contentFiltered`, `blockedAddress`,
`unpinnedCredentialedHost`, and now `missingRequiredOverride` all landed
after the type's original ship), so it is declared **"Vocabulary growth
(1.x)"**, not frozen, and removed from the freeze-audit allowlist in favour
of the doc-comment marker.

## What changed

- **New case:** `CloudBackendError.missingRequiredOverride(String)` —
  `.nonRetryable`, `isRetryable == false`, `errorDescription` reads
  `"Internal error: \(detail)"`.
- **`SSECloudBackend.buildRequest(...)`**'s base (un-overridden) fallback now
  throws `.missingRequiredOverride` instead of `.invalidURL` or `fatalError`.
- `CloudBackendError`'s doc comment gained a "Vocabulary growth (1.x)"
  marker; its entry in `Tests/ManifoldInferenceTests/public_enum_freeze_allowlist.txt`
  was removed.

## What needs a one-line fix

An **exhaustive `switch` statement over `CloudBackendError`** outside this
package no longer compiles. Add a `default:` (or an explicit
`case .missingRequiredOverride:`) arm — the recommended pattern going
forward, since the type is now declared vocabulary-growth, not frozen:

```swift
switch error {
case .missingAPIKey: // ...
case .networkDisabled: // ...
default:
    // Handle unrecognized/future CloudBackendError cases, including
    // .missingRequiredOverride.
}
```

No behavior changes for code that pattern-matches specific cases (`if case
.invalidURL = error`) or reads `.errorDescription`/`.isRetryable` generically
— only exhaustive switches need the fix.
