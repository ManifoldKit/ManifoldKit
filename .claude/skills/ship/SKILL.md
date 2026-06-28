---
name: ship
description: >-
  Ship a non-trivial change through the mandatory draft-PR review-and-fix loop
  before CI. Use when asked to implement an issue/feature/fix as a PR, or to
  "ship", "land", or "PR" a non-trivial change. Implements in an isolated
  worktree, opens a DRAFT PR, runs a skeptical reviewer subagent, fixes findings,
  gates on the full affected test targets (incl. audit suites), then marks ready
  — which is the single trigger that starts CI (drafts run zero CI in this repo).
---

# /ship — draft-PR review-and-fix loop

This repo gates CI to **skip draft PRs** (`ci.yml`/`readme-snippets.yml`/`cold-start-human.yml`/`build-modes.yml`
guard on `draft == false`, with `ready_for_review` in the trigger types). So a draft PR is a
**zero-CI staging area**, and `gh pr ready` is the single, deliberate CI trigger. Use that window
to catch green-but-wrong code *before* paying for a 10×-billed macOS run. See CLAUDE.md
§"Draft-PR review loop".

## When this applies

**Non-trivial** = touches **2+ files** OR adds/changes **behavior or logic**. Trivial single-file
mechanical edits (typo, version bump, comment/doc-only, pure rename) skip this loop — make a normal
PR. When in doubt, run the loop.

## The loop

### 1. Implement (isolated worktree off `origin/main`)
- `git fetch origin` then create a worktree on a fresh branch off `origin/main` — **never** the
  current working branch. Do all edits there.
- Follow the change's conventions (CLAUDE.md): async/await + `@Observable`/`@MainActor`; no `try?`
  in production paths (`do/catch` + `Log.*`); no `assertionFailure`/`fatalError` on recoverable
  paths; inject `UserDefaults`; in-memory SwiftData (never mock persistence). Tests + docs ship in
  the same PR.
- **Open the DRAFT PR the moment it compiles** (`swift build`) — protect work before the long gate.
  `gh pr create --draft --title "<conventional title>" --body "..."`. Never `--auto`/`--merge`.

### 2. Review (skeptical subagent)
Dispatch a reviewer subagent against the diff (`gh pr diff <N>` + read changed files in full).
It must be **adversarial** — assume there are bugs — and check:
- **Correctness** and the **premise/assumptions** (verify cited file:line anchors against `Sources/`).
- **Is the feature actually live, or inert?** A read path with no writer is dead code — the #2064
  lesson (a hash recorded nowhere never fires). Trace every consumer/producer.
- **Scope discipline** — no unrelated changes; deferred work stays deferred.
- **Conventions** — the CLAUDE.md list above; minimal `public` surface.
- **Tests prove the behavior** (not vacuous asserts) and a sabotage check would fail if the code broke.

### 3. Fix
Apply findings; push to the **same** branch (still draft). Loop step 2 again if the fixes are
substantial.

### 4. Local gate — FULL affected targets, not `--filter <featureSuite>`
> Cross-cutting audits live **outside** feature suites — `TestSuiteSilentSkipAuditTest`,
> `SilentCatchAuditTest`, schema/codegen/snapshot guards — so a filtered run goes **green** while CI
> goes **red**. This is exactly how #2064's `try? XCTUnwrap` reached CI.
- Run the affected test **target(s) whole**, plus the audit suites by name:
  `swift test --filter TestSuiteSilentSkipAuditTest` and `swift test --filter SilentCatchAuditTest`.
- For broad or risky changes, run the full gate: `scripts/test.sh --profile local`.
- `grep -rnE 'try\? (XCTUnwrap|XCTSkip)' Tests/` must be clean in added files.

### 5. Mark ready (the CI trigger)
Only when **review-clean AND the local gate is green**: `gh pr ready <N>`. That flip fires
`ready_for_review` → CI starts. Do **not** merge; the maintainer reviews and merges. Report the PR
URL and the review/gate summary.

## Worker hygiene (when delegating to subagents)
- Each worker brief must: sync the branch first (`git fetch && git reset --hard origin/<branch>`),
  stage **explicit paths** (never `git add -A` — it sweeps `Package.resolved`/build artifacts), and
  end commit messages with the `Co-Authored-By` trailer.
- Reviewer and implementer can be the same resumed agent across rounds (it keeps context) or fresh
  agents — but the reviewer must be told to be adversarial, not confirmatory.
