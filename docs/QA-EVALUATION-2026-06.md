# ManifoldKit Evaluation — Architecture, QA, DX, Economics (June 2026)

**Date:** 2026-06-07 · **Method:** principle-driven, evidence-first audit (see [`QA-EVALUATION-PROCESS.md`](QA-EVALUATION-PROCESS.md)) · **Rubric:** [`TESTING-CI-PRINCIPLES.md`](TESTING-CI-PRINCIPLES.md)

Every finding is anchored to `file:line`. Findings are evidence-cited from a single-pass sweep; the cross-dimension reconciliations (e.g. the API-breakage gate) were adversarially confirmed — treat un-reconciled findings as high-but-not-certain confidence until verified.

## Headline

**The deductive and adversarial core is genuinely strong; the systemic gap is self-instrumentation.** ManifoldKit proves correctness well (owned seams, exhaustive switch funnel, audit-test discipline, a real fuzz harness, regression-encoding as habit) but does not *measure* its own quality or cost: no mutation score, no flake-rate / time-to-green / re-run-tax telemetry. The principles it espouses in `TESTING-CI-PRINCIPLES.md` §10/§16 are written but not mechanically emitted. Secondary theme: **doctrine lags implementation** — `CLAUDE.md`'s caching/batching narrative and several doc/CI paths have drifted from the shipped workflows and a past file move.

## Scorecard

| Dimension | Principle | Verdict | Anchor |
|---|---|---|---|
| **Architecture** | Switch exhaustiveness (P2/P3) | CONFORMS | `GenerationStreamConsumer.swift:17-77` (exhaustive funnel); 1 gap `GenerationToolDispatchLoop.swift:221` |
| | Module boundaries: compiler vs lint (P3) | PARTIAL | UI edges already deductive `Package.swift:520-523`; lints `ci.yml:258-270` redundant; framework-isolation lints necessary |
| | Illegal states unrepresentable (P3) | PARTIAL | non-negative-`Int` guards `PromptSlot.swift:316`, `RedirectGuardDelegate.swift:83` → `UInt`/value type |
| | Force-unwrap posture (P3) | PARTIAL | lint real `ci.yml:325`; **whole-file** allowlist trusts future edits `lint-no-new-force-unwraps.sh:80` |
| | Public API as contract (P5) | PARTIAL | live gate **3 of ~24 targets** `ci.yml:385-402`; richer test dormant `PublicAPIStabilityTest.swift:36` |
| | `@testable` vs plain import (P5) | PARTIAL | 584/649 `@testable`; plain-import slice exists `APIFreezeTests/PublicSurfaceTests.swift:16` |
| | Owned seams (P15) | CONFORMS | `ClaudeBackend.swift:49`, `MockURLProtocol.swift:23`, `MLXModelContainerProtocol.swift:62`; no foreign-type mocks |
| | Cold-start consumability (P14) | CONFORMS | tiers 1-4 `ci.yml:792-877`; gap: only umbrella+UI products |
| | Ownership topology (A1) | CONFORMS | `Exports.swift:16-29`; gates only at consumer→family edges `Package.swift:466-503` |
| **QA** | Determinism / hermeticity (P6) | CONFORMS | `UserDefaultsStandardAuditTest.swift:63`, `TrafficBoundaryAuditTest`; minor: 170 `Task.sleep` in tests |
| | Trust / signal integrity (P7) | CONFORMS | `withKnownIssue`=0; `TestSuiteSilentSkipAuditTest`; durable analog = `AuditSabotageSuiteTests.swift` |
| | Discovered-space / regression (P13) | CONFORMS | 200 `#NNN` refs; `KVCacheReuseRaceRegressionTests.swift:9-15`; pinning labeled |
| | Tiering by value-of-info (P8) | PARTIAL | excellent speed-tiering; turn loop per-PR golden `ci.yml:522`; placement **cost-justified, not severity-ranked** |
| | Change-confidence measured (P10) | **GAP** | **no mutation testing**; coverage lagging nightly floor 10pp low, 4/~20 modules `check-coverage.sh:20-25` |
| | Adversarial verification (P4) | CONFORMS | TLS/DNS/sanitizer/MCP suites + fuzz harness (7×16); caveats below |
| | Self-instrumentation (P16) | **GAP** | metrics named `TESTING-CI-PRINCIPLES.md:71` but **no collector**; 2.1× tax is anecdotal |
| **DX** | Feedback latency | PARTIAL | `--profile spike`/`--minimal` real `test.sh:260-425`; **no installed git hooks** |
| | Change-confidence, felt | CONFORMS | honest-summary tripwires `test.sh:603-611`; 19 audits + sabotage + cold-start (strongest DX axis) |
| | Cold-start / onboarding (P14) | PARTIAL | `quickStart()` `QuickStart.swift:78`; strong error `ManifoldKitError.swift:87`; **chat inert until model selected**; 3 broken doc links |
| | Docs as DX surface | PARTIAL | snippet-compile real `readme-snippets.yml`; **its own `paths:` filter references 2 missing files** |
| **Economics** | Batch sizing → interior optimum (P9) | PARTIAL | concurrency-cancel + path-filter shipped `ci.yml:53-126`; no upper-bound guard; doctrine stale |
| | Selective / affected testing | CONFORMS | Tier-0 resolver + Tier-2 exec `ci.yml:143-481`; FULL-fallback backstops |
| | Cost instrumentation (P16) | **GAP** (telemetry) | no billing/run-count tracking anywhere; dep-cache live `ci.yml:200-213` |
| | Commitment gradient / platform (P12) | PARTIAL | floor declared `Package.swift:25-27`, **no availability-floor audit**; API gate core-only |

