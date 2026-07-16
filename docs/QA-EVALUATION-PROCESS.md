# QA Evaluation Process

**Audience:** contributor
**Status:** living

A repeatable, principle-driven audit of ManifoldKit's architecture, QA, DX, and CI economics. Run it periodically (suggested: each minor-version train, or quarterly) to catch drift, regressions in discipline, and rules that have quietly expired. The most recent run (`QA-EVALUATION-2026-06.md`) was removed in a 2026-07 docs/plans hygiene pass — see git history for that snapshot.

This process turns the principles in [`TESTING-CI-PRINCIPLES.md`](TESTING-CI-PRINCIPLES.md) from a reference into an **audit instrument**. The principles are the rubric; this doc is the procedure.

## Why it works this way

Three rules make the output trustworthy rather than vibes:

1. **Codebase is the only truth.** Every finding cites `file:line`. A claim without an anchor is a hypothesis, not a finding. This is what catches "the test exists ✓" when the test actually always skips.
2. **Evidence first, judgment second.** Workers gather grep/read evidence *before* rating. No rating without the anchor that supports it.
3. **Adversarially reconcile.** Where two workers' evidence conflicts (it will), the conflict is the signal — reconcile it explicitly. The June 2026 run flipped a "no API-breakage gate" GAP to a "narrow gate" PARTIAL exactly this way.

## The instrument: principle → diagnostic

Each principle becomes a diagnostic question, an evidence target, and a severity-weighted verdict (CONFORMS / PARTIAL / GAP). The dimensions and their principle clusters:

| Dimension | Principles | Core diagnostic questions |
|---|---|---|
| **Architecture** | P2/P3 (mode selection, deduction-first), P5 (API contract), P14 (cold-start), P15 (owned seams), A1 (topology) | Where is induction used where deduction is free? Is the public API a mechanically-enforced contract? Are foreign deps faked at owned seams? Can a stranger build against each product? |
| **QA** | P6 (determinism), P7 (trust), P8 (tiering), P10 (change-confidence), P13 (discovered space), P4 (adversarial), P16 (instrument) | Is every test reproducible & hermetic? Is flake debt zero and skips justified? Is tiering severity-ranked or only speed-ranked? Is change-confidence *measured* (mutation/coverage)? Is the suite itself instrumented? |
| **DX** | P10 (felt confidence), P14 (onboarding), feedback latency | How fast is the inner loop, and is it the real gate? How many steps from zero to working? Are docs tested and links live? |
| **Economics** | P9 (EOQ batching), P12 (commitment gradient), P16 (cost telemetry) | Is batch size at an interior optimum or "bigger is always better"? Is affected-only testing safe? Is the re-run tax instrumented? Is the platform floor enforced or just declared? |

For each principle also ask the **contingency question**: *is this a good practice, or an expired one?* (over-batching after caching improved, mocking a contract you now own, inducting what you could deduce, doctrine that lags the shipped code).

## The protocol

1. **Scope.** Pick the dimensions (all four, or one as a proof-of-method). Re-read `TESTING-CI-PRINCIPLES.md` for the current rubric.
2. **Fan out evidence workers** — one per dimension (split QA into two; it's the densest). Each worker:
   - gets the diagnostic questions for its cluster (use the June run's worker prompts as templates),
   - greps/reads the real repo, citing `file:line`,
   - returns CONFORMS / PARTIAL / GAP per area with evidence and 1-3 candidate actions.
3. **Reconcile + adversarially verify.** Cross-read the worker outputs for conflicts; re-check any material or surprising finding against the source before trusting it. Conflicts are findings.
4. **Severity-weight (P8).** Rank gaps by *risk reduction per unit cost*, not by count. A dormant contract gate (consumer-fanning, irreversible) outranks ten cosmetic items. Note cross-cutting gaps (a gap that appears in two dimensions is higher leverage).
5. **Write the report** — scorecard table, cross-cutting themes, prioritized P0/P1/P2 actions with anchors, and an explicit "already strong — do not fix" section so the audit isn't only negative.
6. **Track the actions** — one tracking issue with a checklist, or a checklist in the report. Do **not** fan out one issue per finding (see `CLAUDE.md` issue hygiene).

## Running it from Claude Code

Ask Claude to "run the QA evaluation process" (point it at this file). The expected shape:

- Dispatch 4-5 parallel evidence workers (`general-purpose` agents) with the per-dimension diagnostic prompts. Each must cite `file:line` and rate CONFORMS/PARTIAL/GAP.
- Optionally add an adversarial-verify pass: a skeptic re-checks each GAP/PARTIAL against the source and tries to refute it; survivors stand.
- Synthesize into a dated `docs/QA-EVALUATION-<YYYY-MM>.md` mirroring the latest run's structure.

The June 2026 worker prompts are the canonical templates — reuse and update them. For a heavier, fully-orchestrated run (fan-out → adversarial verify → synthesis as one deterministic pipeline), this is a good candidate for a multi-agent workflow.

## Cadence & scope guidance

- **Full audit:** each minor-version train or quarterly. ~4-5 workers; a few hours of agent time.
- **Single-dimension spot-check:** when touching a specific area (e.g. after CI changes, re-run Economics only).
- **Drift watch:** the cheapest recurring value is re-checking the cross-cutting themes — self-instrumentation, doctrine-vs-implementation drift, and self-validating gates (path filters, audit-of-audits) — because those rot silently between full runs.

## Reading the output

A CONFORMS is not "done forever" — it's "true as of this run, at this anchor." A PARTIAL with a cheap deductive fix usually outranks a GAP with an expensive one. And every recommendation should name the driver it serves, so a future reader can tell whether the action still matters when the facts change (see the expiry-condition discipline in `TESTING-CI-PRINCIPLES.md`).
