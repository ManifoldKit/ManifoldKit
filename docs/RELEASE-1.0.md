# Toward 1.0 — release criteria and the post-1.0 policies

**Audience:** contributor
**Status:** living

> **Status: accepted 2026-07-16.** This document has two halves. The first —
> *1.0 release criteria* — enumerates what the `1.0.0` freeze actually covers,
> and is a factual description of the current stability program. The second —
> *Post-1.0 policies* — is five policies that are now **decided project
> policy**, ruled on in
> [issue #2211](https://github.com/ManifoldKit/ManifoldKit/issues/2211).
> Each retains the alternative that was considered and why it was rejected, so
> the reasoning survives the decision.
>
> **The two policy decisions that were open are now settled; release
> qualification is not.**
> [Appendix A](#appendix-a--api-digester-isolation-change-blind-spot)'s
> isolation-change blind spot was closed at type level 2026-07-21: the
> normalizer now emits conformance and filtered-attribute signal, so an
> isolation/`Sendable` change on a public type shows up as baseline drift
> instead of silently passing. (Member-level isolation changes and two narrow
> edges remain documented manual review items — see the Appendix A resolution.)
> Policy 2's two sub-questions were ruled on separately — "what counts as a
> critical fix" on 2026-07-16 (narrow: security + data-loss/corruption only),
> and "how a fix reaches the 1.x line" on 2026-07-21, via
> [Appendix B](#appendix-b--1x-maintenance-branch-runbook)'s runbook. See each
> section for the resolution. Those decisions do **not** establish that the
> C.2 stable-tier seal or a current release is qualified. Read
> [Release health](#release-health--qualification-ledger) for dated blockers
> and the exact evidence required before making a Tier 1/2 release claim.
>
> **Issue #2211 remains open.** Policies 1–5 below are decided. The later
> proposal for a sixth policy — separate stable and continuous qualification
> channels — has not been adopted. The operational ledger below records
> current evidence without silently deciding that policy.

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
consequential was that neither gate reliably detected an actor-isolation change
(adding `@MainActor` to a public symbol), which is source-breaking under Swift 6
but is not an ABI property. That gap is now closed at type level (2026-07-21):
the public-surface baseline emits conformance and filtered-attribute signal, so
an isolation/`Sendable` change on a public type registers as drift. Member-level
changes and two narrow edges remain manual review items — see Appendix A's
resolution for the honest residual list.

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
1.0. Independent versioning does not waive release evidence: every registered
companion, eval, or apps consumer still needs a real canary before its
integration is claimed as qualified; the current blockers are in
[Release health](#release-health--qualification-ledger).

### 6. Performance

Performance is measured nightly and is mostly non-gating: the one asserted
threshold is a streaming-cadence regression tripwire
(`IntegratedStreamingPerformanceTests`, which fails only on a *profoundly*
broken cadence, not on baseline drift). Per **Policy 5** below, performance is
**not a versioned property** of 1.0: a perf regression is a bug to fix, never a
breaking change requiring a major. Published, provenance-pinned local-inference
baselines (Ollama HTTP spine, load/prefill/decode split) live under
[`docs/perf/`](perf/PERFORMANCE.md) — see #2335; companion server lanes remain
gated on [#2245](https://github.com/ManifoldKit/ManifoldKit/issues/2245).

### Semver-exempt and Experimental products (unchanged by 1.0)

Four developer-tooling products stay outside the semver promise even after 1.0,
exactly as documented in [`API-DESIGN.md` § 7](API-DESIGN.md):
`ManifoldTestSupport`, `ManifoldPersistenceTestSupport`,
`ManifoldBackendTestKit`, and `ManifoldTools`. They may break in any minor with
a migration note. 1.0 does not change their status; this section exists so the
exemption is visible from the freeze document, not only from the API design
page.

The five zero-adopter Experimental products
([`API-DESIGN.md` § 7b](API-DESIGN.md#7b-experimental-products-declared-2026-07-13-v1-rationalisation-plan-phase-c)
— `ManifoldMCP`, `ManifoldMCPHost`, `ManifoldAppIntents`, `ManifoldAgentInstructions`,
`ManifoldTelemetryOTLP`) are
outside the freeze for the same reason, until each graduates on a real
adopter. `ManifoldAppEval` graduated out of this roster 2026-08-09 on two
real adopters — fireside and idlewick — see
[`docs/PRODUCTION-READINESS.md`](PRODUCTION-READINESS.md) Tier 2. **This
"1.0 release criteria" section covers what freezes; it does
not enumerate what doesn't** — [`docs/PRODUCTION-READINESS.md`](PRODUCTION-READINESS.md)
is the complete tier assignment (audit-enforced for every `.library`
product) for every published product, this section's two exempt groups
included, and is the page to check before
assuming a product is covered by the 1.0 promise. A tier assignment is not a
current-release approval: qualification blockers can withhold a scoped Tier
1/2 claim without changing the compatibility roster.

---

## Release health — qualification ledger

**Dated:** 2026-08-16. This is the current-release qualification ledger for
Tier 1 and Tier 2 promises. It is deliberately separate from
[`PRODUCTION-READINESS.md`](PRODUCTION-READINESS.md), which assigns a product's
**compatibility tier**. A tier says what compatibility commitment the project
assigns to the surface; it does not certify that every release gate for that
commitment is presently evidenced.

**Release rule.** A release may describe a Tier 1/2 capability as qualified
only when its row below is clear with the stated evidence. An open row is an
operational demotion of the affected promise for the current release: either
fix it and record the evidence, or explicitly remove that promise from the
release claim. A passing unit suite, declared CI route, or old green run is not
a substitute for the evidence named here.

### Tier 1/2 blockers

| Order | Scope affected | Blocker | Evidence required to clear |
|---:|---|---|---|
| 1 | Tier 1 bootstrap recipe and Tier 2 `ManifoldUIModelManagement` endpoint configuration | [#2476](https://github.com/ManifoldKit/ManifoldKit/issues/2476) is **blocked**: the canonical ancestor `endpointStore` injection yields `nil` in `ChatView`'s configuration sheet. | An Example/integration test presents the real configuration content and proves it receives a usable store; the canonical recipe and runnable example use that verified wiring; and CI executes the test. A compile-only snippet is insufficient. |
| 2 | Tier 1 cold-start release gate | [#2423](https://github.com/ManifoldKit/ManifoldKit/issues/2423) is **blocked**: `cold-start-human` can restore a stale main-scoped cache and report diagnostics not reproducible from source. | A PR run records either a current-generation cache hit or intentional cold miss, including cache `createdAt`/key provenance; no multi-week-old restored build directory is accepted; and the `llama`/`ManifoldLlama` diagnostic divergence is rechecked from the corrected run. |
| 3 | Tier 1 `ManifoldContract`; every Tier 2 backend | [#2409](https://github.com/ManifoldKit/ManifoldKit/issues/2409) is **blocked**: cancellation and immediate reuse have no shared, non-vacuous contract tripwire. | `BackendContractChecks` proves a generation is in flight before cancelling, then asserts synchronous `isGenerating == false` and successful immediate reuse; its test demonstrably fails on a known violating backend; and every in-tree backend passes or publishes a deliberate deviation. |
| 4 | Tier 2 `ManifoldOllama`; terminal-turn behaviour in Tier 1 Runtime/UI | [#2376](https://github.com/ManifoldKit/ManifoldKit/issues/2376) remains **unqualified**: bounded production mitigations now include a five-minute stream-idle timeout, terminal drain, and visible diagnostics, but the reported live iOS Ollama tool-continuation path has no terminal-state evidence. | A regression test drives an Ollama tool round-trip to a terminal state, and a real iOS-simulator/Ollama CI or release-gate run records either a completed continuation or the explicit bounded error. If request shape is causal, pin it with a request-body test; a runner timeout is failure. |

The rows are in the approved remediation sequence, not severity: rows 1–2 are
the first parallel lane, followed by rows 3–4. A release cannot skip an
unresolved blocker by calling a later canary green.

### Release-context gates after the blockers

| Order | Gate | Current state and evidence required to clear |
|---:|---|---|
| 5 | [PR #2462](https://github.com/ManifoldKit/ManifoldKit/pull/2462), migration-index and companion-canary gates | **Not qualified.** Its local/demonstrated-red evidence does not cover either release-context gate. A legitimate Release Please candidate — never a synthetic version bump — must run both gates in CI. Retain links to successful migration-index and dispatched-companion logs, including the release-context decision and checked head. |
| 6 | [#2477](https://github.com/ManifoldKit/ManifoldKit/issues/2477), companion/eval/apps registry | **Blocked.** Dispatch, pre-release gating, and prose use different hard-coded lists; eval is dispatched but not pre-release-gated. One checked-in registry must source dispatch, canary enumeration, pin/freshness checks, and generated or validated documentation. An audit must fail when a consumer is omitted or duplicated. |
| 7 | Eval core-main canary | **Pending after #2477.** `manifold-eval` must not count merely because it receives a dispatch. Its registry-derived entry must run against core main/release candidate, return a terminal CI conclusion, and be consumed by the release gate. |
| 8 | Bespoke apps canary | **Pending after eval.** The apps integration cannot use the SwiftPM-only companion workflow unchanged. A real apps-specific workflow must exercise the supported integration against core main/release candidate, return a terminal CI conclusion, and be registry-derived and release-gated. |

### Demonstration program remains future work

Issue [#2453](https://github.com/ManifoldKit/ManifoldKit/issues/2453) is not
closed by this ledger or by the two canaries. Its M1–M5 remain future work: M1
shrink, M2 local inference, M3 headless/long-tail vehicles, M4 deliberate
macOS coverage, and M5 a blocking freshness/staleness ratchet. M0 is the
shipped instrument only. The canaries can contribute evidence; they do not
replace the milestone gates.

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

> **Both sub-questions left open by the 2026-07-16 ruling are now settled.**
> The accepted decision was the *shape* — deprecate-in-minor, remove-in-next-major,
> six-month tail. Two things it did not settle at the time:
>
> - **What "critical fix" includes.** Decided 2026-07-16 (same ruling comment
>   as the shape, settled slightly after the policy text above was first
>   written): the narrow reading — security and data-loss/corruption fixes
>   only. Ordinary bugs do not qualify for a 1.x backport once `main` has moved
>   to 2.0; they are fixed on `main` only. This is what keeps the six-month
>   tail a bounded, solo-maintainer-sustainable commitment rather than an
>   open-ended one.
> - **How a fix reaches the 1.x line** once `main` has moved to 2.0. Resolved
>   2026-07-21 by [Appendix B](#appendix-b--1x-maintenance-branch-runbook): a
>   decided-but-dormant `release/1.x` branch runbook — cherry-pick from
>   `main`, never branch-only, with the release mechanics and CI caveats
>   spelled out there.
>
> The six-month tail is the only clause here obliging labor *after* attention
> has moved to the next major, which is why these were worth settling before
> 1.0 rather than at the first 1.x security report.

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
`.upToNextMinor` pin plus a qualifying compat canary express and enforce this).
A companion may sit at `0.x` against a `1.x` core, or reach `1.0` before core
does; the only contract between them is the declared core range and a verified
green canary for every registry participant. Rationale: the packages were split precisely so a heavy GPU/native
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

**Published baseline (archived artifacts).** Committed, provenance-pinned
numbers live under [`docs/perf/`](perf/PERFORMANCE.md) (#2335) — raw
`BenchResult` JSON, human matrix, and advisory regression thresholds. The
schema and driver stay in [manifold-eval](https://github.com/ManifoldKit/manifold-eval);
core only archives what the evaluator produced. HTTP-spine memory / cancel /
MK-server lanes remain deferred on
[#2245](https://github.com/ManifoldKit/ManifoldKit/issues/2245). Thresholds are
investigation triggers, not semver events — consistent with this policy.

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

**Consequence for 1.0 (historical — see Resolution below).** Actor-isolation
and `Sendable`-conformance changes on public symbols were **not covered by
either automated gate**, confirmed rather than inferred. Until closed, the
project treated this as a **manual review item**: any PR that adds/removes
`@MainActor`, `nonisolated`, or `Sendable` on a public symbol had to call it
out in its PR body, the same way a public-surface addition already must be
justified. The fix, if ever prioritized, was narrow and data-already-exists:
teach `api-surface-extract.py` to also emit a `declAttributes`/`conformances`
line per type — the raw digester dump already carries the signal, only the
normalizer discarded it. (`.swiftinterface` text is a second, independent path
worth measuring — it does print `@MainActor` in source form — but wasn't
exercised in this experiment.)

### Resolution (closed 2026-07-21)

The blind spot named above is closed. `scripts/_lib/api-surface-extract.py`
now emits two additional deterministic line kinds per public `TypeDecl`,
alongside the existing `<Qualified> <declKind>` line:

- `<Qualified> conformances: A,B,C` — the type's `conformances` array
  (sorted, comma-joined), when non-empty. Adding `@MainActor` or an explicit
  `Sendable` both extend this list (`Sendable`, `SendableMetatype`), so both
  now register as baseline drift — an addition line for the new conformance
  names.
- `<Qualified> attrs: X,Y` — a **filtered** view of the type's
  `declAttributes`, when the filtered list is non-empty. `@MainActor` shows up
  as the raw digester's generic `"Custom"` marker (it does not name which
  attribute), so an `attrs: Custom` line appearing is the isolation signal
  itself, not just a proxy for it.

The filter (a denylist, applied before the `attrs:` line is emitted) excludes
attributes that vary with doc comments or the digester's own internal
bookkeeping rather than with a source-visible API change — chosen empirically
against a real `ManifoldContract` dump (2026-07-21) rather than assumed. See
the module docstring in `api-surface-extract.py` for the exact denylist and
the dump evidence behind each entry, in the same style as the existing
`isInternal`/`spi_group_names` notes.

Member-level isolation changes (`@MainActor` on one public method rather than
the whole type) are addressed per the empirical finding recorded in the same
docstring — see there for whether member-level `declAttributes` were clean
enough to emit, or whether type-level remains the accepted minimum.

Coverage added: `Tests/APIFreezeTests/PublicSurfaceBaselineTests.swift` gained
fixture-driven tests reproducing this Appendix's three probe states (plain
public struct / `@MainActor` / explicit `Sendable`-only) as minimal ABIRoot
JSON fixtures under `Tests/APIFreezeTests/Fixtures/`, asserting the normalizer
now produces three distinct outputs. All 29 checked-in baselines were
regenerated against the new normalizer (`scripts/api-surface-baseline.sh`) as
part of the same change.

Residual gaps, stated rather than implied (the docstring carries the full
evidence): member-level isolation changes (too noisy to emit — ~8× line growth
for a marker that cannot distinguish `@MainActor` from any other custom
attribute); an authored `@preconcurrency` change (masked by the same denylist
entry that suppresses 55 compiler-inferred occurrences); and `@MainActor`
*removal* on a type that is Sendable-by-members and carries a second
Custom-marked attribute. All three are manual review items — narrower than the
original Appendix A scope, not zero.

---

## Appendix B — 1.x maintenance-branch runbook

Resolves Policy 2's second open sub-question: once `main` moves past a 2.0
breaking-change wave, how does a critical fix (per the 2026-07-16 ruling:
security or data-loss/corruption only — see Policy 2 above) reach a consumer
still pinned to the 1.x line, during the six-month support tail? This is a
**decided-but-dormant procedure** — written down now, before it's needed under
pressure, per the same reasoning that motivated settling it before 1.0. Cut
day is whenever the first 2.0-breaking `feat!:`/`BREAKING CHANGE:` lands on
`main`; nothing in this appendix executes before then.

### Trigger

Cut `release/1.x` from the last 1.x tag **the moment the first 2.0-breaking
change merges to `main`** — not before (there is nothing to protect yet) and
not later (every commit after that point diverges `main` from the last-known
1.x-compatible state). "Last 1.x tag" is whatever `.release-please-manifest.json`
recorded immediately before that merge; find it via `git log --oneline
.release-please-manifest.json` or the GitHub Releases page.

```bash
git fetch origin
git branch release/1.x <last-1.x-tag>   # e.g. v1.4.2
git push origin release/1.x
```

### Flow — fix on `main` first, cherry-pick back, never branch-only

A critical fix is developed and merged to `main` exactly like any other PR —
same review loop, same CI gate, same conventions. Once merged there, it is
cherry-picked onto `release/1.x`:

```bash
git fetch origin
git checkout -b fix/1.x-cherry-pick-<short-desc> origin/release/1.x
git cherry-pick <main-commit-sha>
# resolve conflicts if 2.0 refactored the surrounding code — the fix's
# *behavior*, not its diff, is what must land on 1.x
git push -u origin fix/1.x-cherry-pick-<short-desc>
gh pr create --base release/1.x --title "fix: <same summary as the main PR>" --body "Cherry-pick of <main-commit-sha> for the 1.x maintenance line. Refs #<issue>."
```

Never develop the fix branch-only against `release/1.x` — `main` is always
first, so the 2.0 line never regresses on a bug 1.x already fixed. If the fix
doesn't apply to `main` at all (the bug was introduced by the 2.0 break
itself), it isn't a 1.x maintenance fix — it's an ordinary `main` bug fix.

### Release mechanics

**Feasibility check performed 2026-07-21** (read `release-please-config.json`
and every workflow that references `release-please`, per this repo's shared
convention that release automation lives in `ManifoldKit/.github` and is
consumed here — see [`mk-compat-bump-deps-convention`
memory / AGENTS.md § Release workflow]): today's automation does **not**
support a second target branch.

- `.github/workflows/release-please.yml` triggers on `push: branches: [main]`
  only, and passes no `target-branch` input to `googleapis/release-please-action@…
  # v5` — the action defaults `target-branch` to the repository's default
  branch when the input is omitted. A push to `release/1.x` today fires no
  release-please run at all.
- `release-please-config.json` / `.release-please-manifest.json` describe a
  single package (`"."`) with a single version state — there is no
  second manifest scoped to a maintenance branch.
- `release-please-action` v5 *does* support a `target-branch` input in
  general (it is part of the underlying `release-please` CLI's contract), so
  wiring a second branch is possible in principle — but doing so is a change
  to shared release automation, which this PR is explicitly scoped not to
  make (see the task that produced this appendix). Standing it up (a second
  workflow trigger on `release/1.x`, a `target-branch: release/1.x` input, and
  a second manifest/config pair, or equivalent) is future work for whoever
  cuts `release/1.x` for real.

**Mechanism to use as configured today: hand-tagged `1.x.y`.** Until the
automation is extended, cut a 1.x release manually:

```bash
git checkout release/1.x
git pull origin release/1.x
# Update CHANGELOG.md by hand (Prisma-style Highlights format, same as any
# release — see AGENTS.md § Release workflow) and bump version.txt.
git add CHANGELOG.md version.txt
git commit -m "chore(release): 1.4.3"
git tag -a v1.4.3 -m "v1.4.3"
git push origin release/1.x v1.4.3
gh release create v1.4.3 --target release/1.x --notes-file <(sed -n '/## \[1.4.3\]/,/## \[/p' CHANGELOG.md | sed '$d')
```

Re-evaluate the target-branch approach before the first real 1.x maintenance
release ships, if wiring it up by then looks cheaper than the hand-tag path
above — this appendix does not forbid extending the automation later, only
declines to do it in the PR that first documents the runbook.

### CI

**As configured today, a PR against `release/1.x` would not trigger the full
gate.** `ci.yml`'s `pull_request` trigger is `branches: [main]` (and its
`push` trigger the same); a PR whose base is `release/1.x` matches neither
filter, so none of `ci.yml`'s jobs would run. This is a real gap the cut-day
procedure must handle, not a claim that it's already covered:

- **Cut-day step:** when `release/1.x` is created, add it to `ci.yml`'s
  `pull_request.branches` and `push.branches` lists in a small, reviewed PR
  against `main` (a workflow-file change, so it needs its own review — this
  is exactly the kind of change this current PR is scoped not to make
  pre-emptively, since the branch doesn't exist yet and an untested trigger
  addition is unverifiable today).
- Until that lands, a maintenance-branch PR's safety net is running the full
  local gate by hand (`scripts/test.sh --profile local`) before merging —
  the same discipline the Draft-PR review loop already asks of every PR,
  just without CI's automated confirmation.

### Scope

Critical fixes only, per Policy 2's now-decided sub-question: **security, and
data-loss/corruption bugs.** Ordinary bugs, performance regressions, and
feature requests are not eligible for a 1.x backport — they land on `main`
only. This is what keeps the six-month tail affordable for a solo maintainer;
widening scope here would silently re-open the "tiered support" alternative
Policy 2 already rejected.

### End-of-life

Six months after `2.0.0` ships. The exact EOL date is **recorded in this
appendix, in a dated addendum, on the day `2.0.0` releases** — not computed
ad hoc later, so a consumer reading this document always finds a concrete
date rather than a relative one that drifts with when they happen to read it.
(No such addendum exists yet, because no 2.0 release has shipped as of this
writing.)
