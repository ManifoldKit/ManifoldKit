# docs/plans/

This directory holds **active** design/execution plans only — not a history
book. Git history is the archive: when a plan is fully executed, superseded,
or rejected, delete it (don't move it to an `archive/` subdirectory, and
don't leave a stub). Anyone who needs the old text can `git log --all --
docs/plans/<name>.md` and read the last version before deletion.

## Rules

1. **Every plan carries a `Status:` line** near the top (first ~20 lines),
   e.g. `**Status:** Awaiting sign-off (Rory)` or `**Status:** Active —
   Phase 1 shipped, Phase 2 open.` `AgentsMdPlansStatusAuditTest` (in
   `Tests/ManifoldInferenceTests/`) fails CI if a tracked `docs/plans/*.md`
   file is missing one.
2. **Delete, don't archive, once a plan is done.** A plan that is fully
   executed, explicitly superseded, or rejected gets `git rm`'d in the same
   PR that closes it out — not moved to an `archive/` subfolder. This mirrors
   the repo's pre-1.0 "delete, don't deprecate" API policy (see AGENTS.md
   Part 2).
3. **`runs/` output is gitignored, never committed.** Per-run artifacts
   (raw JSONL, sweep logs, per-cell CSVs, transcripts) under
   `docs/plans/runs/` are ephemeral and regenerable from source data — commit
   only curated markdown summaries (e.g. `SUMMARY.md`, `MATRIX.md`) if a plan
   explicitly calls for one. See the `.gitignore` entries for the exact
   ignore/un-ignore pattern.

## Why

Agents and contributors reading this directory can't tell current direction
from history if closed-out plans and in-flight ones sit side by side with no
signal distinguishing them. A `Status:` line is a one-line, always-visible
answer to "is this still true," and deleting completed plans keeps the
directory listing itself a reliable index of what's actually in flight.