**Adversarial caveats (P4 CONFORMS but):** GitHub Actions are tag-pinned not SHA-pinned (`maxim-lobanov/setup-xcode@v1`, `dorny/paths-filter@v4`); `dependency-review` is `continue-on-error: true` → fail-open (`lint.yml:281`); the fuzz harness has no automated cadence (`fuzz-weekly.yml:18-21`, schedule disabled).

## Cross-cutting themes

1. **Self-instrumentation is the one systemic GAP** — it surfaces in *both* QA (no flake / signal-to-noise / time-to-green) and Economics (no cost / re-run-tax telemetry). The metrics are named in the principles doc; nothing emits them. Highest-leverage cross-dimension fix.
2. **Change-confidence is asserted, not measured** — strong golden/characterization assets (turn-loop snapshots) but no mutation score or escaped-defect rate; coverage is a lagging nightly proxy.
3. **Doctrine/docs lag implementation** — `CLAUDE.md` still says "compiled-artifact caching ruled out" (dependency caching is in fact live and the real win) and frames "fewer/bigger PRs" as the dominant lever (concurrency-cancel + path-filter already shipped; the framing now steers toward over-batching). Plus a cluster of drift defects from the `ManifoldInference → ManifoldModelCatalog` file move: 3 broken doc links + a stale `readme-snippets.yml` path filter.
4. **CI's own supply chain is softer than the product's** — adversarial rigor is applied to runtime (TLS/DNS/sanitizers/fuzz) but the pipeline uses mutable action tags and a fail-open dependency check.
5. **The contract gate is real but narrow** — live for 3 core targets; the umbrella surface consumers actually `import` is unprotected, and a `fix:`/`feat:` can still drift a family target's surface.
6. **Severity-ranking is implicit** — tiering decisions are justified by billing, not by a documented risk matrix; some defect-detection (coverage, the sabotage audit) was demoted to nightly for cost, accepting a ≤24h blind window on a per-PR gate.

## Prioritized actions

Ranked by severity-weighted leverage (P8: risk-reduction per unit cost), not finding count.

### P0 — do first

**A1. Stand up QA + cost telemetry (closes the P16 gap in both QA and Economics).**
A scheduled 1×-billed ubuntu job querying `gh api` / the Actions API weekly for run-count, re-run ratio, time-to-green, and selective-vs-full outcomes, writing a committed trend file or step-summary. Converts the anecdotal 2.1× re-run tax into a standing signal and gives the §16 metrics a home. *Why #1:* the re-run tax is the largest premium-runner line item and is entirely un-instrumented; the fix is cheap and cross-cutting. *Evidence:* no collector found in `.github/` or `scripts/`; `TESTING-CI-PRINCIPLES.md:71`.

