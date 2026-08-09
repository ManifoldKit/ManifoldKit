# scripts/

Inventory of every script in `scripts/`, its one-line purpose, and where it runs.
Derived by reading each script's header comment plus `git grep -l '<script>' .github/workflows/`
— re-run that grep if this table drifts.

**Invocation context** legend:

- **CI-only** — invoked exclusively by a GitHub Actions workflow; not part of the local pre-push gate.
- **Local pre-push** — part of (or invoked by) `scripts/test.sh --profile local`, the mandatory gate
  before every push (see the repo `CLAUDE.md` "Pre-push checklist").
- **Manual / operational** — run by hand, ad hoc, when a maintainer needs it. Never wired into CI.

## Conventions (audit-enforced)

`ScriptFailOpenAuditTest` (in `ManifoldCoreTests`) scans every `*.sh` here for
fail-open idioms — machinery whose failure mode is silence must not swallow the
errors it exists to surface, because fail-open code cannot go red and a green
run is indistinguishable from an inert one:

- **`set -euo pipefail`**, somewhere in the file. Deviating on purpose
  (report-all-failures sweeps, sourced libraries)? Put
  `# fail-open-ok: <reason>` on the `set` line, or — when there is no `set`
  line at all — on a comment line in the first 80 lines.
- **`set +e`** must be re-armed with `set -e` (the capture-`$?` idiom).
- **`|| true` / `|| :`** is allowed only when the discarded status belongs to a
  tolerant command (`grep`, `kill`, `rm`, `comm`, `head`, … — see the audit's
  `tolerantCommands`) or the line carries / sits within three lines below a
  `# fail-open-ok: <reason>` marker. There is **no** idiom escape for masked
  `swift build|test|run` / `xcodebuild` — a swallowed build failure silently
  benchmarks a stale binary.
- A bare `fail-open-ok:` with no reason is itself flagged — the reason is the
  point.

## Cold-start conformance / import gates

