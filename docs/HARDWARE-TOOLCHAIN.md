# Hardware and toolchain constraints

**Audience:** contributor
**Status:** living

A one-page consolidation of the hardware- and CI-specific constraints that
recur across core and both companion packages. Each of these has bitten this
project at least once; they're gathered here instead of staying scattered
across `Package.swift` comments, `CLAUDE.md`, and script headers so a new
companion package doesn't have to rediscover them.

## OS availability

**`FoundationBackend` requires iOS 26 / macOS 26.** The bridge is gated with
`@available(iOS 26, macOS 26, *)` throughout
(`Sources/ManifoldFoundation/FoundationBackend.swift`,
`FoundationAvailabilityReason.swift`) and by `#if canImport(FoundationModels)`
at the target level — there is no trait for this any more (retired in v0.48).
Gate any code that touches the bridge accordingly; it compiles unconditionally
but only *works* on the current OS.

ManifoldKit's general platform floor is **n-1**: the current Apple OS release
and the one immediately before it (currently macOS 26 / 15, iOS 26 / 18 — see
`CLAUDE.md` → Platform policy). `Package.swift`'s `platforms:` declares
`.iOS(.v18)` / `.macOS(.v15)` as the package-wide minimum; `FoundationBackend`
is the one target that needs a higher floor than the package minimum.

## Local-backend hardware gating (companion packages)

