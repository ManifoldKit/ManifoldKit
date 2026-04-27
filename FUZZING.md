# Fuzzing Guide

BaseChatFuzz is a long-running, randomised exercise harness for the inference stack. It drives real backends with semi-random prompts, sampler settings, and stop conditions, and runs detectors over the output stream looking for whole classes of bugs that unit tests don't think to ask about — visible reasoning leaks, runaway loops, template-token escapes, KV cache collisions, and so on. It is **not** a regression-test replacement: detector hits are leads to investigate, and severity stays at `flaky` until the calibration corpus clears both accuracy gates (FP < 2 %, TP ≥ 80 %).

On its first real-model smoke run against `qwen3.5:4b` via Ollama, the harness landed three findings in three iterations — every one a 41–99-second compute that produced an empty assistant message. Root cause was filed as [#487](https://github.com/roryford/BaseChatKit/issues/487): `OllamaBackend.extractToken` only reads `message.content` and silently drops the separate `thinking` field that reasoning models emit. That is the kind of bug this harness exists to find — a real production-path drop that no unit test was asking about, surfaced in minutes against an off-the-shelf model.

---

## Table of Contents

- [Quickstart](#quickstart)
- [Backends](#backends)
- [Rotation](#rotation)
- [Anatomy of a Finding](#anatomy-of-a-finding)
- [Day-One Detectors](#day-one-detectors)
- [Reproducing a Finding](#reproducing-a-finding)
- [Adding a New Detector](#adding-a-new-detector)
- [Real-Bug Rediscovery Recipes](#real-bug-rediscovery-recipes)
- [Calibration Corpus](#calibration-corpus)
- [Known Gaps](#known-gaps)
- [CI tiers](#ci-tiers)

---

## Quickstart

Five-minute Ollama run, default detector set, defaults on everything else:

```bash
scripts/fuzz.sh --minutes 5
```

The wrapper prints a preflight line showing which backends it found (Llama via `~/Documents/Models/`, MLX via `~/Documents/Models/`, Ollama via `localhost:11434`, Foundation via `sw_vers`). If nothing is usable it exits with install hints. The recommended first model is `qwen3.5:4b` — it is a reasoning model and is the most likely to surface fuzzer-relevant behavior on a fresh machine (`ollama pull qwen3.5:4b`).

Direct invocation works too — the wrapper just adds the preflight and the MLX xcodebuild bridge:

```bash
swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat --minutes 5
swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat --iterations 200 --backend ollama --quiet
swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat --single --seed 42 --model qwen3.5
```

Common flags:

| Flag | Purpose |
|------|---------|
| `--backend <name>` | `ollama` (default), `llama`, `foundation`, `mlx`, `mock`, `chaos`, `all`. `mlx` runs via the xcodebuild path (see below); `all` is not yet implemented. |
| `--minutes N` | Wall-clock budget. Default 5. |
| `--iterations N` | Iteration cap; runs until either budget is hit. |
| `--single` | One iteration then exit — useful with `--seed`. |
| `--seed N` | Deterministic prompt/sampler selection for repro. |
| `--model <substr>` | Ollama: pin to the first installed model containing `<substr>`; pass `all` (or omit) to rotate through every installed Ollama model. Llama: pin to the first GGUF whose filename contains `<substr>`. `scripts/fuzz.sh --with-mlx` maps the same flag to `MLX_TEST_MODEL` for the xcodebuild-hosted MLX path. |
| `--detector <ids>` | Comma-separated detector IDs to enable. |
| `--quiet` | Suppress the per-iteration log line. |
| `--tools` | Inject `SyntheticToolset` so tool-aware backends have something to call. Pairs with `tool-call-validity` ([#627](https://github.com/roryford/BaseChatKit/issues/627)). |

---

## Backends

| Backend | Status | Discovery | Notes |
|---------|--------|-----------|-------|
| Ollama | Wired | `curl http://localhost:11434/api/tags` | Default backend in v1. |
| Llama  | Wired | `~/Documents/Models/**/*.gguf` via `HardwareRequirements` | Single-model only: `llama_backend_init` is a process-global one-shot, so `--model all` is a no-op for this backend. `LLAMA_TEST_MODEL=<substr>` pins a specific file. |
| MLX    | Wired (xcodebuild path) | `~/Documents/Models/<dir>/{config.json,*.safetensors,tokenizer.*}` | Requires the xcodebuild path because MLX Metal shaders only compile under Xcode — see `--with-mlx` below. `MLX_TEST_MODEL=<substr>` pins a specific snapshot. |
| Foundation Models | Wired | `sw_vers -productVersion >= 26` | macOS 26+ only. Requires Apple Intelligence to be enabled; otherwise backend creation fails and the run exits early with an error. |

Backend wiring lives behind the `FuzzBackendFactory` protocol. A factory exposes `makeHandle() async throws -> FuzzRunner.BackendHandle`, where `BackendHandle` carries `(backend: any InferenceBackend, modelId: String, modelURL: URL, backendName: String, templateMarkers: RunRecord.MarkerSnapshot)`. The importable real-backend factories live in `Sources/BaseChatFuzzBackends/`, so both `fuzz-chat` and the MLX XCTest host reuse the same bring-up code. Detectors operate on the resulting `RunRecord` and don't care which backend produced it.

### MLX via xcodebuild

`swift run fuzz-chat --backend mlx` cannot work directly because MLX's Metal shaders are not compiled by SwiftPM. The wrapper's `--with-mlx` flag (or `--backend mlx`) runs the MLX XCTest fuzz suite separately while forwarding the shared campaign knobs into the test host via environment variables:

```bash
scripts/fuzz.sh --with-mlx --minutes 5 --seed 42 --corpus-subset smoke
scripts/fuzz.sh --backend mlx --iterations 10 --model gemma
```

The xcodebuild host reads `BASECHAT_FUZZ_MINUTES`, `BASECHAT_FUZZ_ITERATIONS`, `BASECHAT_FUZZ_SEED`, `BASECHAT_FUZZ_DETECTOR`, `BASECHAT_FUZZ_CORPUS_SUBSET`, `BASECHAT_FUZZ_SESSION_SCRIPTS`, `BASECHAT_FUZZ_TOOLS`, and `MLX_TEST_MODEL`, then feeds the resulting `FuzzConfig` into `FuzzRunner` / `SessionFuzzRunner` with the shared `MLXFuzzFactory`.

---

## Rotation

Bug shapes diverge per model. The #487 `thinking`-drop only showed up on reasoning models; repetition and looping skew toward small-quant instruct models. A campaign that touches a single model misses everything that lives on its siblings, which is why rotation is the default.

**Default behaviour.** With no `--model` flag (or `--model all`), `fuzz-chat` enumerates every installed Ollama model at startup and round-robins through them — one model per iteration. With six iterations across two installed models, each model gets three iterations. Deduplication is unaffected: `Finding.hash` already mixes `modelId` into the key, so the same bug shape on two different models produces two distinct findings.

**Pinning to one model.** `--model <substr>` preserves the pre-#501 behaviour: pick the first installed model whose name contains the substring, and use only that model for the whole campaign.

**Determinism.** The discovered model list is sorted by UTF-8 byte order before rotation, so two invocations on the same machine — regardless of the order Ollama reports its models — produce the same iteration-to-model mapping. This is the contract that keeps `--seed N --replay` (#490) meaningful: given a fixed seed and a fixed installed-model list, the rotation sequence is reproducible.

**Llama opt-out.** `LlamaBackend` calls `llama_backend_init` as a process-global one-shot — only one instance per process is supported. Rotation never applies to Llama. The CLI's Llama path is wired (`--backend llama` discovers the first GGUF in `~/Documents/Models/` via `HardwareRequirements.findGGUFModel`) and stays single-model even under `--model all`; use `--model <substr>` or `LLAMA_TEST_MODEL=<substr>` to pin a specific file.

**Mechanism.** The rotating factory is a `FuzzBackendFactory` conformance that wraps an ordered array of child factories and advances an internal index per `makeHandle()` call. The runner's `init(config:factory:)` contract (#537) is unchanged — rotation is hidden behind the factory boundary. See `RotatingFuzzFactory` in `Sources/BaseChatFuzz/`.

```bash
# Rotate through every installed Ollama model (default)
swift run fuzz-chat --iterations 6

# Same, explicit
swift run fuzz-chat --model all --iterations 6

# Pin to one model
swift run fuzz-chat --model qwen3.5 --iterations 6

# Verify rotation hit every model evenly
cat tmp/fuzz/index.json | jq '.[].model_id' | sort | uniq -c
```

---

## Anatomy of a Finding

All output lands under `tmp/fuzz/` (gitignored). Each run appends to the index without clearing prior findings.

```
tmp/fuzz/
├── INDEX.md                       # Human-readable table: detector, hash, model, severity
├── index.json                     # Machine-readable equivalent for tooling
└── findings/
    └── <detector-id>/
        └── <hash>/
            ├── record.json        # Full event stream + sampler config + seed
            ├── summary.txt        # Human-readable triage summary
            └── repro.sh           # Single-command repro
```

Findings are deduplicated by `<hash>` — the same bug surfaced twice in one run shows up once. Open `tmp/fuzz/INDEX.md` after a run to triage.

---

## Day-One Detectors

Four detectors ship with the v1 harness. Most sub-checks are classified `flaky` until the calibration corpus clears both accuracy gates on known-good outputs — see [Calibration Corpus](#calibration-corpus); two zero-FP-by-construction transcript invariants under `tool-call-validity` (`id-reuse` and `orphan-result`) ship `confirmed`.

| ID | Sub-checks | Inspiration |
|----|-----------|-------------|
| `thinking-classification` | 4 | df94418 — `<think>...</think>` reasoning blocks were leaking into visible MLX/Llama output. |
| `looping` | 2 | qwen3.5:4b on Ollama — model gets stuck repeating phrases inside `<think>` blocks until max-tokens. |
| `empty-output-after-work` | `silent-empty` | [#487](https://github.com/roryford/BaseChatKit/issues/487) — `OllamaBackend.extractToken` drops the `thinking` field for reasoning models, leaving the user with a long compute and an empty assistant bubble. The headline first-day discovery. |
| `tool-call-validity` | 5 (`malformed-json-args`, `schema-violation`, `id-reuse`, `orphan-result`, `toolchoice-violation`) | [#627](https://github.com/roryford/BaseChatKit/issues/627) — tool-call correctness is the most fragile piece of any real integration. Activates when `--tools` is set or `RunRecord.toolCalls` is non-empty; reuses `JSONSchemaValidator`. `id-reuse` and `orphan-result` ship `confirmed` (zero-FP-by-construction transcript invariants); `malformed-json-args`, `schema-violation`, `toolchoice-violation` ship `flaky` pending corpus calibration under [#488](https://github.com/roryford/BaseChatKit/issues/488). |

The remaining seven detectors are documented below. All ten single-turn detectors are now covered by the calibration corpus — see [Calibration Corpus](#calibration-corpus).

---

## Reproducing a Finding

Every finding directory ships an auto-generated `repro.sh` pointing at the preferred replay path:

```bash
bash tmp/fuzz/findings/<detector-id>/<hash>/repro.sh
# expands to:
swift run fuzz-chat --replay <hash>
```

`--replay` resolves the hash to `tmp/fuzz/findings/*/<hash>/record.json`, refuses if the package git rev or the model's SHA-256 have drifted (override with `--force`), and re-runs the exact recorded prompt + sampler config three times. Output summarises pass/fail:

```
Replay 7f2a8c91b0de: reproduced 2/3 — promoted to confirmed
Replay 7f2a8c91b0de: reproduced 0/3 — remains flaky
Replay 7f2a8c91b0de: drift refused (git 7076c6f → fa9e236); pass --force to override
Replay 7f2a8c91b0de: record not found
Replay 7f2a8c91b0de: schema version 99 is newer than harness (supported: 1)
```

Exit codes: `0` for reproduced / not-reproduced (both are valid data), `2` for drift refused, record not found, schema unsupported, or non-deterministic backend.

### Replay determinism per backend

`--replay` is only useful when the backend will bit-reproduce given the same prompt + sampler config. `FuzzBackendFactory` exposes `supportsDeterministicReplay` (default `true`); cloud factories override to `false` and `--replay` short-circuits with a clear message rather than deliver misleading data.

| Backend | Deterministic? | Notes |
|---------|----------------|-------|
| MLX, Llama | yes (seed + temperature=0) | bit-identical; the default 2/3 promotion threshold is safe. |
| Foundation Models | yes | on-device; deterministic given identical prompt + config. |
| Ollama | backend-dependent | seed plumbing varies by model/version. Verify by running the same prompt twice at `--seed N` before trusting a promotion. If outputs aren't bit-identical, raise the threshold (e.g. 3/5) before promoting. |
| Claude, OpenAI, cloud | no | `--replay` refuses with `non-deterministic backend`. Structural-equivalence replay is a follow-up. |

The promotion gate is `ceil(2/3 * attempts)` successes: 2/3 at the default `attempts: 3`. Fallback to the old direct-seed recipe is preserved as a commented line at the bottom of every `repro.sh` for cases where a rev bump has invalidated the record and you want to re-fuzz without replay.

### Drift detection

`record.harness.packageGitRev` is compared against the current `git rev-parse --short HEAD` on every replay. `record.model.fileSHA256` is compared against the current on-disk model hash when both sides are non-nil. Any mismatch returns `.driftRefused(DriftReport)` and exits non-zero — the developer sees exactly what changed rather than debugging a phantom "it worked yesterday" non-repro. `--force` threads through, logs a warning, and annotates the Result with the drift for later inspection.

---

## Adding a New Detector

Detectors live in `Sources/BaseChatFuzz/Detectors/`. Each conforms to the `Detector` protocol — one ID, a human-readable name, an inspiration string, and an `inspect(_ record: RunRecord) -> [Finding]` function. Register the new type in `DetectorRegistry.all`. See `EmptyOutputAfterWorkDetector.swift` for a worked example.

```swift
import Foundation

public struct MyDetector: Detector {
    public let id = "my-detector"
    public let humanName = "Short human-readable description"
    public let inspiredBy = "Issue #NNN or commit hash that motivated this check"

    public init() {}

    public func inspect(_ record: RunRecord) -> [Finding] {
        // Walk record.events / record.rendered / record.thinkingRaw / record.timing.
        // Return a Finding for each suspicious pattern; return [] when nothing fires.
        return []
    }
}
```

Then in `DetectorRegistry.swift`:

```swift
public static let all: [any Detector] = [
    ThinkingClassificationDetector(),
    LoopingDetector(),
    EmptyOutputAfterWorkDetector(),
    MyDetector(),   // ← add here
]
```

Run with `--detector my-detector` to test in isolation. A detector that fires on every iteration is almost certainly mis-tuned — verify against the calibration corpus before relying on it.

---

## Real-Bug Rediscovery Recipes

These verify the harness can rediscover known-fixed bugs. Use them as a sanity check after detector changes.

### Visible-text leak (thinking-classification)

```bash
git revert df94418
swift build
scripts/fuzz.sh --minutes 5 --detector thinking-classification
git revert HEAD   # restore the fix
```

The reverted state ships raw `<think>...</think>` content in the visible message stream. The `thinking-classification` detector should fire within the first few iterations against any reasoning-capable model.

### Looping inside think blocks (looping)

```bash
scripts/fuzz.sh --minutes 5 --model qwen3.5:4b --detector looping
```

`qwen3.5:4b` on Ollama is the canonical reproducer — it gets stuck repeating phrases inside `<think>` and exhausts max-tokens. The `looping` detector should hit consistently against this model with default sampler.

### Silent-empty Ollama output (empty-output-after-work)

```bash
scripts/fuzz.sh --minutes 5 --model qwen3.5:4b --detector empty-output-after-work
```

Until [#487](https://github.com/roryford/BaseChatKit/issues/487) is fixed, this fires reliably against any reasoning model on Ollama: the backend swallows the `thinking` stream, generation completes cleanly with no error, and the user sees a long compute followed by an empty bubble.

---

## Calibration Corpus

`Sources/BaseChatTestSupport/FuzzCalibrationCorpus/` holds a labeled fixture corpus that gates the `flaky` → `confirmed` severity promotion for each single-turn detector.

| File | Size | Purpose |
|------|------|---------|
| `good.json` | ~210 records | Known-good `RunRecord` captures — no detector should fire |
| `bad.json`  | ~55 records  | Known-bad captures labeled `{detectorId, note, record}` |

### Accuracy gates

`CalibrationTests` in `Tests/BaseChatFuzzTests/` asserts:

| Gate | Threshold |
|------|-----------|
| False-positive rate (FP) | **< 2 %** per detector on the good corpus |
| True-positive rate  (TP) | **≥ 80 %** per detector on its labeled bad records |

Run the gate locally:

```bash
swift test --filter BaseChatFuzzTests.CalibrationTests --disable-default-traits
```

All ten single-turn detectors pass both gates as of [#488](https://github.com/roryford/BaseChatKit/issues/488). `tool-call-validity` (which landed in [#813](https://github.com/roryford/BaseChatKit/pull/813) after the corpus was authored) ships two `.confirmed` zero-FP-by-construction sub-checks (`id-reuse`, `orphan-result`) and three `.flaky` sub-checks pending follow-up corpus work — it is intentionally exempt from the coverage check via `CalibrationTests.coverageExempt`. Session detectors (`turn-boundary-kv-state`, `cancellation-race`, `session-context-leak`) consume `[SessionCapture]` objects and are not covered by this corpus — they require a separate session-level fixture set.

### Adding records

1. Append entries to `good.json` (plain `RunRecord`) or `bad.json` (`{detectorId, note, record}`). Good records use `g-<group>-NNN` (group letter from the corpus-group table). Bad records use a short detector slug + bug-class group, e.g. `b-tc-vl-001` for `thinking-classification` visible-leak — follow the existing pattern in `bad.json` for the relevant detector to keep IDs consistent.
2. Re-run `CalibrationTests` — mislabeled records are caught immediately.
3. A new detector added to `DetectorRegistry.all` will fail `test_badCorpusCoverage_allDetectorsCovered` until at least one bad record is added for it.

See `Sources/BaseChatTestSupport/FuzzCalibrationCorpus/README.md` for the full schema reference and corpus-group descriptions.

---

## Known Gaps

Items below are tracked as follow-up issues — some are detectors that ship without corpus coverage, others are infrastructure not yet built.

### Session detectors without corpus coverage

All ten single-turn detectors are implemented and covered by the calibration corpus. The following session-level detectors ship and run, but consume `[SessionCapture]` rather than `RunRecord`, so they are not gated by the single-turn corpus and need a separate session-level fixture set:

| ID | Looks for |
|----|-----------|
| `turn-boundary-kv-state` | KV-cache residue bleeding across turn boundaries in multi-turn sessions. |
| `cancellation-race` | Output emitted after a cancellation request is acknowledged. |
| `session-context-leak` | Context from one session appearing in a different session's output. |

### Infrastructure

- **`--shrink`** — minimise a failing prompt to the smallest input that still fires the detector.
- **Multi-turn** — opt-in via `--session-scripts`. The harness drives bundled `SessionScript` JSONs through `InferenceService.enqueue`, exercising the queue, cancellation, and latest-wins load paths that single-turn fuzzing can't reach. Three multi-turn detectors ship alongside: `turn-boundary-kv-state`, `cancellation-race`, and `session-context-leak`. Single-turn remains the default ([#492](https://github.com/roryford/BaseChatKit/issues/492)).
- **Slash command** — `/fuzz` shortcut to run `scripts/fuzz.sh` from inside Claude Code.
- **Multi-backend factory fleet** — `FuzzRunner` now accepts a `FuzzBackendFactory` protocol (landed via [#496](https://github.com/roryford/BaseChatKit/issues/496)). Ship `LlamaFuzzFactory`, `FoundationFuzzFactory`, and `MLXFuzzFactory` to feed `--backend all` ([#501](https://github.com/roryford/BaseChatKit/issues/501)).

---

## Tool-Calling Harness (bck-tools)

`bck-tools` validates end-to-end tool-calling correctness independently of the generation fuzzer.
It uses `OllamaBackend` only and does **not** require `--traits Fuzz` (OllamaBackend is always compiled).

```bash
# Requires Ollama running at localhost:11434
swift run bck-tools
```

Unlike `fuzz-chat`, `bck-tools` runs a deterministic scripted scenario rather than a stochastic fuzzer.
Use it for regression testing after changes to tool-calling logic in `BaseChatTools`.

---

## CI tiers

The fuzzer runs on three tiers so each PR pays a small, bounded cost and larger
investments are scheduled rather than blocking merges.

### PR tier — `.github/workflows/fuzz-pr.yml`

- **When:** every PR that touches `Sources/**`, `Tests/**`, `Package.swift`, the allowlist, or the PR-tier workflow itself.
- **Runner:** `macos-15` (GitHub-hosted — no self-hosted dependency).
- **Budget:** 200 iterations at `--seed 1` on the smoke corpus subset, using the `MockInferenceBackend`-backed factory. Typical wall clock: ~60 seconds once the SPM cache is warm.
- **Backend:** `--backend mock` (zero hardware). `--backend chaos` is also available via the CLI for local experiments with injected failure modes.
- **Gate:** `scripts/fuzz-ci-gate.sh tmp/fuzz/index.json` compares every finding hash to `.github/fuzz-allowlist.json`. Any finding not on the allowlist, or any allowlist entry whose `expires` date has passed, fails the job.
- **Goal:** zero flake tolerance. Because the seed and corpus are pinned, a PR that introduces a new finding hash is either a real regression or a new test of nerve for the harness.

**Adding a finding to the allowlist.** Open `.github/fuzz-allowlist.json` and add an object to the `allowlist` array:

```json
{
  "allowlist": [
    {
      "hash": "abc123def456",
      "reason": "Known MockInferenceBackend edge case; tracked in #NNN",
      "expires": "2026-05-19"
    }
  ]
}
```

The `expires` field is strict — past that date the PR job fails even if the hash still matches, which forces periodic triage. Keep the window short (≤ 30 days) and link a tracking issue in `reason`.

### Nightly tier — `.github/workflows/fuzz-nightly.yml`

- **When:** every day at 05:00 UTC, plus `workflow_dispatch`.
- **Runner:** `[self-hosted, macos, arm64]` — see [self-hosted runner requirements](#self-hosted-runner-requirements).
- **Budget:** 10 wall-clock minutes.
- **Backend:** real Ollama `qwen3.5:4b`. The seed is derived from `github.run_number` so each nightly run samples a different slice of the mutator space.
- **Gate:** the job fails if `tmp/fuzz/index.json` contains any `confirmed`-severity finding. `flaky`-severity findings are uploaded as artefacts and do not fail the build (they are leads, not regressions).
- **Artefacts:** the full `tmp/fuzz/` tree uploads to `fuzz-nightly-findings-<run-id>` every run.

### Weekly tier — `.github/workflows/fuzz-weekly.yml`

- **When:** every Sunday at 07:00 UTC, plus `workflow_dispatch`.
- **Runner:** `[self-hosted, macos, arm64]`.
- **Budget:** 30 wall-clock minutes.
- **Backend:** `--backend ollama --model all` — rotates through every installed Ollama model per iteration. This is the explicit sibling-coverage sweep; bugs that only fire on a non-default model surface here.
- **Gate:** none. The job is report-only: the `INDEX.md` is echoed to the job log and the full findings tree is uploaded to `fuzz-weekly-findings-<run-id>`.

### Self-hosted runner requirements

Nightly and weekly tiers assume a macOS self-hosted runner labelled `self-hosted`, `macos`, and `arm64`. Provisioning checklist:

1. Apple Silicon host (nightly fuzzes Metal-accelerated Ollama inference — x86 emulation will be too slow to hit the 10-minute budget).
2. Xcode 26.3 and a matching Swift toolchain (same pins as `.github/workflows/ci.yml`).
3. Ollama installed and reachable on `localhost:11434`. Pull at least `qwen3.5:4b` before the first nightly run (`ollama pull qwen3.5:4b`).
4. Any additional models the weekly sweep should include — they'll be picked up automatically by `--model all`.

Until a runner is provisioned, the nightly and weekly workflows will queue indefinitely on scheduled trigger. That is intentional — the PR tier does not depend on them, so the absence of a self-hosted runner does not block merges.

---

## Backend fixture coverage — audit 2026-04-19

Rationale: [#487](https://github.com/roryford/BaseChatKit/issues/487) — OllamaBackend silently dropped `message.thinking` because `OllamaBackendTests` had zero fixtures with that field. This matrix audits which protocol fields every backend has a fixture for and which it does not, so each `no` cell becomes a tracked follow-up rather than a latent "surfaced-by-the-fuzzer" bug. Source: [#503](https://github.com/roryford/BaseChatKit/issues/503).

**Legend.** `yes` — a fixture in `Tests/BaseChatBackendsTests/` asserts the field's behaviour. `no` — no fixture anywhere in the test tree exercises the field. `partial` — a fixture touches the field but does not cover the variants called out in the gap issue. Cells marked `n/a` apply when the field is structurally impossible on that backend (e.g. GGUF chat templates on Claude).

### Ollama

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| Ollama | `/api/chat` NDJSON happy path | yes | `OllamaBackendTests.swift:101` (`streaming_yieldsTokens`) | — |
| Ollama | `message.content` extraction | yes | `OllamaBackendTests.swift:328` (`extractToken_parsesContent`) | — |
| Ollama | `message.thinking` field | no | — | [#487](https://github.com/roryford/BaseChatKit/issues/487) |
| Ollama | `done_reason` variants (`stop`/`length`/`load`/`unload`) | no | — | [#507](https://github.com/roryford/BaseChatKit/issues/507) |
| Ollama | `eval_count` / `eval_duration` usage stats | no | — | [#508](https://github.com/roryford/BaseChatKit/issues/508) |
| Ollama | NDJSON mid-line byte split | no | — | [#509](https://github.com/roryford/BaseChatKit/issues/509) |
| Ollama | `/api/generate` legacy endpoint shape | no | — | [#510](https://github.com/roryford/BaseChatKit/issues/510) |
| Ollama | SSE stream limits (size / event rate) | no | — | [#511](https://github.com/roryford/BaseChatKit/issues/511) |
| Ollama | `Retry-After` header non-numeric variants | partial[^1] | `OllamaBackendTests.swift:230` (`rateLimitError_429`) | [#512](https://github.com/roryford/BaseChatKit/issues/512) |
| Ollama | 404 / 500 / 429 error paths | yes | `OllamaBackendTests.swift:189` / `:210` / `:230` | — |
| Ollama | system prompt in request body | yes | `OllamaBackendTests.swift:125` (`streaming_withSystemPrompt_includesInMessages`) | — |
| Ollama | conversation history serialisation | yes | `OllamaBackendTests.swift:286` (`conversationHistory_usedInMessages`) | — |
| Ollama | malformed NDJSON line handling | yes | `OllamaBackendTests.swift:168` (`streaming_malformedLine_skipped`) | — |

[^1]: Only `Retry-After: "0"` is fixtured; RFC 7231 HTTP-date form and non-trivial integer seconds are not.

### MLX

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| MLX | qwen3 thinking markers | yes | `MLXBackendThinkingTests.swift:59` (`test_thinkingTokensEmittedSeparatelyFromVisibleTokens`) | — |
| MLX | deepseek-r1 thinking markers | partial[^2] | `MLXBackendThinkingTests.swift:59` | — |
| MLX | custom / gpt-oss / gemma4 markers | no | — | [#513](https://github.com/roryford/BaseChatKit/issues/513) |
| MLX | `maxThinkingTokens` cap | no | — | [#514](https://github.com/roryford/BaseChatKit/issues/514) |
| MLX | `maxOutputTokens` with thinking active | yes | `MLXBackendThinkingTests.swift:123` (`test_outputTokenCount_doesNotIncludeThinkingTokens`) | — |
| MLX | no thinking events when markers nil | yes | `MLXBackendThinkingTests.swift:166` (`test_noThinkingEvents_whenMarkersNotSet`) | — |
| MLX | token yield happy path | yes | `MLXBackendGenerationTests.swift:38` (`test_generate_yieldsInjectedTokens`) | — |
| MLX | cancellation via stream termination | yes | `MLXBackendGenerationTests.swift:95` (`test_generate_cancellation`) | — |
| MLX | generate-error propagation | yes | `MLXBackendGenerationTests.swift:141` (`test_generate_generateThrows_propagatesError`) | — |
| MLX | stop_reason variants (`.maxTokens` / EOS / cancel) | no | — | [#515](https://github.com/roryford/BaseChatKit/issues/515) |
| MLX | chat-template detection (missing `tokenizer_config.json`) | no | — | [#516](https://github.com/roryford/BaseChatKit/issues/516) |
| MLX | tool-call deltas (`<tool_call>` tags) | no | — | [#517](https://github.com/roryford/BaseChatKit/issues/517) |
| MLX | `capabilities` surface | yes | `MLXBackendTests.swift:28`-`:42` | — |

[^2]: DeepSeek-R1 uses the same `<think>/</think>` tags as Qwen3, so the qwen3 fixture effectively covers the token-shape. No fixture distinguishes the two at the template-detection layer.

### Llama

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| Llama | init / capabilities / context size | yes | `LlamaBackendTests.swift:32`-`:54` | — |
| Llama | loadModel invalid path | yes | `LlamaBackendTests.swift:58` (`test_loadModel_invalidPath_throws`) | — |
| Llama | loadModel empty GGUF | yes | `LlamaBackendTests.swift:78` (`test_loadModel_emptyFile_throws`) | — |
| Llama | plan-clamp honoured | yes | `LlamaBackendTests.swift:389` (`test_loadModel_fromPlan_clampRespected...`) | — |
| Llama | concurrent `stopGeneration` thread-safety | yes | `LlamaBackendTests.swift:229` | — |
| Llama | stop-then-regenerate (KV cache clear) | yes | `LlamaBackendTests.swift:257` (`...regression390`) | — |
| Llama | GGUF chat-template variants (ChatML / Llama3 / Gemma / Gemma4 / Mistral) | no | — | [#518](https://github.com/roryford/BaseChatKit/issues/518) |
| Llama | EOS token variants (`</s>` / `<|eot_id|>` / multi-EOG Gemma) | no | — | [#519](https://github.com/roryford/BaseChatKit/issues/519) |
| Llama | `n_batch` boundary (N, N+1, contextSize±1) | no | — | [#520](https://github.com/roryford/BaseChatKit/issues/520) |
| Llama | `llama_decode` error paths (prompt / generation) | no | — | [#521](https://github.com/roryford/BaseChatKit/issues/521) |
| Llama | `stopGeneration` fired mid-`llama_decode` | no | — | [#522](https://github.com/roryford/BaseChatKit/issues/522) |
| Llama | tokenizer heuristic fallback | yes | `LlamaBackendTests.swift:438`-`:459` | — |
| Llama | `countTokens` without model throws | yes | `LlamaBackendTests.swift:468` | — |
| Llama | memory-pressure auto-stop | yes | `LlamaBackendMemoryPressureTests.swift` (full file) | — |
| Llama | Llama-serialized load characterisation | yes | `LlamaBackendLoadSerializationCharacterizationTests.swift` (full file) | — |

### Foundation

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| Foundation | init + capabilities | yes | `FoundationBackendUnitTests.swift:132` (`test_capabilities_hasCorrectValues`) | — |
| Foundation | generate before load throws | yes | `FoundationBackendUnitTests.swift:44` | — |
| Foundation | unload clears state / idempotent | yes | `FoundationBackendUnitTests.swift:64` / `:76` | — |
| Foundation | resetConversation preserves isModelLoaded | yes | `FoundationBackendUnitTests.swift:94` / `:105` | — |
| Foundation | `isAvailable` is readable | yes | `FoundationBackendUnitTests.swift:122` | — |
| Foundation | probe session not retained as active | yes | `FoundationBackendUnitTests.swift:183` (hardware-gated) | — |
| Foundation | stop resets session | yes | `FoundationBackendUnitTests.swift:213` (hardware-gated) | — |
| Foundation | `GenerationOptions.topP/topK/seed/repeatPenalty` passthrough | no | — | [#523](https://github.com/roryford/BaseChatKit/issues/523) |
| Foundation | `SystemLanguageModel.Availability` variant handling | no | — | [#524](https://github.com/roryford/BaseChatKit/issues/524) |
| Foundation | cancellation timing mid-partial | no | — | [#525](https://github.com/roryford/BaseChatKit/issues/525) |
| Foundation | structured content-part types (non-monotonic diff) | no | — | [#526](https://github.com/roryford/BaseChatKit/issues/526) |
| Foundation | temperature passthrough | partial[^3] | `FoundationBackendUnitTests.swift:148` | — |

[^3]: Capability test asserts `.temperature` is in `supportedParameters` but no fixture drives a non-default value end-to-end.

### Claude

| Backend | Field | Fixture exists? | Test file / line | Gap issue |
|---|---|---|---|---|
| Claude | `text_delta` token extraction | yes | `SSEPayloadReplayTests.swift:45` (`test_claude_realStreamingResponse_extractsTokens`) | — |
| Claude | `message_start` prompt-token usage | yes | `SSEPayloadReplayTests.swift:74` | — |
| Claude | `message_delta` completion-token usage | yes | `SSEPayloadReplayTests.swift:84` | — |
| Claude | usage accumulation across events | yes | `SSEPayloadReplayTests.swift:125` (`test_claude_usageAccumulation_acrossEvents`) | — |
| Claude | `message_stop` isStreamEnd | yes | `SSEPayloadReplayTests.swift:91` | — |
| Claude | SSE `error` event extraction (`overloaded_error`) | yes | `SSEPayloadReplayTests.swift:101` (`test_claude_errorEvent_extractsError`) | — |
| Claude | 401/403 authentication failure | yes | `ClaudeBackendTests.swift:41` (`test_loadModel_withoutAPIKey_throws`) | — |
| Claude | conversation history in request body | yes | `ClaudeBackendTests.swift:141` | — |
| Claude | keychain-backed configure path | yes | `ClaudeBackendTests.swift:238` | — |
| Claude | stopGeneration mid-stream | yes | `ClaudeBackendTests.swift:198` | — |
| Claude | `thinking` / `thinking_delta` content blocks | no | — | [#527](https://github.com/roryford/BaseChatKit/issues/527) |
| Claude | `tool_use` streaming (`input_json_delta`) | no | — | [#528](https://github.com/roryford/BaseChatKit/issues/528) |
| Claude | `citations_delta` handling | no | — | [#529](https://github.com/roryford/BaseChatKit/issues/529) |
| Claude | `stop_reason` variants (`refusal` / `max_tokens` / `stop_sequence`) | partial[^4] | `SSEPayloadReplayTests.swift:57` | [#530](https://github.com/roryford/BaseChatKit/issues/530) |
| Claude | rate-limit error body shape + `anthropic-ratelimit-*` headers | partial[^5] | `ClaudeBackendTests.swift` (no body, only status) | [#531](https://github.com/roryford/BaseChatKit/issues/531) |
| Claude | interleaved content blocks (text + tool_use + thinking) | no | — | [#532](https://github.com/roryford/BaseChatKit/issues/532) |
| Claude | GGUF chat-template variants | n/a | — | — |

[^4]: Only `stop_reason: end_turn` is fixtured (implicitly, via the happy-path payload). `refusal`, `max_tokens`, `stop_sequence`, and `tool_use` are never driven.
[^5]: 429 is driven with empty body and `Retry-After: "0"` only. Structured Anthropic error body and the `anthropic-ratelimit-tokens-reset` header are not exercised.

### Summary

26 gap issues opened (#507–#532): 6 Ollama, 5 MLX, 5 Llama, 4 Foundation, 6 Claude. Each row above with a `no` or `partial` verdict links to the tracking issue. Re-run this audit whenever a new protocol field lands, or when a backend source file's public surface changes meaningfully.
