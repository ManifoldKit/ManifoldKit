# Cross-repo simplification plan — 2026-07

Scope: ManifoldKit (core) · manifold-llama · manifold-mlx · manifold-eval · ManifoldKit/.github (org).
Goal: reduce duplication, fix drifted automation, and set the ecosystem up as a cohesive multi-repo
kit — executed as a batch of PR-sized work items that can run unattended overnight or over a work day.

Grounded in a five-agent survey (2026-07-02): per-repo audits of all four repos plus a cross-repo
infrastructure diff. Facts below were spot-verified where they drive a change (the mlx pin-rewrite
bug and the org `.github` contents were confirmed by hand; one survey claim — an mlx path-pin on
core — was found stale and discarded).

## Findings that drive the plan

1. **Live bug — manifold-mlx release automation is broken post-org-move.**
   `core-bump.yml:83`'s perl rewrite matches `roryford/ManifoldKit"` but `Package.swift` now pins
   `github.com/ManifoldKit/ManifoldKit`, so the automated pin bump silently no-ops.
   `canary.yml:30` also checks out `repository: roryford/ManifoldKit`. manifold-llama's copies are
   correct — the two repos' "identical" workflows have already drifted, which is the argument for
   consolidating them.
2. **Companion automation is copy-paste.** `core-bump.yml` (135 lines) and `canary.yml` (51 lines)
   are near-identical llama↔mlx; `release-please.yml` is byte-identical. manifold-eval has none of
   them — its exact core pin (`0.63.0`) requires a manual bump every core release (its README P5
   defers this). The org `.github` repo exists with only a `profile/` — shared reusable workflows
   can live there.
3. **Vendored data drifts silently.** `manifold-tools-llama` and `manifold-tools-mlx` hand-copy the
   same 9 scenario JSONs and an identical 8-file fixture tree from core
   (`Sources/ManifoldTools/Scenarios/built-in` + test fixtures); md5-identical today, no sync check.
4. **CLI harness boilerplate duplicated.** Both `manifold-tools-*` executables hand-roll arg
   parsing, scenario-runner wiring, and identical VL-model pre-flight guards
   (`preprocessor_config.json` etc.) — ~200–300 LOC per repo that belongs in core's `ManifoldTools`.
5. **Core scripts/ has internal duplication.** 40 scripts / ~8.2k lines; five cold-start gates each
   re-scaffold a tmpdir consumer (~800 lines of near-repeated shell); test runners each re-implement
   swift-test invocation + output parsing; no scripts/README classifying CI-only vs local vs manual.
6. **Docs debt in core.** Stale: `docs/MIGRATION-cost-estimation-removed.md` (stub),
   `docs/llama-runtime.md` (pre-v0.48 trait era), `docs/release-notes/v0.20.0-prisma.md` (orphan),
   `docs/design/voice-surface-scoping.md` (never updated post-ship). Operational artifacts
   (`docs/plans/runs/`) and 9 archived plans mixed into user-facing docs. Three overlapping
   "why ManifoldKit" narratives.
7. **Companion onboarding is undocumented.** The ManifoldTestSupport / ManifoldBackendTestKit XCTest
   split, the process-global claims-registry serial-test constraint, and contract-adoption
   walkthrough live only in Package.swift comments and CLAUDE.md — every new companion rediscovers
   them. Companions have no CLAUDE.md at all.
