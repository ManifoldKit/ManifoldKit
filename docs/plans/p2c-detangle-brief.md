# P2c — De-tangle `ConversationTurnExecutor` (dispatch-ready brief)

Issue: #1721. Parent: #1605. Plan: `docs/plans/p2-engine-carve-split.md`.
**Risk: HIGH. Single sequential worker — NOT parallelizable** (rewrites the shared turn-loop file).
**The one real refactor of P2.** Behavior-preserving: every step diffs clean against the P0c goldens.

## Preconditions (do NOT start until both are true)
- **#1722 merged** (P2b grown goldens: `agentID`/`sessionID`/token fields in the canonicalizer +
  `test_handoff_midStream` + `test_tokenUsage`). This is the safety net — the de-tangle is unsafe
  without it.
- **#1723 merged** (P2a `ManifoldContract` leaf). Not strictly required for this file, but branch off
  the `main` that contains both so the worktree matches CI.

Branch off fresh `origin/main` after both land. If they merge mid-work, rebase (verify checkout +
HEAD movement) before pushing.

## Target file
`Sources/ManifoldRuntime/Services/ConversationTurnExecutor.swift` — a 1,740-line `struct` with four
public entry flows (`runSendFlow` ~L79, `runRegenerateFlow` ~L243, `runEditFlow` ~L308,
`runBranchFlow` ~L396) converging on a shared `runGenerationTurn`. No module move — this is an
internal refactor within `ManifoldRuntime`.

## Goal
Reduce the monolith to a thin per-turn executor by lifting cross-cutting concerns behind narrow,
testable seams — WITHOUT changing observable behavior:
- **Persistence writes** (`ConversationPersistencePort`: `insertMessage`/`deleteMessage`/
  `fetchMessages`/`fetchSession`/`updateSession`/`touchSession`, ~12 call sites) behind a narrow
  turn-scoped port.
- **Event emission** (~50 `emit(...)` calls via the `eventSink` @Sendable closure, private `emit`
  ~L1281) behind a typed per-turn emitter.
- **Tool-dispatch seam** (advertise `readAdvertisedToolDefinitions` ~L744, register
  `registerSessionToolExecutors` ~L754, unregister ~L1700; execute happens in `ManifoldInference`'s
  `GenerationQueue`/dispatch loop) made explicit instead of cross-cutting-implicit.
- Optionally extract the pre-turn (~L130–184) and post-turn (~L1199–1275) **compression** coordination
  (shared `makeCompressionGenerateClosure` ~L1481) into its own coordinator.

The four flows should read as: assemble context → enqueue → consume stream → persist → post-turn,
with each concern a named collaborator rather than inline.

## INVARIANTS — must be preserved exactly (from the concurrency persona review)
1. **`sessionRecord` stays a function-local, re-pinned `var` — NEVER re-fetched from the store
   mid-stream.** It is fetched once (~L611) and re-pinned from `handoff.targetAgentID` AFTER the
   async `updateSession` (~L894). The executor is a `struct` and `runGenerationTurn` is a single
   non-reentrant async function, so the local is the authoritative copy and nothing else can observe
   it between the write and the re-pin. **Do NOT replace this with a "single source of truth" port
   that re-reads session state on the next loop iteration** — that inserts an async read-after-async-
   write where the store write may not yet be visible, reintroducing a race the current design avoids.
   If you lift `updateSession` behind a port, the port returns void and the local re-pin stays.
2. **#965 switch-cancel-resend** — the empty-assistant-drop branch (~L1082–1087) relies on
   `GenerationQueue.discardRequests(notMatching:)`. Preserve the ordering.
3. **#1606 register-before-enqueue** — session tool executors MUST be registered on the
   `InferenceService.toolRegistry` BEFORE `enqueueAsync` (~L737–775), else the dispatch loop returns
   `unknownTool`. Keep this ordering when extracting the tool-dispatch seam.
4. **KV-cache re-read-after-async-write discipline** — don't reorder reads of backend state around
   the async stream-consume boundary.
5. **`@Sendable` event sinks must not capture `@MainActor` state.** Any extracted emitter/port that
   receives `eventSink` takes it as `@Sendable (ConversationEvent) -> Void` and must NOT close over
   `InferenceService` or any `@MainActor` member. Main-actor reads stay behind the existing
   `@MainActor read*()` hops (`readActiveBackendName` ~L1716, etc.). Watch the Swift 6 gotcha:
   a non-isolated async helper receiving a `@MainActor`-capturing closure triggers
   `#SendingRisksDataRace` — annotate the closure or keep the read behind the hop.
6. **preCompact hook is observational in v1** (~L1217–1236) — `block:true` is ignored. Don't
   "fix" that here; it's documented contract.
7. **Token-usage pinning** (~L967–981) — the per-turn `lastTokenUsage` read must stay pinned to the
   turn so back-to-back sends don't cross-contaminate counts. Now golden-covered by `test_tokenUsage`.

## Approach: incremental, each step golden-verified
Do NOT big-bang this. Land it as a sequence of behavior-preserving commits (the issue allows 1–2 PRs;
prefer a stack of small commits on one branch, or two PRs split at a natural seam):

1. **Extract the event emitter** (lowest risk). Introduce a `TurnEventEmitter` (or similar) wrapping
   the `@Sendable` sink with typed phase methods; replace the ~50 inline `emit(...)` calls. Run the
   goldens — must diff clean (event order/identity unchanged).
2. **Extract the persistence seam.** Narrow turn-scoped writes behind a port; keep `sessionRecord`
   local per invariant 1. Run goldens — clean.
3. **Extract the tool-dispatch binding** (advertise/register/unregister lifecycle), preserving #1606
   ordering. Run goldens — clean (`test_tool_roundTrip` + `test_handoff_midStream` are the guards).
4. **Thin the four flows** over the extracted collaborators. Run goldens — clean.
5. (Optional) **Compression coordinator** extraction.

After EACH step, the grown P0c goldens must diff clean. If a step forces a golden change, STOP — a
behavior-preserving refactor must not change goldens; investigate before re-recording.

When changing any behavior touchpoint, grep ALL of `Tests/` for references (not just the obvious
file) — `ConversationRuntimeTests`, `HandoffScenarioTests`, `CompressionPolicyTests`,
`PreCompactWiringTests`, `SessionToolSource*Tests`, the characterization harness.

## Gate (before push)
- `scripts/test.sh --profile local` (full all-traits XCTest + Swift-Testing two-invocation shape).
- The grown characterization goldens diff clean:
  `swift test --filter ManifoldTurnLoopCharacterizationTests --disable-default-traits` (twice).
- Add sabotage checks per QA-PRACTICES §3 to prove each extracted seam fails the test when broken;
  **remove before committing**.
- Never stage `Package.resolved`.

## Mandatory diff review (before merge)
Because this is the HIGH-risk refactor, after the worker has a green branch, run **2–3 persona
reviewers on the DIFF in parallel** (concurrency / turn-loop-correctness / test-coverage lenses),
specifically checking the 7 invariants above survived. Only open/finalize the PR once they clear.
Do NOT `--auto`/`--merge`; report the PR URL for maintainer merge.

## Commit / PR
- Conventional: `refactor(ManifoldRuntime): de-tangle ConversationTurnExecutor into per-turn seams`
  (refactor → no release), trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- PR body: `Closes #1721`, the seam decomposition, per-step golden results, the 7 invariants checklist,
  and the persona-review verdicts.