The six `cold-start-*.sh` entry points are thin wrappers around the parametric
`cold-start.sh` core (extracted in this PR — see `scripts/_lib/consumer-scaffold.sh`).
Each one scaffolds a fresh SwiftPM consumer in a tmpdir, links ManifoldKit by local path,
builds, and runs an executable target that proves some slice of the public surface works
from *outside* the monorepo. See [`docs/QA-PRACTICES.md`](../docs/QA-PRACTICES.md) and
[`Tests/README.md`](../Tests/README.md#cold-start-conformance-gates) for the full rationale.

| Script | Purpose | Invocation context |
|--------|---------|---------------------|
| `cold-start.sh` | Parametric core (`--tier 1\|2\|3`, `--module mcp\|voice\|uimodelmanagement`) shared by the six wrappers below. Not called directly by CI. | CI-only (via wrappers) |
| `cold-start-conformance.sh` | Tier 1 — public consumer surface: `InferenceService`, `InferenceBackend`, `GenerationStream` via a tiny inline fake backend. | CI-only (`ci.yml`, `nightly-slow-tests.yml`) |
| `cold-start-tier2-bootstrap.sh` | Tier 2 — `ManifoldBootstrap` → `ChatViewModel` orchestration; drives one user → assistant turn via `vm.inputText` + `vm.sendMessage()`. | CI-only (`ci.yml`, `nightly-slow-tests.yml`) |
| `cold-start-tier3-chatview.sh` | Tier 3 — `ManifoldUI` `ChatView` composition: `@State`/`.environment(_:)` view models, the `apiConfiguration:` view-builder closure, theming seams. | CI-only (`ci.yml`, `nightly-slow-tests.yml`) |
| `cold-start-specialised-mcp.sh` | Import gate — `ManifoldMCP` as a standalone product dependency (`MCPServerDescriptor`, `MCPTransportKind`, `MCPToolSource`). | CI-only (`ci.yml`, `nightly-slow-tests.yml`) |
| `cold-start-specialised-voice.sh` | Import gate — `ManifoldVoice` as a standalone product dependency (`VoiceError`, `VoiceCaptureState`, `SpeechTranscribing`/`SpeechSynthesizing`). | CI-only (`ci.yml`, `nightly-slow-tests.yml`) |
| `cold-start-specialised-uimodelmanagement.sh` | Import gate — `ManifoldUIModelManagement` as a standalone product dependency (`ModelManagementViewModel`, `ModelImportError`, `DocumentLibraryViewModel`). | CI-only (`ci.yml`, `nightly-slow-tests.yml`) |
| `cold-start-human.sh` | Tier 4 — the "human path": asserts README.md's first H2 is `## Hello World` and compiles its first ```` ```swift ```` block against the current package. Structurally different from tiers 1-3 (Markdown parsing, no `swift run`); reuses only `cs_swift_build` from the shared lib. | CI-only (`nightly-slow-tests.yml`, `cold-start-human.yml`) |

`cold-start-human.yml` restores its persistent build path by exact key only,
with a UTC-day key generation. PR-scoped cache entries are not visible to other
PRs, so a broad fallback can silently select a stale `main` build directory;
an unchanged exact key can do so after weeks as well. A clean miss is
intentional; the workflow logs the current key and either `provenance: none` or
the restored cache's ID, `createdAt`, and ref before compiling the README
snippet. At the next UTC day, an old build directory is ineligible.

## Test running & CI gating

| Script | Purpose | Invocation context |
|--------|---------|---------------------|
| `test.sh` | Runs `swift test` and prints an honest summary (swift test's own summary silently drops signal-11 crashes and XCTSkip counts). The load-bearing pre-push gate — see `CLAUDE.md` "Pre-push checklist". | Local pre-push + CI (`ci.yml`, `ci-required-test-shim.yml`, `build-modes.yml`, `readme-snippets.yml`, `nightly-slow-tests.yml`) |
| `ci-test-with-watchdog.sh` | Runs `test.sh` under a stall watchdog — `swift test --parallel` parks every worker if one test hangs, and the job-level `timeout-minutes` is too coarse to localize which suite stalled. | CI-only (`ci.yml`, `ci-required-test-shim.yml`) |
| `affected-suites.sh` | Tier 0 selective-testing resolver: maps changed paths to the subset of per-PR test-job suites that could be affected, using a committed SwiftPM target-dependency-graph snapshot (`affected-suites-graph.json`). | CI-only (`ci.yml`, `ci-required-test-shim.yml`) |
| `ci-selective-test.sh` | Tier 2 compile-pruned selective CI runner — receives Tier 0's affected-suite list and routes each suite to the fastest correct test path (scheme vs. `swift test --filter`). | CI-only (`ci.yml`, `ci-required-test-shim.yml`) |
| `build-modes.sh` | Builds ManifoldKit in each documented build mode (traits on/off combinations) and optionally runs a binary symbol audit. Entry point for the build-mode CI matrix; also usable for local repro. | CI-only, local-repro capable (`build-modes.yml`) |
| `example-ui-tests.sh` | `build-for-testing` / `test-without-building` wrapper for the Example app's XCUITests. | CI + local (`ci.yml`, `ci-required-test-shim.yml`, `example-ui-smoke.yml`) |
| `test-ios-simulator.sh` | Runs `ModelContainerFileProtectionTests` on a real iOS Simulator via `xcodebuild` — `NSFileProtection*` is an iOS kernel feature the macOS `swift test` lane can't exercise. | CI-only (`ci.yml`, `ci-required-test-shim.yml`) |
| `test-sandboxed.sh` | Runs the local-only test suites under `sandbox-exec` with a net-deny profile — catches traffic that bypasses `URLSession` (raw sockets, `getaddrinfo`, mDNS, `Process.launch` of curl). | Manual / operational (no current workflow caller; Phase 5 of #714) |
| `check-coverage.sh` | Verifies per-module line coverage against thresholds from a `.profdata` + xctest binary (auto-discovered under `.build/` if not passed explicitly). | CI-only (`ci.yml`, `nightly-slow-tests.yml`) |
| `lint-no-new-force-unwraps.sh` | Fails CI if a force-unwrap (`!`/`try!`/`as!`) appears in production `Sources/` code outside the reviewed allowlist. | CI-only (`ci.yml`, `ci-required-test-shim.yml`) |
| `audit-availability.sh` | Flags `@available`/`#available` annotations that exceed the Package.swift platform floors (macOS 15 / iOS 18) without an explicit OS-floor elevation. | CI-only (`lint.yml`) |
| `lint-docs-headers.sh` | Cheap Bash mirror of `DocsAudienceStatusAuditTest` — fails if a top-level `docs/*.md` is missing a valid `Audience:`/`Status:` header. Lives in Lint so docs-only PRs (which skip the paths-filtered macOS `test` job) still get the check before the merge queue. | CI-only (`lint.yml`) |
| `check-readme.sh` | Lints the README's API references against the current package — the tripwire that stops stale snippets from creeping back in. | CI-only (`readme-snippets.yml`, `lint.yml`) |
| `check-swift-toolchain.sh` | Parses `swift-tools-version` from `Package.swift` and cross-checks it against the installed `swift`/`xcrun swift` version. | CI-only (`release-provenance.yml`, `release-provenance-rehearsal.yml`) |
| `extract-snippets.sh` | Extracts fenced ` ```swift ` blocks from README.md, `docs/QUICKSTART*.md`, `docs/WHY-MANIFOLDKIT.md`, and DocC catalogs into standalone `.swift` files for downstream compilation. | CI-only (`readme-snippets.yml`) |
| `extract-snippets-test.sh` | Companion to `extract-snippets.sh` — scaffolds a single SwiftPM consumer package with one executable target per kept snippet and runs `swift build` once (batches the doc-snippet gate; see `CLAUDE.md` "Doc-snippet gate batching"). | CI-only (`readme-snippets.yml`, `nightly-slow-tests.yml`) |

## Release & provenance

| Script | Purpose | Invocation context |
|--------|---------|---------------------|
| `demo-apps-build.sh` | Pre-release gate: builds both example apps (Advanced iOS, Minimal iOS + macOS) and prints a pass/fail summary. Mandatory before bumping the release version (`CLAUDE.md` "Pre-bump demo-app gate"). | Manual / operational (release-time only, not per-PR) |
| `generate-sbom.sh` | Emits a CycloneDX 1.5 SBOM for the ManifoldKit Swift package (hand-rolled — SwiftPM has no machine-readable dependency surface `cyclonedx-bom`/`swift-sbom-action` can consume directly). | CI-only (`release-provenance.yml`, `release-provenance-rehearsal.yml`) |
| `migration-index-check.sh` | Two-mode gate over `docs/MIGRATION-INDEX.md`: completeness (every `docs/MIGRATION-*.md` has a table row) always; `--release` additionally fails on any row still marked `next` in the Release column, which must be flipped to the version being shipped. The completeness half is the cheap mirror of the authoritative `MigrationIndexAuditTest`; the `--release` half is release-gated only, not an in-suite audit. | Manual / operational (release-time gate; completeness half also enforced per-PR by `MigrationIndexAuditTest`) |

## Fuzz harness

| Script | Purpose | Invocation context |
|--------|---------|---------------------|
| `fuzz.sh` | Runs the ManifoldFuzz harness with a friendly preflight (default: 5 min against Ollama). CI cadence is weekly-only; run locally when adding a new backend/model family. | CI (weekly) + manual (`fuzz-weekly.yml`) |
| `fuzz-ci-gate.sh` | Gates a fuzz campaign's findings JSON against an allowlist; exits non-zero on any unallowlisted finding. | Manual / operational (documented in `FUZZING.md`; not wired into a workflow) |

## MCP fixtures

| Script | Purpose | Invocation context |
|--------|---------|---------------------|
| `regenerate-mcp-fixtures.sh` | Generates deterministic, offline MCP provider fixtures (github/linear/notion) used by `ManifoldMCPTests`. `--check` mode verifies fixtures are up to date without writing. | CI (`ci.yml`'s `mcp-fixture-check` job, path-gated on the fixture directory / this script; nightly `queue-merge-backstop` runs it unconditionally as the merged-tree backstop) + manual (run by hand when provider fixtures need regenerating) |

## Docs & metrics generation

| Script | Purpose | Invocation context |
|--------|---------|---------------------|
| `render-feature-matrix.sh` | Renders `docs/FeatureMatrix.md` from `FeatureMatrix.swift` (shells out rather than calling the public API directly — see the script's own rationale for why). | Manual / operational (no workflow caller found; run by hand after `FeatureMatrix.swift` changes) |
| `measure-trait-costs.sh` | Measures the per-trait binary size, build time, and dependency weight of each SwiftPM trait; renders `docs/trait-costs.json` + `docs/TRAIT-COSTS.md`. | Manual / operational (no workflow caller found) |
| `qa-telemetry.sh` | Self-instrumentation for CI cost/QA health — queries the GitHub Actions API over a trailing window and computes run-count/re-run-tax metrics. | CI-only (`qa-telemetry.yml`, scheduled) |
| `sourcekit-stale-module-diagnostics.sh` | Exercises the SourceKit stale-module diagnostic repro path (issue #1109) in an isolated scratch path, without touching `.build` or DerivedData. Dry-run by default; `--run` executes. | Manual / operational (diagnostic tool) |

## Local developer hygiene

| Script | Purpose | Invocation context |
|--------|---------|---------------------|
| `clean-build.sh` | Full `.build` wipe + `swift package resolve`. Use when a build fails with "XCFramework Info.plist not found" or other `workspace-state.json` desync errors. | Manual / operational |
| `clean-leaked-test-artifacts.sh` | Removes model-artifact files tests historically leaked into the demo app's `Documents/Models` directory (see #379). | Manual / operational |
| `cleanup-merged-branches.sh` | Removes stale local branches: merged branches and leftover `worktree-agent-*` branches. | Manual / operational |
| `benchmark.sh` | ManifoldKit backend throughput benchmark suite (TTFT, tokens/sec) rendered as a Markdown table. Explicitly documented as local-only — never run in CI. | Manual / operational |
| `local-integration-sweep.sh` | Repeatable real-model integration + perf sweep across core + companion packages on local Apple Silicon hardware — the one tier of behavior CI's mocked backends can't cover. Preflight-gated: probes companion repos/Ollama/eval-role models/corpora before any lane runs, and exits non-zero if a requested lane did no real work. Run by hand, not scheduled. | Manual / operational |
| `record-fixture.sh` | Captures a backend SSE/NDJSON response from stdin with redaction applied, for use as a test fixture. | Manual / operational |
| `migrate-uimm-imports.sh` | One-off codemod (v2.0 `ManifoldUIModelManagement` peel) that inserts `import ManifoldUIModelManagement` into files using a symbol that moved out of `ManifoldUI`. Historical; kept for reference. | Manual / operational (historical, one-off) |
| `split-proof.sh` | B5 out-of-package compile proof for the companion-package split (#1749). **Retired at v0.48 PR C2** — the MLX/Llama families it proved now live in their own repos. Kept for historical reference only. | Retired — not invoked anywhere |

## Shared library (not an entry point)

| Path | Purpose |
|------|---------|
| `_lib/consumer-scaffold.sh` | Sourced-only helper library for the cold-start gates: scratch-workdir setup + cleanup trap, `Package.swift` scaffolding, and `swift build`/`swift run` wrappers that capture exit codes correctly (never pipes a build through `tail` and reads `$?` afterwards). Not executable as a standalone script — `source` it. |

## Subdirectories with their own docs

These aren't top-level scripts but self-contained tool directories, each with its own README:

| Directory | Purpose |
|-----------|---------|
| [`dx-walkthrough/`](dx-walkthrough/README.md) | DX walkthrough harness — one of the four cross-cutting QA practices (see `docs/QA-PRACTICES.md`). |
| [`perf-audit/`](perf-audit/README.md) | Performance-audit summarization tooling. |
| `bench/` | `http-bench.py` — ad hoc HTTP benchmarking helper. |
| `migrate-uimm-imports-tests/` | Fixture-driven tests for `migrate-uimm-imports.sh`. |

## Data files (not scripts)

| Path | Purpose |
|------|---------|
| `affected-suites-graph.json` | Committed SwiftPM target-dependency-graph snapshot consumed by `affected-suites.sh` (Tier 0 selective testing). Regenerate when the target graph changes; see `affected-suites.sh` for how. |
