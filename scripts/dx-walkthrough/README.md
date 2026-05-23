# DX Walkthrough Harness

A repeatable, forced-blindness DX regression check. Three parallel agents
play "fresh Swift developer", each follow an archetype brief (e.g.
`01-chat-cli.md`) without reading ManifoldKit's source or tests, and log
friction as they go. Their friction logs are synthesized into a
per-iteration `SUMMARY.md` and diffed against prior iterations to track
which DX papercuts get fixed, which persist, and which new ones surface.

## Running it

```sh
scripts/dx-walkthrough/run.sh 01-chat-cli iter5
```

This scaffolds `runs/<date>_v<version>_<label>/<archetype>/run-{1,2,3}/`
and prints three self-contained dispatch prompts. Hand each to the Agent
tool with `subagent_type=claude`, `isolation=worktree`,
`run_in_background=true`. They run in parallel.

When the three agents report back, write `SUMMARY.md` (and optionally
`ROOT_CAUSES.md`) directly under the iteration's archetype directory.
Use prior iterations' SUMMARY.md as the format reference — see
`runs/2026-05-23_v0.33.0-iter4/01-chat-cli/SUMMARY.md` for the canonical
shape.

## Comparing iterations

```sh
scripts/dx-walkthrough/compare.sh \
  runs/2026-05-23_v0.33.0/01-chat-cli \
  runs/2026-05-23_v0.33.0-iter4/01-chat-cli
```

Heuristic markdown diff. Groups findings into Disappeared (likely
fixed), Persisted (still open), New (regression or next-layer
discovery). Fingerprints by the first sentence of each entry's "Trying
to:" line — false positives are possible when entries get rephrased.

## The forced-blindness rule (do not relax)

Agents may read `README.md`, `docs/`, `Sources/*/Documentation.docc/`,
`Package.swift`, and repo-root markdown. They may **not** read
`Sources/Manifold*/**/*.swift` or `Tests/**`. The whole point of the
exercise is to measure whether the public-facing surface is sufficient
for a new developer; letting agents grep internals turns the test into
"can a competent reverse-engineer ship in 30 min", which is a different
question.

If an agent gets stuck and wants to peek at sources, they should log it
in `FRICTION.md` as a discoverability gap and pivot — that signal is the
deliverable.

## Methodology: vary the surface across runs

A regression-style rerun where all three agents pick the same backend
collapses three data points into one. Steer each run at a different
public path (e.g. Foundation in run-1, local Llama GGUF in run-2, cloud
or Ollama in run-3, or different reasoning vs. non-reasoning models).
Backend variation is signal — uniformity is noise.

This lesson was learned the hard way between iter-2 and iter-3; iter-4
was the first iteration where the dispatch deliberately spread runs
across surfaces, and it surfaced multiple findings that homogeneous
runs missed.

## Recommended cadence

- **Quarterly** as a baseline DX regression check
- **Pre-release** before any minor-version bump
- **Post-major-refactor** any time a module boundary moves or a
  public-facing type changes shape

A single archetype rerun is ~30 minutes of agent time and ~5 minutes of
human synthesis. Adding a new archetype (e.g. `02-swiftui-chat.md`,
`03-rag-from-pdf.md`) is the right way to widen coverage.

## Layout

```
scripts/dx-walkthrough/
  briefs/                    # one .md per archetype, checked in
  runs/<date>_v<ver>_<label>/<archetype>/
    SUMMARY.md               # checked in — cross-run synthesis
    ROOT_CAUSES.md           # checked in (optional) — causal grouping
    run-{1,2,3}/             # NOT checked in (gitignored)
      app/                   # the working Swift package
      FRICTION.md            # per-run friction log
      NOTES.md               # 5–10 line per-run impression
      session.log            # final swift run transcript
  run.sh
  compare.sh
  README.md
```

The per-run artifacts (`run-*/`) are large and ephemeral — they're
gitignored. The retrospective `SUMMARY.md` / `ROOT_CAUSES.md` files at
the iteration root **are** committed so historical DX state stays in
the repo.

## Canonical example

The 2026-05-23 v0.33.0 session produced four iterations (`-iter1`
through `-iter4`) and shipped PRs #1392, #1393, #1397, #1401 plus bugs
#1394, #1398, #1399. The iter-4 summary at
`runs/2026-05-23_v0.33.0-iter4/01-chat-cli/SUMMARY.md` is the canonical
"what good output looks like" reference.
