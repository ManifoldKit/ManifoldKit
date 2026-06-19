# Autonomous wave run — pre-1.0 API cleanup train (2026-06-14)

**Orchestrator:** Claude (main loop). **Plan:** `pre-1.0-api-cleanup-train.md`. **Base:** `origin/main` @ 9dfb3243.

## Operating rules (honored every wave)
- **Versioning OFF-LIMITS** (per overnight-run convention): land on `main`, never touch #1806 / CHANGELOG / tags / companion pins. Release-Please accumulates; maintainer cuts.
- Each unit: worker **implements → DRAFT PR → fresh adversarial reviewer reviews+fixes → mark ready → merge on green CI**. Serialize merges; rebase the rest.
- Worktree-isolated workers off `origin/main`; unique `TMPDIR` per concurrent gate; never stage `Package.resolved`; `feat!:` + `BREAKING CHANGE:` + api-break-allowlist entry per breaking PR.
- Orchestrator sanity-checks each diff before merge (CI-green is necessary, not sufficient).
- **P4 companion port (manifold-mlx):** prepare as DRAFT only — it can't go green until MK is released (pinned). Leave for maintainer's lockstep release.

## Wave status
| Wave | Unit | Worker | Draft PR | Reviewer | CI | Merged |
|------|------|--------|----------|----------|----|--------|
| 1 | B2 GenerationEvent freeze (`usage`→`TokenUsage`) | ✅ done | #1826 | ✅ clean (agent) | ✅ green | ✅ **MERGED** df7b8c9a |
| 1 | B3 ChatSession naming (`Persisted*`) | ✅ done | #1827 | ✅ clean (orchestrator; reviewer agent flaked) | ✅ green | ✅ **MERGED** a0d855f8 |
| 2 | P7 shim retirement (+ migration guide) | ✅ done | #1837 | ✅ clean + 2 CI fixes (orchestrator) | ⚠️ merged RED (2 audits) → fix #1840 | **MERGED** c4c99f0a (main went red — see incident) |
| 3 | P4a seam + P4b MessagePart collapse | ✅ done | #1839 | ✅ clean (orchestrator) | ✅ green (verified) | ✅ **MERGED** e929ca40 |

**RUN COMPLETE 2026-06-14.** All mergeable units landed on `main` (e929ca40): #1826, #1827, #1836, #1837, #1840, #1839. Deferred to maintainer lockstep release: P4c + manifold-mlx companion port. WONTFIX: #1682. Deferred backlog: #1796.
| 2b | P7 audit follow-up (un-red main) | ✅ done | #1840 | verified (all checks pass) | ✅ green | ✅ **MERGED** efb0c6f8 — main green again |
| — | #1836 contract wire hardening (concurrent worker) | ✅ done | #1836 | ✅ clean (orchestrator) | ✅ green | ✅ **MERGED by maintainer** (b57d4023) |
| 3 | P4c migrate/delete clones (core) | DEFERRED | — | — | — | breaks companion → needs lockstep release (maintainer) |
| 3 | P4 companion port (manifold-mlx, DRAFT only) | DEFERRED | — | — | — | gated on P4c + MK release |
| bg | #1796 §A perf | deferred | — | — | — | needs re-verify vs main (RepetitionDetector already fixed #1802); after current batch |
| bg | #1682 transaction{} | ❌ WONTFIX | — | — | — | already implemented + defended in code (`SwiftDataPersistenceProvider.swift:407-460`) + 10 tests; worker correctly stopped |

