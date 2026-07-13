# ManifoldKit QA practices

Four cross-cutting QA practices guard ManifoldKit beyond its unit / integration / E2E test pyramid. Each one catches a class of regression that ordinary tests miss. This page is the discovery doc — what each practice is, why it exists, how to run it, and how to extend it.

For day-to-day test conventions (suites, traits, layering), see [`Tests/README.md`](../Tests/README.md). For module/architecture rules and pre-push gates, see [`CLAUDE.md`](../CLAUDE.md).

| Practice | Scope | Lives at | Doc |
|---|---|---|---|
| DX walkthroughs | Forced-blindness fresh-developer DX regression | [`scripts/dx-walkthrough/`](../scripts/dx-walkthrough/) | [README](../scripts/dx-walkthrough/README.md) |
| Audit tests | File-walking discipline rules (19 files) | `Tests/*/Manifold*AuditTest*.swift` | this doc |
| In-file sabotage tests | Verify the audit tests still catch what they claim | `test_sabotage_*` methods in each `Tests/**/*Audit*.swift` file | this doc |
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

## 3. In-file audit sabotage tests

**What.** Every audit test carries a `test_sabotage_*` method **in the same
file**, calling the **same static detection function** the audit itself runs.
Each sabotage test:

1. Creates a temp directory (or in-memory input) containing a known violation
   of the rule the audit enforces.
2. Calls the audit's real detection function against it — the exact function
   the main test runs against `Sources/` (or `Package.swift`, or the fixture
   tree).
3. Asserts the violation is detected — and, where an allowlist or idiom rule
   exists, that an exempted equivalent is *not* flagged.

`AuditSabotageCoverageAuditTest` (in `ManifoldCoreTests`) enforces the pairing:
any `Tests/**/*Audit*.swift` file without a `func test_sabotage...` method
fails per-PR CI.

**Why.** Audit tests are line-grep heuristics with allowlists. Over time, an
allowlist entry can drift, a regex can be loosened to land an unrelated fix,
or the audit can quietly turn into a no-op. The sabotage tests are the "who
watches the watchers" guard. They originally lived in a separate nightly
`ManifoldAuditSabotageSuiteTests` target that *reimplemented* each audit's
logic inline — which meant a green sabotage run proved a hand-copied replica
still fired, not the shipped audit, and several replicas had measurably
drifted from their audits by mid-2026. The in-file pattern (established by
`TrafficBoundaryAuditTest`'s `test_sabotage_rule1..7`) makes replica drift
structurally impossible — one file, one detection function, two callers — and
runs per-PR instead of nightly, so a broken audit is caught before merge
rather than up to 24 h after. Originated in PR #1290; converted to in-file in
the 2026-07 audit-hardening pass.

**Run them.** Nothing special — they are ordinary tests in the audit's home
target, so `scripts/test.sh --profile local` and per-PR CI run them
automatically.

**Extend.** When you add a new audit (practice 2), pair it in the same file:

1. Put the detection logic in a `static func` parameterized by the scanned
   root/input (and the allowlist, if the sabotage should prove exemption).
2. The main test calls it with the real root; the `test_sabotage_*` test
   calls it with a temp tree containing a representative violation.
3. Assert the violation is flagged and an allowlisted equivalent is not.

`SessionConstructionAuditTest` is the simplest converted shape;
`SilentCatchAuditTest` shows the allowlist + stale-check split.

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

## 6. Known coverage gaps

### ManifoldFoundation CI coverage gap (#2096, accepted, deferred)

**What's uncovered.** `ManifoldFoundation`'s entire test surface — `FoundationBackendUnitTests`, `FoundationBackendToolCallingTests`, `FoundationLocalBackendContractTests`, `FoundationBackendMetricEmissionTests`, `Conformance/FoundationBackendContractTests`, `FoundationModelE2ETests`, plus the Foundation-gated slices of `BackendBenchmarkE2ETests` and `ManifoldFuzzTests/FoundationFuzzFactoryTests` — compiles in CI but has never asserted a real pass/fail. Every test method's `setUp()` throws `XCTSkip("FoundationModels requires iOS 26 / macOS 26")` before touching `FoundationBackend`.

**Why.** `FoundationBackend` is `@available(iOS 26, macOS 26, *)` per CLAUDE.md's platform policy (current-OS floor `n`). Every `runs-on:` across all CI workflows is `macos-15` (or `ubuntu-latest`, or the `fuzz-weekly.yml` self-hosted `macos, arm64` box) — there is no GitHub-hosted macOS 26 runner, and the self-hosted box is not provisioned for one either. The tests key off the *running* OS version (`ProcessInfo.isOperatingSystemAtLeast`), not just SDK availability, so an Xcode 26 SDK on a macOS 15 host still skips at runtime. This is a compile-time-covered, runtime-never-executed gap, not a missing-target gap — `ManifoldFoundation` links into the default `ManifoldKit` umbrella build, so the code itself is exercised by every other suite; only its own assertions never run.

**Decision.** Accepted as a permanent local-only gap (issue #2096, option (c) — document, do not stand up a runner). `ManifoldFoundation`'s suite is verified by hand on Apple Silicon running macOS 26, the same way `ManifoldFuzz`'s campaigns and the local-integration-sweep lanes above are: a developer-run check, not a CI gate. This mirrors the MLX/llama.cpp treatment (§5) in spirit, but is intentionally **not** folded into `scripts/local-integration-sweep.sh` — that script's premise is real-model integration/perf on hardware CI can't reach; this gap is an OS-floor problem, not a hardware or model-weights problem, so bolting it onto the sweep script would conflate two different reasons for "doesn't run in CI."

**Revisit trigger.** Re-open this decision (not just the doc) when either becomes true:
- GitHub ships a `macos-26` (or later) hosted runner image, making a real macOS-26 CI lane cheap instead of requiring new self-hosted infrastructure.
- Apple ships the next major OS and CLAUDE.md's platform-policy floor bumps to macOS 26 / iOS 26 as the *minimum* (`n-1`) — at that point every `runs-on: macos-15` job either upgrades or the whole fleet is already macOS 26+, and the skip guard becomes dead code to remove rather than a gap to route around.

Until then, `docs/QA-PRACTICES.md` (this section) and a comment on the `ManifoldBackendsTests` step in `.github/workflows/ci.yml` are the discoverability anchors — the runtime `XCTSkip` alone reads as an oversight, not a decision, which is what #2096 exists to fix.

---

## When to use which

- Public API or first-time-user friction → DX walkthrough (slow, high-signal) + cold-start gate (fast, narrow).
- "This kind of bug keeps coming back" → audit test + sabotage entry.
- Architecture invariant (module layering, HTTP egress, persistence boundaries) → audit test, cited in [CONTRIBUTING.md § Architecture invariants](../CONTRIBUTING.md#architecture-invariants).
- Real-model behaviour CI can't see (GBNF conformance per family, KV-cache reuse, vision input, decode throughput) → local integration + perf sweep (slow, hardware + models required, run by hand).
- "Why does this suite always skip in CI, is that a bug?" → check § 6 Known coverage gaps before filing an issue; it may already be an accepted, documented gap (e.g. ManifoldFoundation / #2096).
