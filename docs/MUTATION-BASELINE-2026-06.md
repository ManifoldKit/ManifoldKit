# Mutation-testing baseline — turn loop + ConversationRuntime (2026-06)

Status: **SPIKE / exploratory** (issue #1695). Not wired into CI. This doc records
whether off-the-shelf mutation testing (`muter`) can run against ManifoldKit at
all, what it reported for the turn loop, why that report turned out to be
**invalid**, and the exact commands to reproduce the whole investigation.

QA-EVALUATION action **B2** observed that ManifoldKit's change-confidence is
*asserted* (large suite, audit tests, sabotage suite) but never *measured*: we
have no number for "if a line of turn-loop logic silently changed, would a test
fail?". Mutation testing measures exactly that — it perturbs the source and
checks whether the suite notices.

> **TL;DR.** `muter` v16 **runs to completion** here (after working around a
> copied-`.build` module-cache poisoning and scoping to a trait-disabled,
> XCTest-only subset) — but it produces a **silently invalid score**: it
> reported **0 / 62 mutants killed (0%)**, yet hand-applying one of its own
> "survived" mutants makes the suite fail hard. Muter never injected the
> mutations into the code it built. **Recommendation: do not adopt muter v16 on
> this package.** The actionable output is the failure analysis below, not a
> baseline number. See [Results](#5-results).

---

## 1. Why a naive `muter` run does not work here

`muter` works by copying the whole project to a sibling `<project>_mutated/`
directory, inserting one source mutation at a time, and re-running your test
command for each mutant. Three ManifoldKit properties break the default path:

### Blocker A — copied `.build` poisons the module cache (hard failure)
Muter copies the *entire working directory*, including SwiftPM's `.build/`
(1.5 GB here). SwiftPM's precompiled module cache (`*.pcm`) bakes the **absolute**
build path into each module. After the copy, the cached `SwiftShims` PCM still
points at the original worktree path, so the baseline build in `_mutated/` dies
with:

```
error: precompiled file '.../agent-..._mutated/.build/.../SwiftShims-....pcm' was
compiled with module cache path '.../agent-.../.build/.../ModuleCache/...', but the
path is currently '.../agent-..._mutated/.build/.../ModuleCache/...'
error: missing required module 'SwiftShims'
error: fatalError
```

Muter's `exclude:` list only controls which files are *mutated*, **not** what is
copied — so it cannot exclude `.build`. **Fix:** ensure no stale `.build` exists
in the tree muter copies (move/delete it first, or run muter from a clean
checkout). Muter then does one cold build in `_mutated/` and proceeds.

### Blocker B — XCTest + Swift Testing in one process (#681 race)
SwiftPM links *all* test targets into a single test executable. ManifoldKit
deliberately keeps Swift Testing suites (`ManifoldInferenceSwiftTestingTests`)
in a separate target and runs them in a separate process, because mixing the two
runners in one process triggers a libmalloc double-free `SIGABRT` (~25% of runs,
#681). Muter issues a single `swift test` command per mutant. If that command
lets both runners execute, ~1 in 4 mutant runs aborts — and muter scores a
crashed run as a **killed** mutant, silently *inflating* the score.

**Mitigation used here:** the muter test command filters to **XCTest-only**
suites (`ManifoldRuntimeTests.*`). The two target suites
(`ManifoldRuntimeTests`, `ManifoldInferenceTests`) are 100% XCTest — verified:
0 files `import Testing`, all `import XCTest`. With the filter, no `@Test`
function executes. Caveat: the Swift Testing *runtime still initialises* in the
process (observable as a trailing `Test run with 0 tests ... passed` line), so
the race window is **reduced, not eliminated**. A long unattended run should
expect the occasional spurious abort. Fully eliminating it needs a dedicated
test product that does not link the Swift Testing target — out of scope for this
spike.

### Blocker C — traits / MLX / Llama / Metal
Default traits pull in MLX + Llama. MLX needs the Metal `metallib` (absent
headless → process abort); `llama_backend_init` is process-global. Mutation
testing must be deterministic and headless, so every command passes
`--disable-default-traits`. The two target modules (`ManifoldInference`,
`ManifoldRuntime`) carry **no** ML deps, so they build and test fully under
trait-disabled mode.

---

## 2. The other feasibility wall: per-mutant cost

Muter re-runs the test command **once per mutant**. The scoped, trait-disabled
combined XCTest suite for the two modules is large and slow:

| Test command | Tests | Wall time |
|---|---|---|
| `swift test --disable-default-traits --filter ManifoldRuntimeTests --filter ManifoldInferenceTests` | 1758 | **387 s** (~6.5 min) |
| Tight turn-loop subset (`ConversationRuntime*` + `TurnContext` + `TurnInputCollapse`) | 68 | **4.6 s** |

At 6.5 min/mutant a few hundred mutants is **30–90 hours** — infeasible. The
spike is therefore only viable against a **tight, hand-picked test subset** that
still genuinely exercises the mutated code. That is the trade-off baked into
`.muter.conf.yml`: a focused turn-loop XCTest cluster, ~seconds per mutant.

---

## 3. Configuration used

`.muter.conf.yml` (committed at repo root):

- `executable: /usr/bin/swift`
- `arguments:` `test --disable-default-traits` + a `--filter` list naming the
  turn-loop XCTest classes (ConversationRuntime/TurnInput/TurnContext/Scripted
  backend/GenerationHook/compression). XCTest-only → Blocker B mitigated.
- `coverageThreshold: 0` (baseline measurement, not a gate)
- `mutationTestTimeout: 120` (a turn-loop mutation can infinite-loop; cap it)

Tool: **muter v16** (operators available in v16: `RelationalOperatorReplacement`,
`RemoveSideEffects`, `ChangeLogicalConnector`, `SwapTernary`). Built from source —
there is no Homebrew formula (`brew install muter` fails). Note v16 dropped the
older boolean-literal / negate-conditionals operators, so reported mutant counts
are conservative.

---

## 4. Reproduce

```sh
# 1. Build muter v16 from source (no brew formula).
git clone --depth 1 https://github.com/muter-mutation-testing/muter.git /tmp/muter-src
( cd /tmp/muter-src && swift build -c release )
MUTER=/tmp/muter-src/.build/arm64-apple-macosx/release/muter

# 2. From the ManifoldKit worktree root: remove stale .build (Blocker A).
mv .build /tmp/mk-build-bak      # or: scripts/clean-build.sh, or a fresh checkout

# 3. Size the run without testing — discover/count mutants only.
#    (mutate-without-running takes no --files-to-mutate; use `run` for scoping.)

# 4. Run a bounded baseline scoped to the turn-loop files + the tight suite.
$MUTER run \
  --configuration .muter.conf.yml \
  --files-to-mutate Sources/ManifoldRuntime/Services/ConversationRuntime.swift \
  --files-to-mutate Sources/ManifoldRuntime/Services/ConversationTurnExecutor.swift \
  --skip-coverage --skip-update-check \
  --format json --output /tmp/muter-turnloop.json
```

`--skip-coverage` avoids muter's extra full-suite coverage pass (we hand-picked a
covering suite). `--skip-update-check` avoids a network call. Muter writes
`<worktree>_mutated/` as a side effect — delete it afterwards.

---

## 5. Results

**Headline: the score muter produced is invalid — do not trust it.** Muter ran
to completion and emitted a clean-looking report, but every mutation was a
**false survivor**. The number is a trap, not a baseline.

### What muter reported
Scoped to `ConversationRuntime.swift` + `ConversationTurnExecutor.swift`, tight
turn-loop XCTest cluster, `--skip-coverage`:

| Metric | Value |
|---|---|
| Mutants discovered | **62** (2 in ConversationRuntime, 60 in ConversationTurnExecutor) |
| Mutants killed | **0** |
| **Reported mutation score** | **0%** |
| Operators | RemoveSideEffects, ChangeLogicalConnector, RelationalOperatorReplacement, SwapTernary |

A 0% score *looks* like "the turn loop has no effective test coverage." That
conclusion is **wrong**.

### Validation proved the 0% is a harness artifact
Following the codebase sabotage-verify discipline, one of muter's own
"survived" mutants was applied by hand to the real source:

```swift
// ConversationTurnExecutor.swift:1041 — muter's ChangeLogicalConnector mutant, reported "survived"
- } else if accumulator.isEmptyResponse && !hasToolContent {
+ } else if accumulator.isEmptyResponse || !hasToolContent {
```

Running the same turn-loop suite against that hand-applied mutation:

- **Unmutated baseline:** 59 tests, 0 failures (green).
- **Mutation applied:** `test_singleSend_persistsAssistantMessageContainingNonce`,
  `test_failedAssertion_isReportedNotThrown` and others **fail**, plus a
  `Fatal error: Index out of range` crash.

So the suite **does** kill this mutant. Muter said it survived. The verdict was
false.

### Root cause
Inspecting muter's `<worktree>_mutated/` working copy after the run:
`ConversationTurnExecutor.swift:1041` was **byte-for-byte the original** (`&&`
intact), and the file contained **no mutation/schemata guards anywhere**
(`grep` for `MUTATION`/`MUTANT`/`schemata`/`ProcessInfo…environment[` → 0 hits).
Muter's mutation **insertion step silently no-op'd**: it parsed the source and
enumerated 62 mutants (SwiftSyntax worked), but never wrote them into the code it
built and tested. Every "mutant run" therefore executed the pristine baseline →
all tests passed → all mutants "survived" → a uniform, meaningless 0%.

This is the dangerous failure mode of dropping a mutation tool onto an
unfamiliar build: it fails **open** (reports a clean 0% / no-coverage) rather
than erroring out. Muter v16 here is incompatible with this package's build in a
way that is invisible from the report alone — most likely the Swift 6.3 / SwiftPM
+ macro (`@ToolSchema`) + trait-conditional combination versus what muter v16's
schemata code generation expects (v16 predates this toolchain).

> The single most useful artifact from this spike is therefore **not a score** —
> it is the demonstration that muter's score on this package is silently bogus,
> and the exact validation step (apply a reported survivor by hand, run the
> suite) that any future mutation-testing attempt here MUST pass before its
> numbers are believed.

### Confirmatory experiment: is `--skip-coverage` the cause?
To rule out flag misuse, the run was repeated on `ConversationTurnExecutor.swift`
**with coverage enabled** (no `--skip-coverage`, so muter adds
`--enable-code-coverage` and runs its coverage pass first):

| Run | Flag | Discovered | Killed | Score | Schemata injected into `_mutated/`? |
|---|---|---|---|---|---|
| A | `--skip-coverage` | 62 | 0 | 0% | No |
| B | coverage on | 60 | 0 | 0% | No |

Identical broken outcome. The `--skip-coverage` flag is **not** the trigger — the
mutation-insertion no-op happens either way. (Run B discovers 60 not 62 because
it scoped to the executor file alone; the 2 ConversationRuntime mutants are
omitted.) This confirms the incompatibility is in muter v16's mutation
application on this Swift 6.3 / SwiftPM build, not in how it was invoked.

---

## 6. Recommendation

**Do not adopt `muter` v16 for ManifoldKit as-is, and never as a CI gate.** It
fails open — a green-looking 0% that is actually "mutations were never applied".
A tool whose failure mode is indistinguishable from "your tests are worthless"
is worse than no tool until that mode is closed.

Concrete path, in priority order:

1. **Mandatory trust gate for any mutation tooling here.** Before believing *any*
   score, apply one reported-survivor mutant by hand and run the suite (the
   exact check in [§5](#5-results)). If the suite kills it, the tool's "survived"
   verdict is bogus and the run is void. This 2-minute check would have caught
   the false 0% immediately.
2. **Diagnose / pin muter compatibility before re-attempting.** The insertion
   no-op is most likely a Swift 6.3 vs muter-v16-schemata mismatch.
   `--skip-coverage` is already ruled out (§5 confirmatory table — both modes
   fail). Remaining options, cheapest first: (a) pin an older Swift toolchain
   that muter v16 was validated against (via `xcode-select` / a toolchain
   override) and re-verify with the §5 trust gate; (b) try a newer or older
   muter release and re-verify; (c) abandon muter and evaluate a different
   approach (e.g. a small in-house mutation harness that edits the source on
   disk and re-runs the tight suite — exactly the manual step that worked in §5,
   automated). Whatever the tool, it is only trustworthy once a known-killable
   mutant is demonstrably killed.
3. **If a working configuration is found, keep it a manual, scoped spike** —
   `.muter.conf.yml` + `--files-to-mutate`, tight XCTest cluster, seconds per
   mutant — run on demand before a turn-loop refactor. Always clear `.build`
   first (Blocker A); prefer a throwaway `git worktree add --detach` checkout.
   Treat the *list of true survivors* as the deliverable, not the percentage.
4. **A CI gate is a non-starter** until both the insertion bug (this section) and
   the #681 dual-runner race (Blocker B — needs a dedicated XCTest-only test
   product in `Package.swift`) are resolved. Each is its own piece of work.

### Files left by this spike
- `.muter.conf.yml` — the scoped config (kept; documents the intended shape).
- `docs/MUTATION-BASELINE-2026-06.md` — this doc.
- `.gitignore` — added `muter_logs/` and `*_mutated/` so muter run artifacts
  can't be committed by accident.
- Muter writes `<worktree>_mutated/` and `muter_logs/` at run time; both are
  gitignored and safe to delete.
