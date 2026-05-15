# Migration baselines

Snapshots that anchor the cross-backend unification plan's mechanical gates.
The files in this directory are written once on a canonical runner and read
on every CI run by `CoverageRegressionGateTest` and `PublicAPIStabilityTest`.

## Files

| File | Written by | Read by | Status |
|------|------------|---------|--------|
| `baseline-coverage.json` | one-shot capture: `swift test --enable-code-coverage --disable-default-traits --skip-update` projected through xccov | `CoverageRegressionGateTest` | **pending capture** |
| `baseline-scenarios.md` | one-shot enumeration of `func test*` per backend test file | reference only (no test reads this) | **pending capture** |
| `baseline-public-api.txt` | `swift package diagnose-api-breaking-changes <baseline-ref>` | `PublicAPIStabilityTest` | **pending capture** |
| `phase-1-coverage-map.md` | per-deletion accounting in Phases 1b-5 | reviewers | created lazily |

## Capture workflow (Phase 1b)

Once the bench host has a clean checkout of the cross-backend Phase 1a PR
merged, run:

```bash
# Coverage baseline
swift test --enable-code-coverage --disable-default-traits --skip-update \
    --filter ManifoldBackendsTests --filter ManifoldInferenceTests
xcrun xccov view --json --only-targets .build/debug/codecov/default.profdata \
  | jq '...filter to Sources/ManifoldCloud and Sources/ManifoldInference...' \
  > Tests/Fixtures/_migration/baseline-coverage.json

# Public-API baseline
swift package diagnose-api-breaking-changes main \
  > Tests/Fixtures/_migration/baseline-public-api.txt
```

Until those files exist, the gate tests log `SKIPPED:` with a pointer back
to this README. The gates remain green on CI without the baselines so that
this PR can land before the snapshotting tool is finalized.

## Why baselines live in the test fixtures tree

`Tests/Fixtures/` already aggregates SSE recordings, expected JSONL, and
the (forthcoming) per-backend fixture trees. Keeping migration baselines
in the same directory means a single `git mv Tests/Fixtures/...` covers
the whole snapshot category if we ever reorganize.

## Editing policy

These files are **machine-generated**. Do not hand-edit them. Re-run the
capture command instead. A baseline drift caught by a gate is a signal,
not a noise source — either fix the regression or update the baseline
intentionally in a separate commit.
