# Migration baselines

Historical snapshots from the cross-backend unification plan (Phases 1–5).
The files here are now **reference-only**: the two XCTest "mechanical gates"
that once read them (`CoverageRegressionGateTest`, `PublicAPIStabilityTest`)
have been removed because they skipped every CI run since the Phase 1a
scaffold (#1246) — the Phase 1b capture tooling was never built, so they
gave false confidence rather than protection.

What replaced them:

- **Coverage protection** is enforced for real by `scripts/check-coverage.sh`,
  wired into `.github/workflows/nightly-slow-tests.yml`. It runs a fresh
  `swift test --enable-code-coverage` over the four critical modules and
  fails when any module's line coverage drops below threshold.
- **Public-API source-compatibility** (guarding `import ManifoldKit` for
  downstream consumers) is enforced by a direct CI step in
  `.github/workflows/ci.yml` (the `test` job) that runs
  `swift package diagnose-api-breaking-changes origin/main --targets …`.
  No env-var plumbing, no captured baseline file — the command exits
  non-zero on a real break by itself. See that step's comment for the
  per-`--targets` invocation note (whole-package mode fails on the
  trait-gated `llama` C module).

## Remaining files (historical reference, no live consumer)

| File | What it is |
|------|------------|
| `baseline-scenarios.md` | one-shot enumeration of `func test*` per backend test file at capture time |
| `phase-1b-coverage-map.md`, `phase-2a-coverage-map.md`, `phase-2b-coverage-map.md` | per-deletion accounting from the migration phases, for reviewers |

These are frozen snapshots of decisions made during the migration. They are
kept as a record; nothing reads them at test or CI time.
