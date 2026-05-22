---
name: README pruning ritual
about: Recurring DX audit — prune accreted README content and verify Hello World still leads
title: 'dx: README pruning audit YYYY-Q?'
labels: dx-debt
assignees: []
---

READMEs accrete. New features get demo snippets, edge cases get caveats, and over a
few cycles the "60-second adopter onboarding" promise erodes. This issue is the
calendar reminder to reverse that drift before it compounds.

## Checklist

- [ ] `wc -l README.md` — note current line count vs last audit (target ≤700).
- [ ] First H2 is still `## Hello World` (run `bash scripts/cold-start-human.sh`).
- [ ] Hello World snippet still compiles (CI gate confirms; spot-check the README
      block matches `Example/Examples/MinimalExample` patterns).
- [ ] `docs/FeatureMatrix.md` reflects the current `Package.swift` traits
      (`FeatureMatrixTests` asserts this — but eyeball the table for accuracy).
- [ ] No new H2s in `README.md` that belong under `docs/` instead.
- [ ] Identify at least one section to relocate to `docs/` or delete this cycle.

## Context

The DX overhaul (Waves 0–E) established a 60-second-onboarding goal: a new adopter
should hit a working chat in under a minute by reading `## Hello World` and pasting
the snippet. Every audit is a chance to verify that promise still holds and to ship
a `dx:` PR against the [DX budget](../../CONTRIBUTING.md#dx-budget) for this cycle.
