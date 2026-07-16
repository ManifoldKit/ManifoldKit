# Toward 1.0 — release criteria and the post-1.0 policies

> **Status: accepted 2026-07-16.** This document has two halves. The first —
> *1.0 release criteria* — enumerates what the `1.0.0` freeze actually covers,
> and is a factual description of the current stability program. The second —
> *Post-1.0 policies* — is five policies that are now **decided project
> policy**, ruled on in
> [issue #2211](https://github.com/ManifoldKit/ManifoldKit/issues/2211).
> Each retains the alternative that was considered and why it was rejected, so
> the reasoning survives the decision.
>
> **Two things remain open, and are marked as such wherever they appear** — a
> reader should never have to guess which text is a ruling and which is not:
> [Appendix A](#appendix-a--api-digester-isolation-change-blind-spot)'s
> isolation-change blind spot (a confirmed gap in the API-freeze tooling, not a
> policy question), and Policy 2's two sub-questions (what "critical fix"
> includes, and how a fix reaches the 1.x line). Both need settling before 1.0.

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
property — lightweight-only within a major — is **Policy 3** below, now decided
and enforced by `ManifoldMigrationPlanLightweightAuditTest`.

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
ships a new major OS. Per **Policy 1** below, a floor bump is a **minor**
release, announced one release ahead in the changelog: platform floors sit
outside the API stability promise.

### 5. Companion independence

The heavy local-inference families live in companion packages
([`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx),
[`manifold-llama`](https://github.com/ManifoldKit/manifold-llama)) that depend
on this package's `ManifoldInference` from their own repos, pin it with
`.upToNextMinor`, and run a compat canary ([`COMPANION-BACKENDS.md`
§ 4](COMPANION-BACKENDS.md)). Per **Policy 4** below, core and companions
version **independently**: core 1.0 neither waits for nor drags a companion to
1.0.

### 6. Performance

Performance is measured nightly and is mostly non-gating: the one asserted
threshold is a streaming-cadence regression tripwire
(`IntegratedStreamingPerformanceTests`, which fails only on a *profoundly*
broken cadence, not on baseline drift). Per **Policy 5** below, performance is
**not a versioned property** of 1.0: a perf regression is a bug to fix, never a
breaking change requiring a major.

### Semver-exempt products (unchanged by 1.0)

Four developer-tooling products stay outside the semver promise even after 1.0,
exactly as documented in [`API-DESIGN.md` § 7](API-DESIGN.md):
`ManifoldTestSupport`, `ManifoldPersistenceTestSupport`,
`ManifoldBackendTestKit`, and `ManifoldTools`. They may break in any minor with
a migration note. 1.0 does not change their status; this section exists so the
exemption is visible from the freeze document, not only from the API design
page.

---

## Part 2 — Post-1.0 policies (decided)

All five policies below were accepted on 2026-07-16 (#2211). Each states its
context, the policy and its rationale, and the main alternative with why it was
rejected — the alternatives are kept deliberately, so a future reader
re-litigating a decision finds the reasoning rather than re-deriving it. The
policies are modest and solo-maintainer-sustainable by design: a policy that
assumes a release team this project does not have would be a policy nobody can
keep.

### Policy 1 — Platform-floor bumps vs semver

**Context.** The n-1 policy bumps deployment targets every September. Before
this ruling, nothing said whether raising the iOS/macOS floor forced a major
version — a question that detonates on a schedule, since the first post-1.0
September bump arrives about twelve months after 1.0 and would otherwise have
been decided under pressure.

**Policy.** Platform floors are **outside** the API stability promise. A
September floor bump is a **minor** release, announced one release ahead in the
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

**Obligation (manual — no tripwire).** No gate can know a September bump is
coming, so the one-release-ahead announcement is hand-kept. It is written into
the release workflow as *Platform-floor release-notes discipline*
([`AGENTS.md` § Release workflow](../AGENTS.md)), alongside the existing
capability-field callout it is modelled on — so the obligation lives in the
process a releaser actually reads, not only in this document.

### Policy 2 — Deprecation window and support policy

**Context.** [`API-DESIGN.md` § 4](API-DESIGN.md) defers deprecation to
"post-1.0" but never defined the window: how long a deprecated symbol survives,
and how long a shipped major receives fixes. Pre-1.0 the rule is *delete, don't
deprecate* — that changes at 1.0, when there is finally a stability promise to
protect with a migration runway. The window below is that missing definition.

**Policy (kept deliberately modest).** Deprecate in a minor, remove in the next
major. That gives every removed API at least one minor's worth of
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

**No tripwire.** Unlike Policy 3, nothing enforces this one: no gate can tell
that a removal skipped its deprecation minor, and none can notice a support tail
quietly lapsing. Both halves are kept by hand. Policy 1 carries the same caveat;
it is recorded here for the same reason.

> **Open sub-question — not part of the 2026-07-16 ruling.** The accepted
> decision is the *shape* — deprecate-in-minor, remove-in-next-major, six-month
> tail. Two things it does not settle, flagged rather than assumed:
>
> - **What "critical fix" includes.** The narrow reading (security and
>   data-loss/corruption only) is what makes the tail keepable; a reading that
>   includes ordinary bugs is a materially larger commitment. Undecided.
> - **How a fix reaches the 1.x line** once `main` has moved to 2.0. This
>   implies some maintenance-branch-shaped process, which **does not exist
>   today** and would be a real operational cost to stand up.
>
> The six-month tail is the only clause here obliging labor *after* attention
> has moved to the next major, which is why these are worth settling before 1.0
> rather than at the first 1.x security report.

### Policy 3 — SwiftData schema-stability promise

**Context.** Practice is already clean: every stage in `ManifoldMigrationPlan`
is `.lightweight`, each with a read-back test, so no store has ever needed a
destructive migration. What was missing was a forward-looking promise — and,
per Principle 4, a tripwire shipped alongside it.

**Policy.** **Lightweight-only within a major.** Any schema change
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

**Tripwire (shipped in this PR).**
`ManifoldMigrationPlanLightweightAuditTest`
(`Tests/ManifoldPersistenceSwiftDataTests/ManifoldMigrationPlanLightweightAuditTest.swift`)
walks `ManifoldMigrationPlan.stages` and fails if any stage's
`String(describing:)` does not start with `"lightweight("`. `MigrationStage`
has no public case-introspection API, so this string-prefix comparison
(rather than a `switch`/pattern-match, which isn't available across every
SDK version) is the practical way to distinguish `.lightweight(...)` from
`.custom(...)` — SwiftData ships exactly those two cases today, so failing
the prefix match means the stage is a `.custom` (destructive-capable) stage.
Sabotage-verified: temporarily changing a stage to `.custom(fromVersion:toVersion:willMigrate:didMigrate:)`
made the test fail with a message pointing at this policy; reverting restored
a clean `git diff` and a passing test.

Note the tripwire's one fragility: because it matches on `String(describing:)`,
an SDK that changes `MigrationStage`'s description format would break the
detection rather than the invariant. That is an accepted trade — SwiftData
exposes no public case introspection — but it means the audit's own failure
message is worth reading before assuming a real violation.

### Policy 4 — Core ↔ companion 1.0 semantics

**Context.** The pin lifecycle and compat canary between core and the companion
backend packages are documented ([`COMPANION-BACKENDS.md`
§ 4](COMPANION-BACKENDS.md)), but did not say what "companion 1.0" means
relative to "core 1.0." A naive reading couples them — core cannot reach 1.0
until the companions do, or vice versa.

**Policy.** **Independent versioning.** Core 1.0 neither waits for nor
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

### Policy 5 — Performance as a 1.0 property

**Context.** Performance is nightly-measured and mostly non-gating: one asserted
streaming-cadence tripwire, everything else baseline-tracked without a hard
threshold. A 1.0 announcement could be read as promising perf stability the same
way it promises API stability.

**Policy.** Performance is **explicitly outside the semver contract.** A
perf regression is a bug to be fixed, not a breaking change requiring a major.
Keep the streaming-cadence tripwire and the nightly perf suites as regression
detectors; Part 1 § 6 states in one sentence that perf is not versioned.
Rationale: perf on-device is a function of model, hardware, and OS as much as of
this code, so a hard perf-semver promise would be one the project cannot honestly
keep across the device matrix it runs on. Documenting the tripwire's existence
gives consumers the honest guarantee — regressions are caught and fixed — without
overclaiming a numeric contract.

**Alternative considered — perf budgets in the semver contract (a named
regression is a breaking change).** Rejected: attractive in principle, but it
requires stable per-device baselines the nightly-only, hardware-variable setup
cannot provide, so the promise would be routinely false.

---

## Appendix A — API-digester isolation-change blind spot

Issue #2211 asks whether the API-freeze tooling detects a change to a public
symbol's **actor isolation** — adding or removing `@MainActor`, or moving a
type onto/off a global actor. This matters because such a change is
**source-breaking under Swift 6** (a call site that previously called a
`nonisolated` member synchronously must now `await` it and hop actors) yet may
be invisible to a symbol-level diff, since global-actor isolation is a
source-level property and not part of a function's ABI or mangled signature.

**Confirmed verdict (empirically verified 2026-07-12 — both gates blind).**

The experiment below was run against a scratch public type
(`ScratchIsolationProbe`, a throwaway `public struct` added to and then
removed from `ManifoldContract`) so the before/after diff is real rather than
inferred:

1. Added `public struct ScratchIsolationProbe { public var value: Int; public
   init(value: Int) { … }; public func double() -> Int { … } }` — no
   isolation, no explicit `Sendable`.
2. Snapshotted that state with `git stash create` and dumped
   `ManifoldContract`'s digester JSON (the "before" side).
3. Edited the struct to `@MainActor public struct ScratchIsolationProbe`,
   snapshotted again, dumped again (the "after" side).
4. Ran the exact per-PR-shaped command,
   `swift package diagnose-api-breaking-changes <before-snapshot> --targets ManifoldContract --baseline-dir …`,
   comparing the unisolated "before" against the `@MainActor`-isolated
   working tree.
5. Repeated steps 1–4 for an explicit `Sendable`-conformance-only change
   (`public struct ScratchIsolationProbe: Sendable`, no `@MainActor`) as a
   distinct case.
6. Deleted the scratch file; confirmed `git status` clean and `swift build`
   green afterward.

**Findings:**

- **Per-PR breakage-diff gate** (`swift package diagnose-api-breaking-changes`,
  `ci.yml`): **confirmed blind spot.** Step 4's command printed `No breaking
  changes detected in ManifoldContract` for both the `@MainActor` addition and
  the explicit `Sendable` addition. Neither isolation-only change registers as
  breakage.
- **Nightly public-surface baseline** (`scripts/api-surface-baseline.sh`):
  **confirmed blind spot, and the raw digester dump is not itself blind** —
  this is the more precise finding. The raw ABIRoot JSON for
  `ScratchIsolationProbe` genuinely changes: adding `@MainActor` adds
  `"declAttributes": ["Custom"]` (a generic "has some custom attribute"
  marker, not naming which) and extends `conformances` with the implicit
  `Sendable` + `SendableMetatype` the actor isolation grants; adding explicit
  `: Sendable` alone adds the same two conformance entries without the
  `declAttributes` marker. But `scripts/_lib/api-surface-extract.py` — the
  normalizer that produces the checked-in baseline text CI actually diffs —
  reads only `declKind` for a type and `printedName` + `declKind` for its
  members. It never reads `declAttributes` or `conformances`. Confirmed by
  running the normalizer directly on both dumps: the emitted line for the type
  is `ScratchIsolationProbe Struct` in every one of the three states (no
  isolation, `@MainActor`, explicit `Sendable`) — byte-identical, zero drift.

**Consequence for 1.0.** Actor-isolation and `Sendable`-conformance changes on
public symbols are **not covered by either automated gate**, confirmed rather
than inferred. Until closed, treat this as a **manual review item**: any PR
that adds/removes `@MainActor`, `nonisolated`, or `Sendable` on a public
symbol must call it out in its PR body, the same way a public-surface addition
already must be justified. The fix, if ever prioritized, is narrow and
data-already-exists: teach `api-surface-extract.py` to also emit a
`declAttributes`/`conformances` line per type — the raw digester dump already
carries the signal, only the normalizer discards it. (`.swiftinterface`
text is a second, independent path worth measuring — it does print
`@MainActor` in source form — but wasn't exercised in this experiment.)