8. **manifold-eval P5 gaps (its own roadmap):** no core-bump, no action SHA-pinning, no rot-guard.
9. **Healthy — leave alone.** Core target factoring (32 targets, intentional carves), companion
   Swift sources (zero duplication with core), test-support sharing (companions already import
   core's products), per-backend `model-tests.yml` (genuinely different), `.gitignore`s.
   Explicitly rejected: merging ManifoldFuzz+ManifoldTools (both surveys judged the split
   intentional); renaming eval executables; corpus mirroring (fetch-corpora.sh is robust).

## Work items

Each item is one PR (batched per repo-hygiene rules; no single-file PRs unless mechanical).
Risk classes: **S** = safe unattended (code/docs with test gate), **W** = workflow/automation change
(unattended with dry-run validation), **H** = human-gated (prepare only, do not merge).

### Wave A — independent fixes (parallel, no cross-dependencies)

| # | Repo | PR | Risk |
|---|------|----|------|
| A1 | manifold-mlx | `fix(ci): repair post-org-move repo references` — canary.yml checkout + core-bump.yml perl pattern + comment refs. Validate: actionlint + `workflow_dispatch` dry-run of core-bump with current version (must hit the no-op path cleanly). **Branch off `origin/main`, not the spike branch.** | W |
| A2 | manifold-eval | `feat(ci): core-bump automation + SHA-pinned actions` — port llama's core-bump.yml adapted to the exact-pin syntax (`exact: "X.Y.Z"` rewrite, not `.upToNextMinor`); SHA-pin actions in ci.yml per core's action-pin audit. Keep `repository_dispatch` + `workflow_dispatch` triggers (the org-move PAT for dispatch is still broken — manual dispatch works meanwhile). Closes the README §P5 first bullet. | W |
| A3 | ManifoldKit | `chore(docs): prune stale docs, separate operational artifacts` — delete the 4 stale docs (finding 6); move `docs/plans/runs/` → `docs/plans/archive/runs/`; sweep for dangling links (`grep -r` over docs/ + README). No content rewrites in this PR. | S |
| A4 | llama + mlx (one PR each) | `chore: add CLAUDE.md + vendored-sync check` — short CLAUDE.md (test gate = serial `swift test`, registry constraint, pin/release model, pointer to core conventions); `scripts/check-vendored-sync.sh` that checksums vendored scenarios/fixtures against the pinned core tag and a CI step that runs it (warn-only initially). | S |

### Wave B — shared CI plumbing (B1 → B2, sequential)

| # | Repo | PR | Risk |
|---|------|----|------|
| B1 | ManifoldKit/.github | `feat: reusable companion workflows` — `workflow_call` versions of core-bump (inputs: pin-rewrite mode `upToNextMinor\|exact`, package name), canary, and a base release-please config; composite `setup-swift-ci` action (Xcode-select + SwiftPM cache) extracted from core's. actionlint gate. | W |
| B2 | llama, mlx, eval (one PR each) | `chore(ci): adopt org reusable workflows` — replace local core-bump/canary/release-please bodies with thin `uses: ManifoldKit/.github/.github/workflows/<x>.yml@main` shims. Validate each with a `workflow_dispatch` no-op dry-run post-merge; keep the old file content in the PR description for rollback. eval's shim passes `pin-mode: exact`. | W |

### Wave C — core consolidation (parallel with B; C1/C2/C3 independent)

| # | Repo | PR | Risk |
|---|------|----|------|
| C1 | ManifoldKit | `feat(tools): publish scenarios, fixtures, and CLI harness for companions` — bundle built-in scenarios + the manifold-tools fixture tree as resources on the `ManifoldTools` product with public accessors (kill `ScenarioLoader.loadBuiltIn()`'s CWD-relative path as the only mechanism); add `VLModelDetector`; extract the shared CLI harness (arg parsing + scenario-runner wiring used by both `manifold-tools-*`). Tests in the same PR; full `--profile local` gate. This is what lets D1 delete the vendored copies. | S |
| C2 | ManifoldKit | `chore(scripts): extract shared shell lib + parametric cold-start runner` — `scripts/_lib/` (test-output parsing, consumer scaffolding); fold the 5 cold-start variants into one runner with `--tier/--module` flags; keep old entry-point names as thin wrappers so ci.yml keeps working (workflow edits in the same PR if trivial); add scripts/README.md. Gate: run each rewritten script once locally + actionlint. CI runners are Bash 3.2 — no `declare -A`; test under `/bin/bash`. | S |
| C3 | ManifoldKit | `docs: companion-backend onboarding + hardware/toolchain guide` — `docs/COMPANION-BACKENDS.md` (TestSupport/BackendTestKit XCTest split, contract-adoption walkthrough, serial-test registry constraint, fixture patterns, release/pin lifecycle incl. core-bump); consolidate Metal/metallib/Apple-Silicon/llama-process constraints into one core doc linked from companion READMEs (companion-side link edits ride D1). | S |

### Wave D — companion adoption (H: gated on next core release)

| # | Repo | PR | Risk |
|---|------|----|------|
| D1 | llama, mlx | `refactor(tools): consume core-bundled scenarios/fixtures + shared CLI harness` — delete vendored copies, adopt C1's accessors, flip A4's sync check from warn to hard-fail for anything still vendored. **Prepare as draft PRs pinned to the future 0.64; do not merge until core releases and core-bump lands the pin.** | H |
| D2 | manifold-eval | manual pin bump to 0.64 via the new A2/B2 automation (`workflow_dispatch`) — first real exercise of that path. | H |

### Attended-only backlog (not in the unattended run)

- Cut core release 0.64 (changelog rewrite is deliberately human-gated) → unblocks Wave D.
- Re-scope the org PAT so `notify-companions` repository_dispatch works again (org secret; user action).
- Decide the manifold-mlx GBNF spike (1.8k-line optimization rollback on `spike/bfcl-mlx-driver` has
  no rationale doc) and whether to materialize `manifold-mlx-eval` to complete manifold-eval's
  differential matrix (feature work, not simplification).
- Editorial: merge WHY-MANIFOLDKIT.md/POSITIONING.md/README "why" narratives (judgment call on voice).
- manifold-eval rot-guard CI (its P5 item; needs a decision on staleness policy).

## Unattended execution harness

Run via the `overnight-pipeline` skill (or the /ship loop per item). Ground rules, all binding:

- **One worker per item, own worktree, correct repo.** Workers `cd` into the target repo and create
  a named worktree off `origin/main` there (never Agent `isolation: worktree` for companion-repo
  tasks — it forks the orchestrator's repo). A1 must not branch from the mlx spike checkout.
- **Premise verification first.** Each brief includes the finding *and* the command to re-verify it
  (surveys go stale — one already had). If the premise fails, the worker parks the item with a note
  instead of "fixing" a non-problem.
- **Protect work early:** commit + push + draft PR as soon as it compiles, before long gates.
- **Draft-PR review loop** (mandatory, all items are non-trivial): skeptical reviewer subagent on the
  diff — correctness, premise, scope, and is-it-live (no read paths without writers).
- **Gates.** Core PRs: full affected test targets (never `--filter <featureSuite>` alone) + audit
  suites; overnight host contention means CI is the authoritative gate — don't spin on local SIGTERMs.
  Companion PRs: serial `swift test`. Workflow-only PRs: actionlint + post-merge `workflow_dispatch`
  dry-run; verify the dry-run actually ran (`gh run list`).
- **Ready → CI → merge.** `gh pr ready` fires CI; verify a run actually started for the head SHA
  (draft-time pushes can burn the SHA's run — force with close+reopen if skipped). Admin-squash-merge
  with `--delete-branch` once green. Serialize merges within a repo; parallelize across repos.
  Conventional-commit PR titles; `Closes #N` only where a real issue exists (don't open new ones).
- **Ordering:** A* and C* start immediately in parallel (cap concurrent local swift gates at 2);
  B1 → B2; D is prepare-only. A1 merges before mlx's B2 shim (fix the live bug first; the shim
  supersedes it, which is fine).
- **Stop rules:** 2 consecutive gate failures on an item → park it with notes and move on; never
  push to main directly; no releases, no version bumps, no secret/org-setting changes; if a
  workflow dry-run misbehaves post-merge, revert that PR and park.
- **Morning report:** table of PRs (merged / ready-awaiting-CI / parked with reason / drafts staged
  for 0.64), the A1 dry-run result, and any premise-verification discards.

Expected shape: ~11 PRs (4 A, 4 B, 3 C) merged unattended, 3 drafts staged for the release,
5 attended decisions queued.
