# ManifoldKit 1.0 — release criteria and post-1.0 policies

ManifoldKit is pre-1.0: minor versions can break, and [API-DESIGN.md § 4](API-DESIGN.md#4-pre-10-evolution-policy)
says so plainly — delete, don't deprecate. **1.0 is the freeze point** where
that stops being true for the surfaces this document covers. This page
answers two questions: what does the 1.0 freeze actually include, and what
happens after it — the handful of policies a 1.0 announcement implicitly
promises but that aren't written down anywhere yet.

## 1.0 release criteria

Reaching 1.0 means the following are each in a state ManifoldKit is willing
to hold stable under normal semver rules:

- **API surface.** Every `public` symbol in a `.library()` product is
  intentional — not merely whatever compiled. The api-surface baseline
  (`scripts/api-surface-baseline.sh`) and the per-PR breakage-diff gate
  both stay green through the freeze, and the four semver-exempt dev-tool
  products (API-DESIGN.md § 7) keep their looser, explicitly-labeled
  exemption rather than silently inheriting the main promise.
- **Schema.** SwiftData's `ManifoldMigrationPlan` migrates every stage
  `.lightweight` — see Policy 3 below.
- **Traits.** The trait roster (`Server`, `Macros`, plus the WWDC stubs) is
  the traits that exist; adding a new one is a deliberate, documented
  decision, not an accretion.
- **Platform floors.** The n-1 policy (README.md, AGENTS.md) keeps running
  after 1.0 — see Policy 1.
- **Companion independence.** manifold-mlx and manifold-llama version and
  release independently of core — see Policy 4.
- **Performance stance.** Perf is explicitly not part of the semver
  contract — see Policy 5.

These criteria describe the shape of the freeze; they don't replace the
tracking issue for the work of getting there.

## Policy 1 — Platform-floor bumps are not a semver break

ManifoldKit follows an n-1 platform policy: the current Apple OS release and
the one immediately before it. Apple ships a new major OS every September,
and both minimums bump by one at that point.

**Platform floors sit outside the API compatibility promise.** A September
floor bump — even though it can make old deployment targets stop
compiling — ships as a **MINOR** release, not a major, and is announced one
release ahead in the changelog so a consumer pinned to an exact version sees
it coming. The rationale: the floor bump follows a fixed, public, yearly
calendar independent of anything ManifoldKit's API does, and holding it to
major-version cadence would mean either a major release every September
regardless of what else shipped, or holding the floor back and diverging
from Apple's own support window. Neither serves consumers better than an
advance-notice minor bump does.

## Policy 2 — Deprecation window

Pre-1.0, ManifoldKit deletes rather than deprecates (API-DESIGN.md § 4)
because there's no stability promise yet to protect. Post-1.0, that promise
exists, so the two-phase deprecation cycle API-DESIGN.md § 4 deferred to
"post-1.0" is:

- **Deprecate in a minor.** A retired API is marked
  `@available(*, deprecated, message: "...")` with a migration note, and
  keeps working.
- **Remove in the next major.** The deprecated API is deleted at the next
  major version boundary, not before.
- **Critical-fix window.** The prior major line (`1.x` once `2.0.0` ships)
  keeps receiving critical fixes — security issues, data-loss bugs — for
  **6 months** after the next major ships. This is deliberately modest:
  ManifoldKit is solo-maintained, and a longer support window is a promise
  that can't be kept consistently. Six months is enough time for a consumer
  to schedule a migration without ManifoldKit carrying two active support
  lines indefinitely.

## Policy 3 — SwiftData schema stability

Every migration stage in `Sources/ManifoldPersistenceSwiftData/Schema/ManifoldMigrationPlan.swift`
is `.lightweight` today, and has been since the schema had a migration plan
at all — new columns default in place, no data motion. Post-1.0 this
becomes a promise rather than an accident:

- **Lightweight-only within a major.** Every schema change released under
  `1.x` migrates existing stores with a `.lightweight` stage — no destructive
  migration, no data loss, no manual export/import step required to upgrade.
- **Destructive migrations are a major-version event.** If a schema change
  genuinely can't be expressed as a lightweight stage, it ships at a major
  boundary, with a documented, tested export path a consumer can run before
  upgrading.

This policy has a tripwire, not just a description: `ManifoldMigrationPlanLightweightAuditTest`
(`Tests/ManifoldPersistenceSwiftDataTests/ManifoldMigrationPlanLightweightAuditTest.swift`)
fails CI if any stage in `ManifoldMigrationPlan.stages` is anything other
than `.lightweight`. A destructive migration is still possible — the test
doesn't forbid it — but it forces the PR that introduces one to consciously
update the audit's allowlist, which is exactly the point where "is this a
major-version event?" gets asked instead of skipped.

## Policy 4 — Core↔companion 1.0 semantics

The pin lifecycle and compatibility canary are already documented in
[COMPANION-BACKENDS.md § 4](COMPANION-BACKENDS.md#4-pin-and-release-lifecycle).
What that section doesn't say is what a companion's own 1.0 means relative
to core's:

**Core and companions version independently.** Core reaching 1.0 does not
require manifold-mlx or manifold-llama to reach 1.0 at the same time, and
core's 1.0 release is not blocked on either companion being ready. Each
companion declares the range of core versions it supports (its `.upToNextMinor`
pin plus the compatibility canary already enforce this in practice); a
companion is free to stay pre-1.0, tracking core's stable API from the
outside, for as long as it needs to.

## Policy 5 — Performance is not a semver property

Performance work in ManifoldKit is nightly-only and, with one exception (the
streaming-cadence threshold in `IntegratedStreamingPerformanceTests.swift`),
non-gating. **Performance stays explicitly outside the semver contract.** A
release that makes some path slower is not, on its own, a breaking change,
and ManifoldKit does not promise a fixed latency or throughput envelope
across versions. The streaming-cadence tripwire and the nightly perf suites
continue as the mechanism for catching regressions — they're a quality bar,
not a compatibility one.

## Known limitation — the api-digester isolation blind spot

Verified directly (2026-07-12): ran `swift package diagnose-api-breaking-changes`
against `ManifoldUI` and inspected the raw `--baseline-dir` ABIRoot JSON for
`ChatViewModel` — a `@MainActor @Observable public final class`. The raw
digester dump is not entirely blind to isolation: `ChatViewModel`'s node
carries `"declAttributes": ["Final", "Custom"]` (a generic marker that
*some* custom attribute is present, without naming which) and a
`conformances` list that includes `Sendable` — the implicit conformance
`@MainActor` isolation grants a type. So the raw signal technically exists
in the dump.

**But `scripts/_lib/api-surface-extract.py` — the normalizer that produces
the checked-in baseline text — never reads either field.** It emits one
line per type (`declKind` only: `ChatViewModel Class`) and one line per
member (`printedName` + `declKind` only), and confirmed empirically:
running the normalizer against the `ChatViewModel` dump emits exactly
`ChatViewModel Class` for the type and plain signature lines for its
members — no `declAttributes`, no `conformances`, anywhere. **Adding,
removing, or changing a `@MainActor` / `nonisolated` / `Sendable`
annotation on an existing public declaration produces zero diff** in the
checked-in baseline. The per-PR breakage-diff gate
(`swift package diagnose-api-breaking-changes`'s own comparison, ci.yml:599-660)
was not separately re-verified here, but it diagnoses signature-shaped
breakage and has no documented isolation-attribute check either.

That class of change is source-breaking under Swift 6's strict concurrency
checking — a caller that relied on a type being `@MainActor`-isolated (or
safely `Sendable`) can fail to compile against the new version — but no
existing gate sees it. There is currently no automated tripwire for
isolation-annotation changes; a reviewer has to catch it by reading the
diff. Closing this gap would mean teaching the normalizer to also emit
`declAttributes`/`conformances` lines (the raw data is already there) — out
of scope for this document, but a concrete, scoped follow-up if it's ever
prioritized.
