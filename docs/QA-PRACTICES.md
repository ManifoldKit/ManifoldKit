# ManifoldKit QA practices

Four cross-cutting QA practices guard ManifoldKit beyond its unit / integration / E2E test pyramid. Each one catches a class of regression that ordinary tests miss. This page is the discovery doc — what each practice is, why it exists, how to run it, and how to extend it.

For day-to-day test conventions (suites, traits, layering), see [`Tests/README.md`](../Tests/README.md). For module/architecture rules and pre-push gates, see [`CLAUDE.md`](../CLAUDE.md).

| Practice | Scope | Lives at | Doc |
|---|---|---|---|
| DX walkthroughs | Forced-blindness fresh-developer DX regression | [`scripts/dx-walkthrough/`](../scripts/dx-walkthrough/) | [README](../scripts/dx-walkthrough/README.md) |
| Audit tests | File-walking discipline rules (19 files) | `Tests/*/Manifold*AuditTest*.swift` | this doc |
| Sabotage suite | Verifies the audit tests still catch what they claim | [`Tests/ManifoldAuditSabotageSuiteTests/`](../Tests/ManifoldAuditSabotageSuiteTests/) | this doc |
| Cold-start conformance gates | Public-surface tests run from a fresh consumer outside the repo | [`scripts/cold-start-*.sh`](../scripts/) | [Tests/README § Cold-start](../Tests/README.md#cold-start-conformance-gates) |

---

## 1. DX walkthroughs

**What.** A forced-blindness harness in [`scripts/dx-walkthrough/`](../scripts/dx-walkthrough/). Three agents play "fresh Swift developer", each follows an archetype brief (e.g. [`01-chat-cli.md`](../scripts/dx-walkthrough/briefs/01-chat-cli.md), [`02-swiftui-chat.md`](../scripts/dx-walkthrough/briefs/02-swiftui-chat.md)), and is forbidden from reading `Sources/Manifold*/**/*.swift` or `Tests/**`. They log friction as they go. Friction logs are synthesized into a per-iteration `SUMMARY.md` and diffed against prior iterations.

**Why.** In-tree tests cannot tell you whether a new developer with only `README.md`, `docs/`, and `Documentation.docc/` can ship a chat in 30 minutes. DX walkthroughs measure that directly. Recent runs (`scripts/dx-walkthrough/runs/2026-05-23_v0.33.0-iter*/`) caught broken doc snippets that compiled in-repo but referenced renamed types from outside the umbrella — those findings motivated the CI snippet-compile gate in PR #1417 and a string of fixes (#1392, #1393, #1397, #1401).

**Run it.**
```sh
scripts/dx-walkthrough/run.sh 01-chat-cli iter5
```
Scaffolds `runs/<date>_v<ver>_<label>/<archetype>/run-{1,2,3}/` and prints three self-contained dispatch prompts to hand to the Agent tool with `isolation=worktree`.

**Compare iterations.**
```sh
scripts/dx-walkthrough/compare.sh \
  runs/2026-05-23_v0.33.0/01-chat-cli \
  runs/2026-05-23_v0.33.0-iter4/01-chat-cli
```
Heuristic markdown diff; groups findings into Disappeared, Persisted, New.

**Extend.** Add a new archetype `.md` file under `scripts/dx-walkthrough/briefs/`. Keep the forced-blindness rule. The [walkthrough README](../scripts/dx-walkthrough/README.md) is the canonical reference.

---

## 2. Audit tests

**What.** A pattern: a single XCTest file walks `Sources/` (or `Package.swift`, or `.docc` articles) and grep-asserts a discipline rule. Each one bans an entire class of regression. As of writing there are 19 such files. Representative examples:

| Audit | Rule it enforces | Origin |
|---|---|---|
| `SilentCatchAuditTest` | `try?` and empty `catch { }` are banned in `Sources/` outside an idiom/path allowlist | #242 / PR #262 |
| `TrafficBoundaryAuditTest` | 4-rule import-graph and HTTP-egress allowlist (`URLSession` per-file, hostname allowlists, no UI→Backends imports, …) | architecture invariants — see [CONTRIBUTING.md § Architecture invariants](../CONTRIBUTING.md#architecture-invariants) |
| `PackageTraitGateAuditTest` | Gate consumer→library edges in `Package.swift`, not library→library | trait-combo build pain |
| `ProtocolLocationAuditTest` | Cross-family protocols live in `ManifoldInference`, not the umbrella |  |
| `UserDefaultsStandardAuditTest` | Production code must accept an injected `UserDefaults`, not touch `.standard` | #734 / #761 (parallel-test flake) |
| `SessionConstructionAuditTest` | `URLSession(` constructor only inside `URLSessionProvider.swift` |  |
| `DNSRebindingCoverageAuditTest` | Cloud backends must route through `DNSRebindingGuard` |  |
| `AgentsMdAuditTest` | `AGENTS.md` ↔ `CLAUDE.md` stay aligned |  |
| `TestSuiteSilentSkipAuditTest` | XCTSkip without an explicit reason is banned |  |

**Why.** A reviewer's eye is the wrong layer to catch "did this PR add a new `URLSession(...)` outside the allowlist", "did anyone import `ManifoldBackends` from UI again", or "is there a fresh `try?` swallowing errors in production". Each audit codifies a rule that bled into a real bug (or is one Swift compile away from a real bug), then plants a tripwire. The cost is one test file per rule; the payoff is the rule never silently rots back in.

**Run them.** They live in the regular suites and run on every CI build (plain `swift test` — there are no default traits since v0.48):

```bash
swift test --filter ManifoldInferenceTests   # SilentCatchAudit, TrafficBoundaryAudit, …
swift test --filter ManifoldBackendsTests     # SessionConstructionAudit, DNSRebindingCoverageAudit, …
swift test --filter ManifoldCoreTests         # PackageTraitGateAudit, UserDefaultsStandardAudit, …
swift test --filter ManifoldRuntimeTests      # ProtocolLocationAudit
```

Failures print the offending file/line plus the allowlist mechanism. Most audits expose a path-based allowlist file (e.g. `silent_catch_allowlist.txt`) sitting beside the test; some also support "idiom" allowlists for globally-approved patterns.

**Extend — adding a new audit.**

1. Pick the right home target. Audits sit in whichever `Tests/Manifold*Tests/` suite is closest to the surface they police — `Inference` for protocol/error rules, `Backends` for cloud/HTTP rules, `Core` for cross-cutting rules, `Runtime` for layering.
2. Walk `Sources/` (or `Package.swift`, or whatever artifact you're policing) with `FileManager`. Read each `.swift` file as a `String`. Don't `@testable import` — audits look at source as data, not the linked binary.
3. Emit a fingerprint per violation in the form `relative/path.swift:trimmed line` and check against a sibling allowlist file. Use `#`-prefixed comments + blank-line tolerance. Keep the allowlist short — every entry is debt.
4. Document the rule and the approval shape in a file-header doc-comment. Cite the issue or PR that motivated the rule.
5. Add a sabotage entry (see practice 3 below) so the audit can't quietly rot into a no-op.

`SilentCatchAuditTest.swift` is the canonical reference implementation — header doc, idiom rules, path allowlist, stale-allowlist check.

---

## 3. Audit sabotage suite

**What.** [`Tests/ManifoldAuditSabotageSuiteTests/AuditSabotageSuiteTests.swift`](../Tests/ManifoldAuditSabotageSuiteTests/AuditSabotageSuiteTests.swift) (454 LOC). One test per file-walking audit. Each test:

1. Creates a temp directory mimicking the relevant source layout.
2. Writes a file containing a known violation of the rule the audit enforces.
3. Reimplements the audit's check logic inline (SwiftPM forbids `@testable import` of test targets, so logic is inlined minimally).
4. Asserts the violation is detected.

**Why.** Audit tests are line-grep heuristics with allowlists. Over time, an allowlist entry can drift, a regex can be loosened to land an unrelated fix, or the audit can be skipped for trait reasons and quietly turn into a no-op. The sabotage suite is the "who watches the watchers" guard. Without it, an audit could pass for a year while no longer catching what it advertises. Originated in PR #1290 (Phase 5 cloud-helper deletion).

**Run it.**
```bash
SABOTAGE=1 swift test --filter ManifoldAuditSabotageSuiteTests
```
Without `SABOTAGE=1` every test skips immediately — the suite is nightly-only because it does temp-dir setup per test. The scheduled `nightly-slow-tests` workflow runs it with `SABOTAGE=1`, `--min-passed 1`, and a log proof check for `ManifoldAuditSabotageSuiteTests` test-case lines so a skipped sabotage lane cannot look green.

**Extend.** When you add a new audit (practice 2), pair it with a sabotage test:

1. Pick a representative violation of the rule.
2. Create a temp dir, write the violating file at the right relative path.
3. Inline the audit's detection logic (regex, scan, whatever the audit uses).
4. Assert the violation is detected. The test PASSES when the audit would correctly flag the file.
5. Open the suite with `try requireSabotageMode()` so the test no-ops without `SABOTAGE=1`.

Existing tests in the suite serve as templates — `test_sessionConstructionAudit_detectsViolation` is the simplest shape.

---

## 4. Cold-start conformance gates

**What.** Three shell scripts that scaffold a fresh SwiftPM consumer in a `mktemp -d` tmpdir, link ManifoldKit by local `path:`, and exercise the public surface from outside the repo.

| Tier | Script | Surface |
|---|---|---|
| 1 | [`scripts/cold-start-conformance.sh`](../scripts/cold-start-conformance.sh) | Low-level public API: `InferenceBackend`, `InferenceService`, `GenerationStream` consumption. Runs one chat turn through a tiny inline fake backend. |
| 2 | [`scripts/cold-start-tier2-bootstrap.sh`](../scripts/cold-start-tier2-bootstrap.sh) | `ManifoldBootstrap` + `ChatViewModel` orchestration — the high-level path real chat apps use. Drives one user → assistant turn via `vm.inputText` + `await vm.sendMessage()`. |
| 3 | [`scripts/cold-start-tier3-chatview.sh`](../scripts/cold-start-tier3-chatview.sh) | `ManifoldUI` `ChatView` composition with `@State` view models, `.environment(_:)` injection, and the `apiConfiguration: () -> View` view-builder closure. |

**Why.** The in-tree compiler sees internals a fresh consumer cannot. A public API can quietly stop being usable from outside the repo — a forgotten `internal`, a missing `@_exported import`, a `Package.swift` link shape break — and every in-tree test still passes. Cold-start audits in early 2026 found that most of the friction documented by external agents was exactly this shape. Tier 1 originated in PR #1097 to gate the next layer of breakage.

**Run them.**
```bash
scripts/cold-start-conformance.sh        # tier 1
scripts/cold-start-tier2-bootstrap.sh    # tier 2
scripts/cold-start-tier3-chatview.sh     # tier 3
```
Each takes ~30s on a warm cache. They run in CI on every PR; each CI job lists its own script path in the workflow's `paths:` filter so edits to the gate re-trigger the gate.

**Extend.** Adding a tier or widening an existing one:

1. Copy the closest existing script.
2. Build a minimal consumer `Package.swift` in `$WORK`. Pin the local package with explicit `name: "ManifoldKit"` — `.package(path:)` derives identity from the last path component, which breaks under worktree checkouts.
3. Scaffold consumer source that uses *only* products a real downstream consumer can reach. Roll inline fakes for anything that lives in `ManifoldTestSupport` — that target is deliberately not a public product.
4. `swift build` + `swift run` against the consumer. The script should exit non-zero on any compile or runtime failure.
5. Add a CI job in `.github/workflows/ci.yml` and include the script path in `paths:` so the gate self-validates.

The tier-2 script's long header doc-comment is the canonical "why and how" reference for the gate scaffold pattern, including the `ManifoldBootstrap` SwiftData-container collision footgun that motivated explicit `makeModelContainer:` overrides.

---

## 5. Local real-model integration + perf sweep

**What.** One script — [`scripts/local-integration-sweep.sh`](../scripts/local-integration-sweep.sh) — that runs the real-model integration and benchmark suites across the whole family on local Apple Silicon, and writes a single timestamped report:

| Lane | Suite | Real backend |
|---|---|---|
| `core` | `ManifoldE2ETests` (incl. `DemoScenarioOllamaE2ETests`, `BackendBenchmarkE2ETests`) | Ollama @ `localhost:11434` — core's only in-package real-model path post-companion-split |
| `llama` | manifold-llama integration + 5-family GBNF grammar/tool conformance + regression fixtures | in-process llama.cpp against GGUF on disk |
| `mlx` | manifold-mlx text E2E + vision-input + TTFT/TPS benchmark | in-process MLX/Metal against safetensors on disk |

**Why.** CI is macOS-only and mocks every backend; the heavy local families live in companion repos whose integration tiers are `workflow_dispatch`-gated and therefore effectively never run. So real-model behaviour — GBNF conformance across model families, KV-cache reuse correctness, real vision input, decode throughput — is only ever exercised on a developer machine, by hand, if at all. This script makes that a one-command, repeatable sweep instead of ad-hoc `swift test` invocations with easy-to-forget env vars. It is **deliberately not scheduled**: run it the nights you want a sweep (e.g. after adding a model family or a sampler).

**Run it.**
```bash
scripts/local-integration-sweep.sh                  # all lanes, auto-discover models
scripts/local-integration-sweep.sh --lanes llama    # one lane
COMPANIONS_DIR=~/src scripts/local-integration-sweep.sh   # companion repos elsewhere
```
Hours, not seconds — it cold-builds three packages then runs real inference. Lanes run **sequentially** (MLX and llama.cpp contend for GPU/unified memory), each with a unique `TMPDIR` and **no `--parallel`** (matches both repos' process-global-state constraints). The report (`./.local-integration-runs/<stamp>/REPORT.md`, gitignored) leads with a model inventory so a lane that silently `XCTSkip`s for a missing model is visible, not mistaken for a pass.

**Extend.** Add a lane by following the `run_lane` pattern; add a model family by dropping a GGUF whose filename contains the family fragment (`qwen`, `mistral`, `phi`, …) into `~/Documents/Models`, or an MLX snapshot dir for the MLX lane. The inventory block reports what will and won't light up.

---

## When to use which

- Public API or first-time-user friction → DX walkthrough (slow, high-signal) + cold-start gate (fast, narrow).
- "This kind of bug keeps coming back" → audit test + sabotage entry.
- Architecture invariant (module layering, HTTP egress, persistence boundaries) → audit test, cited in [CONTRIBUTING.md § Architecture invariants](../CONTRIBUTING.md#architecture-invariants).
- Real-model behaviour CI can't see (GBNF conformance per family, KV-cache reuse, vision input, decode throughput) → local integration + perf sweep (slow, hardware + models required, run by hand).