**A2. Widen the API-breakage gate beyond the 3 core targets.**
The live gate (`ci.yml:385-402`) digests only `ManifoldInference`/`Runtime`/`CloudCore`. Add the umbrella `ManifoldKit` surface (what consumers import) and family targets where the `llama` C-module issue can be sidestepped; optionally activate the dormant annotated `PublicAPIStabilityTest.swift` (its `SemVerBreak`/`feat!:` plumbing is already written) to mechanically link the version bump to the actual surface change. *Why:* a silent breaking change fans out irreversibly to every consumer (P5, P12).

### P1 — high value, low cost

**B1. Fix the docs/CI drift cluster + add a path-existence audit.**
Three reader-facing broken links to `ManifoldKitError.swift` (README.md:21, QUICKSTART.md:36/305 → actual `Sources/ManifoldModelCatalog/ManifoldKitError.swift`); the snippet gate's own `paths:` filter references two non-existent files (`readme-snippets.yml:40-41,57-58`) so error-rim changes can skip the gate; `CLAUDE.md`'s caching/batching narrative is stale. Add a CI audit asserting every literal `Sources/...` path in markdown and workflow YAML exists on disk (same self-validation discipline already used for cold-start scripts). *Why:* cheap, all real defects, all from one untracked file move; the path-filter hole is a silent self-disarming gate.

**B2. Pilot mutation testing on the turn loop + `ConversationRuntime` (closes P10).**
Even a one-off manual mutation run on the two highest-value deterministic modules produces a baseline mutation score — converting "fearless change" from aspiration to a measured deliverable. Pair with moving the coverage *no-regression delta* check onto per-PR for the 4 critical modules. *Evidence:* no mutation tooling exists; `check-coverage.sh` is nightly-only and 10pp below baseline.

**B3. Harden CI's own supply chain (P4).**
SHA-pin third-party Actions (at minimum `maxim-lobanov/setup-xcode`, `dorny/paths-filter`, `amannn/action-semantic-pull-request`) with Dependabot `github-actions`; enable the repo dependency graph and remove `continue-on-error` from `dependency-review` (`lint.yml:281`) to make it fail-closed.

### P2 — worth doing

**C1. Add an availability-floor audit (P12).** A lint over `Sources/` flagging `#available`/`@available` predicated above the declared `Package.swift:25-27` floor (outside OS-gated Foundation/Skills) — makes the n-1 policy compiler-truth, not prose.

**C2. Document a test-tier risk matrix (P8).** Map highest-risk paths (turn loop, streaming, persistence atomicity, supply chain) to required tiers and assert each has a *blocking per-PR* check; reconsider the nightly demotion of the sabotage-audit tripwire (a broken audit silently disarms a per-PR gate for ≤24h).

**C3. Architecture deduction conversions.** Line-anchor the force-unwrap allowlist (so trusted *files* don't become unaudited); replace non-negative-`Int` `precondition`s with `UInt`/value types; expand the `StreamAction` `default:` at `GenerationToolDispatchLoop.swift:221` to explicit cases.

**C4. Close the cold-start per-product/per-trait gap (P14).** A matrix cold-start job importing `ManifoldMCP`/`ManifoldVoice`/`ManifoldUIModelManagement`/`ManifoldServer` under their enabling traits.

**C5. DX loop + batch bounds.** Ship an opt-in `scripts/install-hooks.sh` (pre-push runs `--profile spike`) so the keystone fast-feedback loop isn't discipline-only; add an upper-bound to `CLAUDE.md`'s PR-size guidance so the EOQ curve is defended on both sides; reframe the "one call to chat" onboarding claim (chat is inert until a model is selected).

## What is already strong — do not "fix"

Owned seams (P15), ownership topology (A1), the exhaustive switch funnel, the audit-test + audit-sabotage discipline, regression-encoding as habit (P13), determinism tripwires (P6), and the adversarial runtime suites (P4) are all CONFORMS with strong evidence. The two UI-boundary lints are *redundant* with the compiler (fine as fast-feedback aids) — don't mistake them for the enforcement of record.