The MLX and llama.cpp process/Metal constraints below now live primarily in
the companion repos, since the backends themselves moved there in v0.48 (PR
C2, #1749) — `docs/LLAMA_CONTRACT.md` in this repo is a redirect stub pointing
at `manifold-llama`'s copy. What's still true and visible from core:

- **Flash Attention is disabled by default in the simulator.**
  `BackendLoadOptions.platformDefaultFlashAttention`
  (`Sources/ManifoldInference/Models/BackendLoadOptions.swift:63,65`) returns
  `false` under `#if targetEnvironment(simulator)` because simulator Metal
  does not reliably support FA kernels; a local backend loader should honor
  an explicit simulator override the same way.
- **`llama_backend_init` is process-global — one llama.cpp instance per
  process.** This is why core's own eval/fuzz tooling and `manifold-tools`
  never link two local-inference families into the same process: the
  `manifold-tools` CLI links `ManifoldOllama` + `ManifoldCloudSaaS` directly
  and deliberately never used the (now-retired) `ManifoldBackends` umbrella,
  because that umbrella would have pulled `ManifoldMLX` and `ManifoldLlama`
  into the same executable's link graph (`Sources/manifold-tools/main.swift:9`,
  `CLAUDE.md`'s `manifold-tools` row). This was tracked as **#982**, the
  "dual-llama Xcode-scheme hazard" — a build target that links both local
  families hits an Xcode scheme collision, and even if it linked cleanly,
  `llama_backend_init` can't be called twice in one process. If you're
  building a driver that needs to exercise multiple local families, run each
  family in its own process (this is how the eval harness's `ConformanceRecord`
  model works — one record per `(model × quant × backend × renderer)` cell,
  collated across separate process runs).
- **Metal-in-simulator and metallib staging for MLX** are owned by
  `manifold-mlx`'s own build scripts now — follow that repo's docs when your
  companion package needs to load a real Metal shader library; core no longer
  ships any metallib-staging logic.

## Swift Testing vs. XCTest — separate processes, always

Mixing Swift Testing (`@Test`/`@Suite`) and XCTest in the same test process
triggers a libmalloc double-free `SIGABRT` — tracked as **#681**. This is not
a "sometimes"; core's own `scripts/test.sh` runs a deliberate three-invocation
shape specifically to avoid it: the XCTest filter batch first, then
`ManifoldBackendsTests` in its own process with `--parallel` (that target mixes XCTest
with Swift Testing files), then `ManifoldInferenceSwiftTestingTests` in a
fully separate `swift test` process (see the `PROFILE_*_FILTERS` arrays in
`scripts/test.sh`; `Tests/README.md`). A companion package that adds Swift
Testing suites alongside existing XCTest suites needs the same per-process
split in its own CI, not a single `swift test` call.

## `swift-tools-version` ceiling

**The `swift-tools-version` ceiling is whatever Xcode version CI actually
runs.** Core's manifest declares `swift-tools-version: 6.1`
(`Package.swift:1`) deliberately below the newest available toolchain. The
current core CI pin is Xcode 26.3 / Swift 6.3; bumping the tools version above
the selected CI toolchain breaks `resolve-check` and the fuzz harness.
`companion-compat.yml` (core's pre-release companion canary) is
explicit about the companions needing a *newer* selected toolchain than the
image default: it force-selects "the newest Xcode 26 toolchain" via
`xcode-select` because the companions' own CI needs Swift 6.3 to prune
trait-disabled edges correctly (`.github/workflows/companion-compat.yml:51-58`).
Don't assume core and a companion package need the same tools-version ceiling
— check what each repo's own CI runner actually has installed before bumping.

## CI runner shape

- **macOS runners, 10× billing.** Core's CI runs on `macos-15` (Apple Silicon)
  specifically to reduce spend relative to Intel runners
  (`.github/workflows/ci.yml:305` and others). Every CI run — core or
  companion — is macOS-only and billed at GitHub's 10× multiplier for macOS
  minutes; a failed push wastes real money, not just time. Run the local test
  gate before every push rather than treating CI as the iteration loop.
- **CI runners ship Bash 3.2 as `/bin/bash`, not a newer bash.** macOS ships
  Bash 3.2 by default on GitHub-hosted runners, so `declare -A` (associative
  arrays) and `mapfile` (needs bash 4+) are unavailable in any script CI
  executes. Core's own scripts route around this everywhere — see
  `scripts/lint-no-new-force-unwraps.sh`, `scripts/extract-snippets-test.sh`,
  `scripts/affected-suites.sh`, `scripts/demo-apps-build.sh`,
  `scripts/check-coverage.sh`, and `scripts/measure-trait-costs.sh`, all of
  which use parallel indexed arrays instead of associative arrays with a
  comment citing the Bash 3.2 constraint. Test any CI-invoked shell script
  edit by running it under `/bin/bash` explicitly, not your interactive
  dev shell (which is very likely a newer bash or zsh).
- **Companion CI selects its own Xcode.** As noted above, a companion
  package's CI may need to explicitly `xcode-select` a newer toolchain than
  the runner image default resolves to — don't assume the default Xcode on
  a `macos-15` runner matches what your companion's dependency graph needs.

## Metal .metallib resource bundling for SPM executables

When a SwiftPM executable target (CLI, menubar tool) transitively depends on
Metal-backed modules (e.g., MLX-related code paths), the executable may fail at
runtime with:

```
Failed to load the default metallib
```

sometimes accompanied by:

```
Failed to create NSXPCConnection
```

### Root cause

SwiftPM executable targets do not receive the Metal resource bundle treatment
that app targets (Xcode-built `.app` bundles) get. The `.metallib` (compiled
Metal shader library) is not copied into the executable's bundle or working
directory at build time. An app target's build phase automatically copies this
resource, but a bare SPM CLI or menubar executable has no equivalent step. At
runtime, the Metal framework looks for the default metallib next to the binary,
fails to find it, and the associated XPC service connection (used for Metal
compilation and loading) fails to establish.

This is a packaging gap, not a logic bug in the Metal-consuming code itself.

### Workaround

Run the Metal-dependent code path via the full app target (Xcode-built `.app`
bundle), not as a standalone SPM executable via `swift run`. There is no known
workaround for running a CLI or menubar target standalone with Metal support.

### Durable fix

The real fix — either copying the `.metallib` into the executable's run
location at build time (via a build plugin or post-build step), or failing fast
with an actionable error identifying the missing resource — lives in the
`manifold-mlx` companion package, which owns the Metal-dependent code paths.
Core has no Metal executables to exercise after v0.48's backend split, so a
fix here would be inert code. Track this in [ManifoldKit/manifold-mlx#149](https://github.com/ManifoldKit/manifold-mlx/issues/149).

## Where to go next

- [`docs/COMPANION-BACKENDS.md`](COMPANION-BACKENDS.md) — the companion
  package build/adoption/release guide these constraints feed into.
- [`Tests/README.md`](../Tests/README.md) — the "Special cases" section
  documents the Swift Testing/XCTest split and other test-runner quirks in
  more detail, with the exact suites affected.
- [`docs/QA-PRACTICES.md`](QA-PRACTICES.md) — the local real-model
  integration + perf sweep (§5) is the closest thing to a real-hardware CI
  signal, run by hand rather than scheduled, precisely because these hardware
  constraints make it unsafe to schedule on shared CI runners.
- `docs/LLAMA_CONTRACT.md` — redirect stub to `manifold-llama`'s own
  llama.cpp C-API contract document (threading, ownership, capacity limits).