## Discovered issues / improvement opportunities (review at end — do NOT act mid-run)
- **[B2] Duplicate `TokenUsage` name:** `ManifoldCloudCore` has a nested `StreamTermination.TokenUsage` (optional fields) vs the new top-level `ManifoldContract.TokenUsage` (non-optional). No collision, but candidate to reconcile (CloudCore one is the wire-parse intermediate feeding the new payload).
- **[B2] Stale prose:** doc comments still describe old `.usage(prompt, completion)` shape — `ClaudeStreamEventExtractor.swift:336,465`, `ClaudeBackend.swift:441`, `OllamaBackendTests.swift:699`, `TurnLoopCharacterizationTests.swift:581`. Cleanup-pass candidate.
- **[B2] API-break gate cadence:** confirm the per-PR `diagnose-api-breaking-changes` `$TARGETS` paths-filter includes `ManifoldContract` so the allowlist entry is exercised on-PR (verified locally; CI scoping not re-derived).
- **[B2] Allowlist comments:** B2 added `#`-prefixed comment lines to `.github/api-breakage-allowlist.txt` (previously comment-free); inert no-ops, strip if maintainer prefers.
- **[B3] Value-type vs typealias resolution is subtle:** many `ManifoldUITests`/`ManifoldBackendsTests` use bare `ChatSession`/`ChatMessage` for the VALUE type and compile unchanged (value struct wins over typealias even with both imported). When the deprecated aliases are removed at the 1.0-adjacent major, those sites need re-verification.
- **[B3] Schema enum self-references:** `ManifoldSchemaV3`–`V9` reference bare `ChatSession.self`/`ChatMessage.self` in their own enum scope (resolves to nested @Model via enum-scoped lookup) — left as-is, correct; note for future audits.
- **[B3] `MessagePartTests.swift`** mixes `ManifoldInference.ChatMessage` / `ManifoldSchemaV4`/`V9.ChatMessage` / `PersistedChatMessage` in one file — heavy disambiguation; readability-cleanup candidate.
- **[process] Admin-merge must verify HEAD checks all-success, not just trust the `--watch` exit:** merged #1837 while a `test` run (27484467715, same SHA) showed `failure` — the watch had exited 0 (latched a different/earlier run). The failure was the affected-suites-graph staleness check (flaky/intermediate); main's graph verified current post-merge, so likely no real break — but the lesson stands: before `gh pr merge --admin`, explicitly confirm every required check on the exact HEAD SHA is `success`. (Verifying main CI now.)
- **[P7/process] affected-suites-graph.json must be regenerated on module removal** (#1636/#1643) — P7 removed modules; the Tier-0 graph snapshot check flagged staleness on the PR. Add "regen `scripts/affected-suites.sh --generate`" to any module-add/remove brief.
- **[P7/process] Source-path-scanning audits break on structural moves:** removing/relocating a source dir breaks audit tests with hardcoded dir lists that `allSatisfy(fileExists)` (CloudSeamUsage, DNSRebinding, SessionConstruction, CancellationLiveness, CloudErrorSanitizer — all in `ManifoldBackendsTests`). P7 updated topology/traffic audits but missed these 5; orchestrator fixed (dropped removed `Sources/ManifoldCloud` entry). Lesson: structural-change briefs must say "update ALL source-path-scanning audits," and these audits ran only in the `saas` CI shape (not the worker's compile-check), so they're invisible until CI.
- **[process] Subagent gate-wait failure mode:** reviewer subagents background the ~15-min `scripts/test.sh` (exceeds foreground timeout) then return BEFORE it finishes — never delivering a verdict/ready. Mitigation adopted: **CI is the authoritative gate; orchestrator owns CI-watch + merge**; workers do implement + `swift build --build-tests` compile-check + draft PR only; orchestrator does the adversarial diff review if a reviewer flakes. (Worth a durable memory.)

## ⚠️ CONCURRENT WORK DETECTED (not part of this run)
- `/private/tmp/mk-prefreeze` branch `feat/contract-prefreeze-hardening` — **31 live procs**, uncommitted edits to `Sources/ManifoldContract/Message.swift`, `Sources/ManifoldHardware/ToolTypes.swift`, `Sources/ManifoldHardware/BackendCapabilities.swift`. No commits/PR yet. Another session is doing contract extensibility hardening. LEFT UNTOUCHED (live PIDs).
- Collision risk: **P4 (Wave 3) touches `Message.swift`** too → rebase P4 onto whatever this lands, or coordinate. `ToolTypes.swift` edits may duplicate the already-shipped P2.5a (#1741). P7 (Wave 2) is disjoint — unaffected.
- **MAINTAINER DECISION (2026-06-14):** that worker will PR its changes for review. **Treat as a BLOCKER until investigated** → **P4 is HELD** until I review that PR. Adjusted sequencing: after P7, run the disjoint backlog (#1796, #1682) instead of P4. Review the incoming `contract-prefreeze-hardening` PR when it appears.
- **RESOLVED:** PR **#1836** ("harden Contract wire types before 1.0 freeze" — JSONSchemaValue `.integer(Int64)`, `ErrorKind.unknown` tolerant decode, tolerant `BackendCapabilities` decode). **Reviewed CLEAN** (defaults match init; switch-completeness compiler-enforced; not a dup of #1741; no conflict with B2/B3). **P4 collision is a non-issue** — #1836's `Message.swift` change is a doc comment only. **P4 effectively UNBLOCKED** (trivial rebase once #1836 lands).

## Run log
- 2026-06-14 — run started; Wave 1 (B2 + B3) dispatched as worktree-isolated background workers.
- 2026-06-14 — Wave 1 COMPLETE: #1826 (B2) merged df7b8c9a, #1827 (B3) merged a0d855f8. Wave 2 P7 implementer running. Detected concurrent `feat/contract-prefreeze-hardening` worktree (see warning above).
- 2026-06-14 — maintainer note: companions (manifold-mlx / manifold-llama) bumped to **0.2.1**. Relevant to Wave 3 P4 companion-port base only (their own version, not the ManifoldKit pin). Do NOT hand-tag companions (manifest is sole version source). No action mid-run.
