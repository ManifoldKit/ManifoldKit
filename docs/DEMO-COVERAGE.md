# Demo coverage gate

**Audience:** contributor
**Status:** living

The instrument milestone M0 of the demonstration program
([issue #2453](https://github.com/ManifoldKit/ManifoldKit/issues/2453))
reports through. It answers one question per ManifoldKit capability: can a
reader actually see this working, find the doc for it, and trust that the doc
and the vehicle haven't silently drifted apart?

## The three requirements

Every capability in `scripts/demo-coverage-manifest.tsv` is scored against:

- **R1 — demonstrated by a runnable vehicle.** `vehicle_kind` is something
  other than `none`: an example app, a focused example, a script, a scenario,
  or an external (companion-repo) vehicle.
- **R2 — documented with a link that can't drift.** `doc` names a repo-relative
  file that exists on disk right now. A doc reference that has rotted away
  fails this the moment the file is deleted or moved, not months later.
- **R3 — a declared execution route, not just a labelled one.** Two
  conditions, both required: `lane` is one of the *executed* lanes —
  `per-pr`, `release-gate`, `live-e2e`, `weekly`, `external` — naming the CI
  workflow, script, or test (`lane_ref`) that fires the vehicle, **AND**
  `exec_kind` is `live` or `scripted` (never `compile`). A row whose lane
  fires per-pr but whose own invocation only *compiles* the vehicle (e.g.
  `xcodebuild build-for-testing`, never `test`) is NOT executed — the whole
  test suite it compiles could go red and this row would still read green.
  `exec_kind` is the fix: it names what the row's OWN `lane_ref` actually
  *does* when it fires, not just when it fires. Where the lane names a test
  file or a workflow, R3 is further **method-bound**: `lane_methods` records
  the exact method(s) that exercise the capability, so the route is a named,
  checkable claim — not a suite-level assumption. See "exec_kind" and
  "lane_methods" below.

  **R3 is a declared route, not a freshness signal.** It does not assert the
  lane ran recently, or that it's currently green — only that a real
  execution path is named and (where method-bound) that the named methods
  exist and are wired where claimed. Last-run / staleness evidence (did this
  lane actually run in the last N days, and did it pass) is a later
  milestone (M5).

  **`manual` does NOT satisfy R3** (its `exec_kind` is irrelevant to the
  score — `lane` alone excludes it). "A human can run this" is real signal —
  the manifest still records it and the scoreboard still counts it — but it
  is not execution: nothing catches a manual-lane vehicle silently rotting
  between runs. The scoreboard reports the R3 (executed) count and the
  manual-only count as two separate numbers so the difference stays visible.

  **`exec_kind`** (the column between `lane_methods` and `notes`) names what
  the invocation actually does when it fires:
  - `live` — drives a real backend or system (a real Ollama server, a real
    MCP subprocess, a human doing ad hoc QA against the real app).
  - `scripted` — executes with scripted/mock backends (a UI test against
    canned demo scenarios, a deterministic-lane golden-scenario replay).
  - `compile` — build-only; compiles/links but asserts nothing ever runs.
    Requires a `notes` entry saying where real execution would come from (or
    `-` if there's no path to it today) — `--check` enforces this, and
    forbids a non-empty `lane_methods` on a `compile` row (nothing executes,
    so no method can be listed).
  - *(empty)* — valid only when `lane` is `none`; nothing fires at all.

  Re-auditing `exec_kind` means reading the actual workflow/script `lane_ref`
  names, not inferring from the row's title — `scripts/demo-coverage-manifest.tsv`
  records the specific evidence per row (e.g. "DemoScenarioUITests methods
  are not among example-ui-smoke.yml's weekly `-only-testing` entries").

  **`lane_methods`** (the column between `lane_ref` and `exec_kind`) is a
  comma-separated list of `Suite/method` entries — the exact XCTest methods
  that exercise the capability. Empty is allowed for non-test lanes (a
  generic runner script, a companion/external CI system this repo can't see
  into, prose-manual QA). It is **required** (non-empty) when `exec_kind` is
  `live`/`scripted` and `lane_ref` contains a bare `.swift` test-file path —
  R3 for a test-file row must be method-bound, not a suite-level assumption.
  **This is a review convention, not something `--check` enforces.** The
  trigger keys on a bare `.swift` element literally being present in
  `lane_ref` — so a row can still leave the vehicle's own `.swift` path out
  of `lane_ref`, naming only a workflow or generic script instead, and
  `--check` will not flag the resulting empty `lane_methods`; nothing ties
  "the vehicle is a test file" to "`lane_ref` must name it." Closing that gap
  properly means keying the requirement off `vehicle_path` being test-shaped
  instead of `lane_ref` containing a bare `.swift` element, and that is not a
  one-line change (a naive version would newly misclassify existing rows,
  e.g. `theming`) — out of scope here. Until it closes, treat an unbound
  test-shaped vehicle as a real review finding, the same way `manual` not
  satisfying R3 is a real review finding even though nothing computes it
  automatically.

  When present, every entry is checked. `Suite` resolves against a suite
  *file*: first, a bare `.swift` element in the row's OWN `lane_ref` whose
  basename matches `Suite` (a capability whose tests live outside
  `Example/AdvancedUITests`, e.g. under `Tests/`, names its own suite file
  this way — the `toolschema-macro` row is the first to do this, #2453 M3);
  failing that, the historical `Example/AdvancedUITests/<Suite>.swift`
  default (every UI-test-bound row, which never lists its own suite file in
  `lane_ref`). Once resolved, the method must exist in that file
  (`grep 'func <method>('`). If `lane_ref` also names a workflow (a `.yml`
  element), the entry must ALSO be reachable through that workflow's
  invocation — checked one of two ways depending on where the suite
  resolved: an `Example/AdvancedUITests/*` suite must appear in the
  workflow's exact `-only-testing:AdvancedUITests/Suite/method` list; any
  other suite must be reachable through a `--filter <pattern>` argument in
  the workflow that matches `Suite/method` (the full pair, not just `Suite`)
  as a substring — the real semantics of `swift test --filter`/`scripts/
  test.sh --filter`, which is a regex over the qualified test name, not an
  exact list. Matching the full pair (rather than `Suite` alone) matters: a
  workflow filter naming one method (`--filter Suite/testA`) must not also
  bind a sibling method (`Suite/testB`) that the workflow never actually
  runs. Otherwise a row could claim CI coverage the workflow doesn't
  actually give it.

  For a non-`Example/AdvancedUITests` suite, a matching `--filter` is not
  the whole story: `swift test`/`scripts/test.sh` also accept `--skip
  <pattern>`, which excludes matches from an already-filtered set, so the
  check also verifies no `--skip` argument in the workflow matches the
  claimed `Suite/method`. This check is itself **fail-closed**: it can only
  parse a bare unquoted `--skip` value (`--skip test_a`), so a quoted value
  (`--skip 'test_a'`/`--skip "test_a"`), the `--skip=test_a` equals form, or
  a regex value starting with punctuation (`--skip .*test_a`) all count as
  "an unparseable `--skip` is present" and fail the row with a named
  "cannot verify" violation rather than silently reading as "not skipped."
  (Known, deliberately unfixed parallel gap: the `-only-testing:` UI-test
  path above is checked only for the claimed `Suite/method`'s presence, not
  for a co-occurring `-skip-testing:` argument that could exclude it — no
  manifest row's `lane_ref` uses `-skip-testing:` today, so there's no
  current exposure.)

A fourth signal, not per-row and **not ratcheted** (see `--check` below):
**lexical public-type mentions** — of every public type ManifoldKit ships
(per module, read from the API-freeze baseline under
`Tests/APIFreezeTests/api-surface-baseline/`), how many are ever named by an
identifier somewhere under `Example/**/*.swift`. A type nobody's example code
ever spells is a type no demo vehicle can be proving works — this is a
lexical (textual-mention) signal, not a proof of execution, hence the name.
This is computed by `scripts/_lib/demo-coverage-types.py` and reported as an
aggregate percentage alongside the per-capability table, informationally.
`scripts/demo-coverage.sh --check` never invokes this helper at all — R1/R2/R3
come entirely from the manifest — so a defect in the helper can never affect
`--check`. The helper itself fails closed: a missing/empty api-surface-baseline
directory, a missing Example directory, zero identifiers collected, an
unreadable input file, or a baseline line that doesn't parse are all fatal
(non-zero exit, named error) rather than silently reported as `0/0`.

## The manifest

`scripts/demo-coverage-manifest.tsv` is a tab-separated file, one row per
capability:

```text
id  title  products  vehicle_kind  vehicle_path  doc  lane  lane_ref  lane_methods  exec_kind  notes
```

- `vehicle_kind` is one of: `example-app`, `focused-example`, `script`,
  `scenario`, `external`, `none`.
- `lane` is one of: `per-pr`, `release-gate`, `live-e2e`, `weekly`, `manual`,
  `external`, `none`.
- `vehicle_path` and `doc` are repo-relative paths (`vehicle_path` may name a
  directory); `lane_ref` names the workflow, script, or test that executes the
  vehicle. `lane_ref` must be empty when `lane` is `none`, and set (non-empty)
  for every other lane.
- `lane_methods` is a comma-separated `Suite/method` list — see above.
- `exec_kind` is one of: `live`, `scripted`, `compile` — empty if and only if
  `lane` is `none`. See "R3" above for the definitions and the R3 formula.

**`lane_ref` path convention.** `lane_ref` may be a comma-separated list
(e.g. multiple UI test files that together cover one capability). Each
comma-separated element is checked independently: an element that **looks
like a path** — it contains `/`, or ends in `.yml`, `.swift`, or `.sh` — is
treated as a promise that file exists, and `--check` fails if it doesn't.
An element that doesn't look like a path (`RUN_MCP_E2E=1 swift test --filter
ManifoldMCPE2ESmokeTests`, `companion CI`) is free text and is never checked.
**Exception:** for `lane: manual` or `lane: external` rows, `lane_ref` is
never checked for existence even when it looks path-shaped — those lanes
routinely carry prose that happens to contain a `/` (e.g. `"manual QA — no
named script/test"`) without being a path promise at all. If a `lane_ref`
combines a real path with a trailing annotation (e.g. "which specific test
method, opt-in only"), put the path alone in `lane_ref` and the annotation in
`notes` — don't append it to `lane_ref` on a `per-pr`/`release-gate`/
`live-e2e`/`weekly` row, since the whole comma-separated element is checked
verbatim, not just its leading token.

A capability that has no demo vehicle yet (`vehicle_kind: none`) is not a
failure — the roster deliberately carries rows tagged for a later milestone
(`M2`/`M3`/`M4` in the `notes` column) and rows for functionality that was
retired outright (e.g. `ManifoldSkills`, `ManifoldAnyLanguageModel`) and has
no vehicle planned at all. The gate's job is to keep the roster **honest**,
not to force every row green immediately.

## Product completeness

`--check` also audits `Package.swift`: every `.library(`/`.executable(`
product it declares must be named in some manifest row's `products` column,
or listed — with a `# reason:` — in
`scripts/demo-coverage-product-allowlist.txt`. Without this, a whole product
could ship with zero demo-coverage tracking and nobody would notice. The
allowlist follows the same convention as
`Tests/APIFreezeTests/inert-surface-allowlist.txt`: every entry needs a
reason, and a stale entry (the product no longer exists, or it's since
gained a manifest-row reference) fails the audit too.

## Running it

```bash
scripts/demo-coverage.sh
```

prints a human-readable scoreboard: the R1/R2/R3 table, then the per-module
lexical-public-type-mentions table with a `TOTAL` row.

```bash
scripts/demo-coverage.sh --markdown /path/to/scoreboard.md
```

writes the same content as a markdown file.

```bash
scripts/demo-coverage.sh --check
```

is the CI gate: it first checks manifest integrity — exact header (now 11
columns, `lane_methods` and `exec_kind` included), unique ids, non-empty
`title` (the one column with no other constraint that would otherwise catch
an empty value), valid enum values, every non-empty `vehicle_path`/`doc`
exists on disk, `vehicle_path` never equals `doc` (a doc is not a runnable
vehicle — this caught a real defect in the `app-eval` row, which originally
claimed `docs/APP-EVAL.md` as both its own doc and its own vehicle), `lane`
is `none` if and only if `lane_ref` is empty, `exec_kind` is `none` if and
only if `lane` is `none`, `exec_kind: compile` requires a non-empty `notes`
and forbids `lane_methods`, `lane_methods` is required when `exec_kind` is
live/scripted with a test-file `lane_ref` and every entry resolves (see
above), every path-shaped `lane_ref` element exists (see the convention
above), every data row has exactly 11 tab-separated columns (a wrong count
silently folds two columns together via `read`, which the column-count
check catches directly rather than relying on garbled output downstream),
and the product-completeness audit above — then compares the current
R1/R2/R3 state against `scripts/demo-coverage-baseline.tsv`. It fails,
naming the offending capability id, if any row's R1, R2, or R3 regressed
from met to unmet with no corresponding manifest edit (an **unaccompanied
regression**), or if a baseline capability disappeared from the manifest
outright. New rows are always allowed — the gate is a ratchet, not a fixed
target: its job is to catch a flag flipping silently, not to forbid a
flag flipping at all.

`current_state` is the single place R1/R2/R3 are scored — `--check` and both
scoreboard renderers (text, markdown) all consume its output and only
format, so the markdown scoreboard can never disagree with what the gate
itself enforces.

**The lexical-public-type-mentions percentage is NOT part of this ratchet**
— it is scoreboard-only. It legitimately moves in both directions for
reasons that have nothing to do with a demo-coverage regression: deleting an
unmentioned public type *raises* it, and adding one new public type
anywhere in the package *lowers* it (e.g. 104/905 → 104/906). Ratcheting a
number that any unrelated API-surface PR can push either way would produce
false reds and would make every routine `--update-baseline` call silently
neuter the ratchet rather than enforce it — so `scripts/demo-coverage-baseline.tsv`
holds only `id`, `r1`, `r2`, `r3` per row, nothing else.

```bash
scripts/demo-coverage.sh --update-baseline
```

regenerates `scripts/demo-coverage-baseline.tsv` from the current manifest and
tree. Run this after deliberately changing a row's R1/R2/R3 status (adding a
vehicle, moving a doc, wiring a new lane) and commit the updated baseline
alongside the manifest change.

`--manifest FILE` / `--baseline FILE` (or the `DEMO_COVERAGE_MANIFEST` /
`DEMO_COVERAGE_BASELINE` environment variables) override the default paths —
used by `DemoCoverageGateAuditTest`'s sabotage tests to point the real script
at a planted fixture tree instead of the real manifest.

## Where this runs

`DemoCoverageGateAuditTest` (in `ManifoldCoreTests`) runs
`scripts/demo-coverage.sh --check` and asserts it passes. `ManifoldCoreTests`
is force-included by `scripts/affected-suites.sh` whenever any `scripts/*.sh`
file changes (the blanket rule that also covers `ScriptFailOpenAuditTest`),
and `scripts/affected-suites.sh` carries an explicit case mapping so an edit
to either `.tsv` data file selects the same target — see AGENTS.md "a suite
that reads or executes a file must be selected when that file changes". That
mapping is only reachable when `ci.yml`'s `changes` job actually runs, so
`ci.yml`'s `push`/`pull_request` `paths:` lists (and the
`ci-required-test-shim.yml` `paths-ignore` mirror, kept in lockstep by
`lint.yml`'s `shim-drift` step) both explicitly name
`scripts/demo-coverage-manifest.tsv` and `scripts/demo-coverage-baseline.tsv` —
a manifest-or-baseline-only edit is a real per-PR trigger, not just a resolver
mapping that never gets consulted.

## See also

- [`docs/QA-PRACTICES.md`](QA-PRACTICES.md) for how this gate fits alongside
  the other cross-cutting QA practices.
- [Issue #2453](https://github.com/ManifoldKit/ManifoldKit/issues/2453) for
  the full demonstration-program roadmap this instrument reports through.
