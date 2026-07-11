# Toward 1.0 — release criteria and the post-1.0 policies

> **Status: proposal.** This document has two halves. The first — *1.0 release
> criteria* — enumerates what the `1.0.0` freeze actually covers, and is a
> factual description of the current stability program. The second — *Post-1.0
> policies* — is five decisions the maintainer has not yet made. Each policy
> below carries a recommendation, its main alternative, and a one-line decision
> ask; until each is ruled on, the recommendation is a proposal, not project
> policy. See [issue #2211](https://github.com/ManifoldKit/ManifoldKit/issues/2211).

ManifoldKit is built for sustained development — apps operated over months and
years, not a demo that compiles once. `1.0.0` is the point where that promise
gains a version contract: a consumer who reads a changelog and bumps a minor
should not have their build break. Everything below exists to make that sentence
true, and to make explicit the handful of places where it deliberately does not
apply.

The `0.x` line has been stabilising pieces incrementally, on purpose: breaking
changes are cheap pre-1.0 and are spent through scheduled `feat!:` waves, each
with a migration note (see [`API-DESIGN.md` § 4](API-DESIGN.md) and the
`MIGRATION-*.md` guides). `1.0.0` is the freeze point where that latitude ends
and semantic versioning starts carrying weight.

---

## Part 1 — 1.0 release criteria

The freeze covers six surfaces. For each, "frozen" means a specific, checkable
thing — not a vibe. Where a tripwire already enforces the property, it is named;
Principle 4 (every rule has a tested tripwire) applies to this document as much
as to any other.

### 1. Public API surface

The SwiftPM **products** are the API — module placement inside `Sources/` is
internal topology and can change without a major
([`API-DESIGN.md` § 5](API-DESIGN.md)). What freezes at 1.0 is the public
symbol surface of every `.library()` product: a public type, member, or
protocol requirement present at 1.0 stays present, with a compatible signature,
for the life of the 1.x line. Additions are always allowed (they are minors);
removals and incompatible signature changes require a major.

This is already instrumented by two complementary gates, which stay in force
across the 1.0 boundary:

- The per-PR source-compatibility check
  (`swift package diagnose-api-breaking-changes`) catches removals and
  type/signature changes.
- The nightly public-surface baseline (`scripts/api-surface-baseline.sh`)
  catches additions, removals, and `public`→`package` demotions across every
  library product.

Two known limitations of this instrumentation are recorded in
[Appendix A](#appendix-a--api-digester-isolation-change-blind-spot) — the more
consequential is that neither gate reliably detects an actor-isolation change
(adding `@MainActor` to a public symbol), which is source-breaking under Swift 6
but is not an ABI property. That gap must be closed, or explicitly accepted as a
manual review item, before 1.0.

Default visibility is `package`, not `public`
([`API-DESIGN.md` § 3](API-DESIGN.md)); the 1.0 surface is the set of symbols
deliberately claimed as `public`, not whatever the compiler happened to accept.

### 2. Persistence schema

The SwiftData schema is versioned (`ManifoldSchemaV3` … `ManifoldSchemaV12` as
of this writing) with a migration plan
(`Sources/ManifoldPersistenceSwiftData/Schema/ManifoldMigrationPlan.swift`)
whose every stage is a `.lightweight` migration, each covered by a read-back
test. On-disk stores written by any 1.x release must open in any later 1.x
release without data loss. The forward-looking promise that makes this a 1.0
property — lightweight-only within a major — is **Policy 3** below; it is a
proposal, not yet decided.

### 3. Traits

There are no default traits: plain `swift build` is the full core build. The
surviving opt-in traits are `Server` and `Macros` (plus the WWDC stubs). The
trait *roster* is part of the surface — removing or renaming a trait breaks a
consumer manifest that names it (SwiftPM hard-errors on an unknown trait, as the
v0.48 retirement demonstrated). Post-1.0, retiring a trait is a breaking change
and follows the same major-version rule as removing a symbol.

### 4. Platform floors

ManifoldKit targets **n-1**: the current Apple OS and the one before it (macOS
26 / 15, iOS 26 / 18 today), and bumps both floors each September when Apple
ships a new major OS. Whether a floor bump is a minor or a major is **Policy 1**
below — the single most time-sensitive decision here, because the first
post-1.0 September bump lands roughly twelve months after 1.0 ships and needs a
written rule before then, not during.

### 5. Companion independence

The heavy local-inference families live in companion packages
([`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx),
[`manifold-llama`](https://github.com/ManifoldKit/manifold-llama)) that depend
on this package's `ManifoldInference` from their own repos, pin it with
`.upToNextMinor`, and run a compat canary ([`COMPANION-BACKENDS.md`
§ 4](COMPANION-BACKENDS.md)). What "core 1.0" means relative to "companion 1.0"
is **Policy 4** below.

### 6. Performance

Performance is measured nightly and is mostly non-gating: the one asserted
threshold is a streaming-cadence regression tripwire
(`IntegratedStreamingPerformanceTests`, which fails only on a *profoundly*
broken cadence, not on baseline drift). Whether performance is a versioned
property of 1.0 — i.e. whether a perf regression can constitute a breaking
change — is **Policy 5** below.

### Semver-exempt products (unchanged by 1.0)

Four developer-tooling products stay outside the semver promise even after 1.0,
exactly as documented in [`API-DESIGN.md` § 7](API-DESIGN.md):
`ManifoldTestSupport`, `ManifoldPersistenceTestSupport`,
`ManifoldBackendTestKit`, and `ManifoldTools`. They may break in any minor with
a migration note. 1.0 does not change their status; this section exists so the
exemption is visible from the freeze document, not only from the API design
page.

---

## Part 2 — Post-1.0 policies (proposals for decision)

Each policy states its context, a recommendation with rationale, the main
alternative and why not, and a one-line decision ask phrased so it can be
accepted or rejected with one word. The recommendations are written to be
modest and solo-maintainer-sustainable — a policy that assumes a release team
this project does not have would be a policy nobody can keep.

### Policy 1 — Platform-floor bumps vs semver

**Context.** The n-1 policy bumps deployment targets every September. Nothing
currently says whether raising the iOS/macOS floor forces a major version. This
detonates on a schedule: the first post-1.0 September bump arrives about twelve
months after 1.0, and if the rule isn't written, it gets decided under pressure.

**Recommendation.** Platform floors are **outside** the API stability promise.
A September floor bump is a **minor** release, announced one release ahead in the
changelog. Rationale: the alternative makes ManifoldKit emit a new major every
year mechanically, decoupled from any actual API change, which drains the
signal out of the major-version number — a "2.0" that means only "we dropped
last year's OS" tells a consumer nothing about their code. A consumer who must
stay on an old OS pins to the last minor that supported it (`0.x`-era guidance
already teaches exact/`upToNextMinor` pinning); that is the same tool they would
use against a major, at lower ceremony.

**Alternative considered — floor bump = major.** It is defensible on the
strict reading that raising a deployment target can break a consumer's build
(their app still targets the old OS). Rejected because the breakage is a
resolve-time floor mismatch a pin already solves, and the annual-major cost to
version-number meaning is worse than the benefit.

**Decision ask:** Are September platform-floor bumps MINOR (recommended) or
MAJOR?

### Policy 2 — Deprecation window and support policy

**Context.** [`API-DESIGN.md` § 4](API-DESIGN.md) defers deprecation to
"post-1.0" but never defines the window: how long a deprecated symbol survives,
and how long a shipped major receives fixes. Pre-1.0 the rule is *delete, don't
deprecate* — that changes at 1.0, when there is finally a stability promise to
protect with a migration runway.

**Recommendation (kept deliberately modest).** Deprecate in a minor, remove in
the next major. That gives every removed API at least one minor's worth of
`@available(*, deprecated)` warning with a documented replacement before it
disappears. Support window: the previous major line (1.x) receives **critical
fixes for six months after the next major (2.0) ships**, then goes
end-of-life. Rationale: this is the smallest policy that is honestly keepable by
a solo maintainer — one deprecation hop, one bounded support tail — and it still
gives consumers a real, written migration runway instead of a silent removal.

**Alternative considered — longer/tiered support (e.g. 12-month LTS, two
deprecation cycles).** Rejected: it reads well but promises maintenance labor
that a single-maintainer project cannot reliably deliver, and an unmet support
promise is worse than a modest kept one.

**Decision ask:** Adopt "deprecate-in-minor, remove-in-next-major, 6-month
critical-fix tail on the prior major" (recommended), or a different window?

### Policy 3 — SwiftData schema-stability promise

**Context.** Practice is already clean: every stage in `ManifoldMigrationPlan`
is `.lightweight`, each with a read-back test, so no store has ever needed a
destructive migration. But no forward-looking promise exists, and Principle 4
says a rule ships with its tripwire.

**Recommendation.** **Lightweight-only within a major.** Any schema change
inside a major version must be expressible as a SwiftData lightweight migration
(additive/renaming, no data-destroying transform). Destructive or custom-stage
migrations are permitted **only at a major version boundary**, and only with a
documented export/re-import path shipped alongside. Enforce it with a new audit
test (see tripwire shape below) that fails on any non-`.lightweight` stage in
the migration plan. Rationale: this promises consumers exactly what the code
already delivers — an in-place upgrade across a 1.x line — and turns an
accidental clean streak into a guaranteed one.

**Alternative considered — no schema promise (best-effort migrations).**
Rejected: it leaves the strongest existing guarantee (never-lost data across
every version to date) undocumented and unenforced, so a future custom-stage
migration could quietly ship in a minor and break the one property persistence
consumers care about most.

**Tripwire shape (to ship in this policy's PR — do not implement here).** An
XCTest audit in the persistence test target that verifies every element of
`ManifoldMigrationPlan.stages` is the `.lightweight` case. Because
`MigrationStage` is a SwiftData enum whose cases are not trivially introspectable
by pattern-match alone across SDK versions, the robust shape is a
**source-scanning audit** (mirroring the existing audit-test family, e.g.
`SilentCatchAuditTest`): read `ManifoldMigrationPlan.swift`, find each stage
literal in the `stages` array, and fail if any stage is constructed with a
non-`.lightweight` initializer (`.custom(...)` or any future destructive
constructor). The scan approach also survives the enum gaining new cases without
a compile break. Pair it with the audit-sabotage suite the way the other audits
are: plant a `.custom` stage in the sabotage fixture and confirm the audit
fires. Allowlist the sabotage fixture path in the scanner so it doesn't trip on
its own plant.

**Decision ask:** Promise "lightweight-only within a major, destructive only at
majors with an export path," enforced by the audit above (recommended)?

### Policy 4 — Core ↔ companion 1.0 semantics

**Context.** The pin lifecycle and compat canary between core and the companion
backend packages are documented ([`COMPANION-BACKENDS.md`
§ 4](COMPANION-BACKENDS.md)), but not what "companion 1.0" means relative to
"core 1.0." A naive reading couples them — core cannot reach 1.0 until the
companions do, or vice versa.

**Recommendation.** **Independent versioning.** Core 1.0 neither waits for nor
drags `manifold-mlx` / `manifold-llama` to 1.0. Each companion versions on its
own cadence and declares a **supported-core range** (the existing
`.upToNextMinor` pin plus the compat canary already express and enforce this).
A companion may sit at `0.x` against a `1.x` core, or reach `1.0` before core
does; the only contract between them is the declared core range and a green
canary. Rationale: the packages were split precisely so a heavy GPU/native
dependency evolves on its own clock; re-coupling their version numbers would
re-import the coupling the split removed.

**Alternative considered — lockstep majors (core and companions share a major
line).** Rejected: it forces a companion to cut a major it doesn't need every
time core does (and vice versa), which is the annual-empty-major problem of
Policy 1 in a second guise, across repos.

**Decision ask:** Adopt independent core/companion versioning with a
declared supported-core range (recommended), or lockstep majors?

### Policy 5 — Performance as a 1.0 property

**Context.** Performance is nightly-measured and mostly non-gating: one asserted
streaming-cadence tripwire, everything else baseline-tracked without a hard
threshold. A 1.0 announcement could be read as promising perf stability the same
way it promises API stability.

**Recommendation.** Performance is **explicitly outside the semver contract.** A
perf regression is a bug to be fixed, not a breaking change requiring a major.
Keep the streaming-cadence tripwire and the nightly perf suites as regression
detectors; state in one sentence in Part 1 that perf is not versioned.
Rationale: perf on-device is a function of model, hardware, and OS as much as of
this code, so a hard perf-semver promise would be one the project cannot honestly
keep across the device matrix it runs on. Documenting the tripwire's existence
gives consumers the honest guarantee — regressions are caught and fixed — without
overclaiming a numeric contract.

**Alternative considered — perf budgets in the semver contract (a named
regression is a breaking change).** Rejected: attractive in principle, but it
requires stable per-device baselines the nightly-only, hardware-variable setup
cannot provide, so the promise would be routinely false.

**Decision ask:** State perf as explicitly out of the semver contract, tripwire
retained (recommended)?

---

## Appendix A — API-digester isolation-change blind spot

Issue #2211 asks whether the API-freeze tooling detects a change to a public
symbol's **actor isolation** — adding or removing `@MainActor`, or moving a
type onto/off a global actor. This matters because such a change is
**source-breaking under Swift 6** (a call site that previously called a
`nonisolated` member synchronously must now `await` it and hop actors) yet may
be invisible to a symbol-level diff, since global-actor isolation is a
source-level property and not part of a function's ABI or mangled signature.

**Analytical verdict (no build was run — see the note below).**

- **Nightly public-surface baseline** (`scripts/api-surface-baseline.sh`):
  **definite blind spot.** The baseline is keyed on the digester's
  `printedName`, which carries parameter *labels* but not types, and certainly
  not decl attributes like `@MainActor`. An isolation-only change leaves
  `printedName` byte-identical, so the normalized text diff shows zero drift.
  This follows directly from the script's own documented normalization (it
  filters to public decls and diffs `printedName`-keyed lines).

- **Per-PR breakage-diff gate**
  (`swift package diagnose-api-breaking-changes`, `ci.yml`): **very likely a
  blind spot, not confirmed.** The gate reports ABI/API *breakage*. Global-actor
  isolation does not change a symbol's ABI — a `@MainActor func` and a
  `nonisolated func` of the same signature mangle and link identically;
  isolation is enforced at the call site by the compiler at source level. The
  digester compares declarations by name and type, so an isolation-only change
  should produce no breakage finding. This is strong reasoning but not a
  certainty, because swift-api-digester's ABIRoot dump *may* record some
  isolation/`Sendable`-related fields whose change it could flag — that behavior
  is toolchain-version-dependent and must be observed, not assumed.

**Consequence for 1.0.** Treat actor-isolation changes on public symbols as
**not covered by automated gates** until proven otherwise. Until the experiment
below is run and the result recorded here, isolation changes are a **manual
review item**: any PR that adds/removes `@MainActor` or global-actor isolation
on a public symbol must call it out in its PR body, the same way a public-surface
addition already must be justified.

**Note:** this appendix was written analytically. The definitive check requires
running `swift package diagnose-api-breaking-changes`, which cannot run
concurrently with a build (it takes a package build lock and self-deadlocks), so
it was deferred rather than run inside an active test gate.

### Morning experiment (to confirm the verdict)

Run against a warm build cache, off any other build:

1. On a scratch branch, take a public symbol currently without isolation — e.g.
   a `public` method on a `public` type in `ManifoldContract` — and add
   `@MainActor` to it (or mark a `public final class` as `@MainActor`). Commit.
2. Run the per-PR gate exactly as CI does:
   `swift package diagnose-api-breaking-changes <parent-commit> --targets ManifoldContract --baseline-dir /tmp/apidiff`.
   Record whether it exits non-zero and whether it names the isolation change.
   *Expected: exit 0, no finding.*
3. Run `scripts/api-surface-baseline.sh --check --modules ManifoldContract`
   against the checked-in baseline. Record drift. *Expected: no drift.*
4. Directly inspect the digester's raw dump for the symbol: grep the JSON under
   `/tmp/apidiff/<hash>/ManifoldContract.json` for `MainActor`, `isolation`,
   `actor`, and `Sendable` on the changed declaration, before and after. This
   answers definitively whether the digester even *records* isolation — the
   root question behind steps 2–3.
5. Repeat step 4 for a `Sendable`-conformance change on a public type (add, then
   remove `: Sendable`), which is a distinct case from global-actor isolation and
   may behave differently in the dump.

Record the observed results back into this appendix, and — if confirmed blind —
add "actor-isolation / `Sendable` changes on public symbols" to the standing
manual-review checklist for 1.0, or build a small `swiftinterface`-scanning
tripwire that greps emitted `.swiftinterface` files for isolation-attribute
drift (the `.swiftinterface` text *does* print `@MainActor`, unlike the digester
dump — a promising cheap enforcement path worth measuring).
