# Root causes — DX walkthrough iteration 1 (v0.50.0)

**Date**: 2026-06-14 · **MK version**: 0.50.0 (`v0.50.0-6-ge929ca40`)
**Scenarios**: 01-chat-cli (4 runs) + 02-swiftui-chat (4 runs), 8 agents total.

Causal grouping across both scenarios. Most surface-level findings collapse into
a small number of causes — two of them are the same packaging regression seen
from the CLI and SwiftUI sides.

---

## RC-1 — `ManifoldBackends` was retired in the P-series cleanup but the docs weren't [HEADLINE]

**Symptoms it explains** (5 of 6 completed runs):
- chat-cli B1 — `.product(name: "ManifoldBackends", …)` doesn't resolve (runs 1/2/3/4)
- swiftui B1 — `DefaultBackends.register(…)` doesn't compile (run-3)
- chat-cli minor — umbrella-product-vs-submodule import confusion (run-1)

**Cause**: The `ManifoldBackends` umbrella was demoted in the pre-1.0 P-series API
cleanup (commits `efb0c6f8`, `e929ca40`), landing **after the v0.50.0 tag**. In
v0.50.0's `Package.swift` it is exposed as **neither a `.library` product nor a
target** (verified: the only backend-ish product is `ManifoldBackendTestKit`).
`DefaultBackends` lives behind that now-unreachable boundary, and the umbrella's
`@_exported import ManifoldBackends` does not surface it to external consumers.

The docs and CLAUDE.md still describe `ManifoldBackends` as a live umbrella, so the
canonical "compile-tested" recipes are stale against the very tag a fresh consumer
pins. This is exactly the doc↔package drift this harness exists to catch — and
invisible to in-repo tests, which never resolve the package as an outside consumer.

**Confirmed locations**:
- `docs/QUICKSTART-CLI.md:84`, `:165`, `:404` — `.product(name: "ManifoldBackends", …)`
- `docs/SWIFTUI-MULTI-SESSION.md:142`, `:353` — `DefaultBackends.register(…)`; refs at `:170`, `:482`
- `CLAUDE.md` — describes `ManifoldBackends` as a live umbrella target/product

**Fix (one of):**
- (a) **Vend a `ManifoldBackends` `.library` product** that re-exports the families + `DefaultBackends`. Lowest doc churn; restores the documented API.
- (b) **Rewrite the recipes** to the per-family products: `import ManifoldOllama` + `OllamaBackends.register(with:)` (CLI) / drop `DefaultBackends` (SwiftUI). The agents verified this path works and it's arguably cleaner.
- Either way: sweep CLAUDE.md and any DocC articles.

**Recommendation**: This is a clean, high-value doc/packaging PR. Pick (a) if
`DefaultBackends`/umbrella-import is meant to remain public API; (b) if the
per-family split is the intended 1.0 surface. Decide the API intent first, then
fix docs to match.

---

## RC-2 — The MLX companion path has no SwiftPM runtime story and is under-documented end-to-end

**Symptoms it explains** (both MLX runs, 2/2 partial):
- chat-cli B2 / swiftui B2 — MLX aborts at unbuilt `default.metallib` under `swift build`/`swift run`
- chat-cli M2/M3, swiftui M2/M3/M4 + minors — no MLX CLI recipe, no MLX `ModelInfo`, no model-acquisition guidance, scattered wiring, companion local-path identity warning

**Cause**: mlx-swift compiles its Metal kernels into `default.metallib` only through
its Xcode/CMake build-tool path. A plain SwiftPM executable build never produces or
bundles the metallib, and MLX loads it relative to the executable at runtime — so
**MLX generation structurally cannot work from a bare `swift run`**; it needs an
Xcode-built `.app`. Everything *up to* generation works (discovery, `[mlx]`
classification, registry wiring, load-plan), which makes the failure especially
confusing — a cryptic C++ runtime error with no doc pointer. On top of the runtime
cliff, the MLX surface lacks a quickstart, a headless `ModelInfo` entry point, a
recommended model id, and a local-path companion form.

**Fix**:
- Document the metallib/Xcode-bundle requirement prominently in the manifold-mlx README *and* in ManifoldKit's MLX docs — the Simulator caveat exists but the common macOS-CLI case doesn't. State plainly: "MLX requires an Xcode `.app` build; `swift run` cannot load MLX kernels."
- Add an MLX quickstart (CLI + SwiftUI) parallel to the GGUF one, including a recommended `mlx-community` model id + `hf download` command and a documented headless `ModelInfo` route (or a `ModelInfo(mlxURL:)` factory mirroring `ggufURL:`).
- Document the local-path companion form (see RC-5).

**Recommendation**: Two tracks — a fast doc PR (the metallib warning is the
highest-leverage single line; it converts a silent blocker into a known
constraint), and a follow-up on whether to expose a headless MLX `ModelInfo`
factory. The metallib cliff likely warrants a tracked issue if it can't be fixed
in mlx-swift's SwiftPM build.

---

## RC-3 — `QUICKSTART-CLI.md` §1 manifest is internally inconsistent

**Symptom**: chat-cli M1 — §1 declares `swift-tools-version: 6.1` but uses
`.macOS(.v26)` (needs 6.2); the manifest is rejected before resolution.

**Cause**: A Foundation example must target macOS 26 (the backend's floor) but the
tools-version line was left at 6.1. Isolated to §1 (§2/§3 correctly use 6.1 for
`.macOS(.v15)`). **Fix**: bump §1 to `6.2`. Trivial; bundle with the RC-1 doc PR.

---

## RC-4 — [HARNESS, not MK] Worktree isolation + GC destroys agent deliverables

**Symptom**: chat-cli run-1 & run-3 lost their `FRICTION.md`/`NOTES.md`/`session.log`;
run-3's whole worktree was pruned before harvest. (Content recovered from
completion reports, so this synthesis is intact — but the raw logs are gone, and a
silent run could have lost everything.)

**Cause**: Agents were dispatched with `isolation: worktree`. The Write/Edit tools
pin to the worktree path even when given a main-checkout absolute path, so
deliverables land *inside* the worktree; the harness then prunes worktrees on
agent completion. run-2 survived only because it detected this and wrote via `Bash`
heredoc to the persistent main checkout.

**Fix (harness)** — update `scripts/dx-walkthrough/README.md` and `run.sh`'s
dispatch prompt:
- These agents are **read-only against ManifoldKit** (forced-blindness forbids touching `Sources/`/`Tests/`); they only *create a separate consumer app*. They do **not** need worktree isolation. **Drop `isolation: worktree`** for this harness — agents can write straight to the main-checkout run dir, and there's no mutation to isolate.
- If isolation is kept for build sandboxing, instruct agents to write all deliverables via `Bash` to the absolute main-checkout run dir (not Write/Edit), and have the orchestrator harvest *incrementally* as each agent completes (before GC), not at the end.

**Recommendation**: Adopt "drop worktree isolation" — simplest and removes the
class entirely. It also dissolves M1 in the SwiftUI scenario (the `.build` desync
came from building against a live churning worktree).

---

## RC-5 — Local-path companion + URL-pinned core → SwiftPM identity collision

**Symptoms**: chat-cli run-3 minor, swiftui run-4 M4 — `Conflicting identity for
manifoldkit` warning when an app pins ManifoldKit by local path while a companion
(manifold-llama / manifold-mlx) pins it by GitHub URL. Resolves today; SwiftPM
warns it "will be escalated to an error in future versions."

**Cause**: The companion packages pin ManifoldKit by URL; a local-checkout
evaluator pins by path; SwiftPM unifies on the `manifoldkit` identity but flags the
divergent coordinates. The docs only ever show the URL form, so the local
multi-checkout setup (the exact dev workflow CLAUDE.md endorses) is undocumented
and on a forward-compat clock.

**Fix**: document the local-path companion form and the dual-local-checkout
override pattern (both core and companion by path so identity unifies). Tie to
RC-2's MLX docs. Low urgency but a known time bomb.

---

## Priority ranking for PRs

1. **RC-1** — doc/packaging fix (decide API intent, then fix docs + CLAUDE.md). Highest value: unblocks every fresh CLI *and* SwiftUI consumer. Bundle **RC-3** in.
2. **RC-2 (doc track)** — the MLX metallib warning + an MLX quickstart. Converts a silent structural blocker into a documented constraint.
3. **RC-4** — harness fix (drop worktree isolation). Cheap; prevents data loss next iteration.
4. **RC-5** — local-path companion docs. Low urgency.

---

# Deeper repo-wide investigation (2026-06-14, 5-agent sweep)

A follow-up sweep showed RC-1 and RC-3 are not isolated doc typos — they are the
visible tip of **one code-level retirement (P7 / #1837 "retire deprecated
ManifoldBackends/ManifoldCloud @_exported shims") that shipped without sweeping
its docs, examples, and generated artifacts — compounded by a CI gate that
structurally cannot catch it.** Every finding below is the *same bug class*.

## RC-1-DEEP — the real root cause: retirement without a sweep, + a CI blind spot

**The systemic hole.** The only gate that compiles doc code is
`readme-snippets.yml` → `scripts/extract-snippets.sh`. It **deliberately skips
every `Package.swift` manifest fragment** (`extract-snippets.sh:222-233`: any
fence beginning `.package(`, `.target(`, or `import PackageDescription` is tagged
`package-manifest-fragment` and not built). So the exact place dead product names
and wrong tools-versions live is exempt from validation. The gate is **green
(12/12) while the docs are broken.** And coverage is incomplete:
`docs/SWIFTUI-MULTI-SESSION.md` (9 swift fences, "complete end-to-end recipe") is
**not in the INPUTS list at all** — zero coverage. The bundled `Example/` app and
the generated `affected-suites-graph.json` aren't validated against reality either.

Net: any rename/retirement rots docs + examples + the dep graph, and CI says
nothing. This will recur on every future API change until the gate is fixed.

## Full blast radius of the ManifoldBackends/ManifoldCloud/DefaultBackends retirement

### Build-breaking for a fresh consumer (or a shipped artifact)
- `docs/QUICKSTART-CLI.md:84,165,404` — `.product(name: "ManifoldBackends", …)` (phantom product)
- `docs/QUICKSTART-BRING-YOUR-OWN-UI.md:14` — same phantom product (its own source imports the right families — self-contradicting)
- `docs/AppStoreSubmission.md:110` — `import ManifoldBackends` (phantom module)
- `docs/CLOUD-OAUTH.md:33,117,118,149,150` — `import ManifoldCloud` (retired shim)
- **`Example/Advanced/ManifoldDemoApp.swift:7`** — `import ManifoldBackends`, **plus `Example/Advanced.xcodeproj/project.pbxproj` links the phantom product (5 refs).** A *shipped* example, not just a doc. (`example-ui-smoke.yml` references `Example/` — verify whether it actually builds the `Advanced` target; if so it should be red, if not the example rotted unguarded.)
- `AGENTS.md:105` — `DefaultBackends.register(with:)` in the file's most-copied bootstrap recipe (`DefaultBackends` type no longer exists)
- `docs/SWIFTUI-MULTI-SESSION.md:142,353` — `DefaultBackends.register(...)` (the §6 recipe = DX blocker B1; ungated doc)

### `DefaultBackends` type is gone — referenced as live API in
`docs/QUICKSTART.md:72,166`, `docs/SCOPE_DECISION.md:11`, `CONTRIBUTING.md:144`,
`AGENTS.md:32,105`, `CLAUDE.md:34`, `SWIFTUI-MULTI-SESSION.md:170,482`.

### Stale architecture prose (misleads, doesn't break builds)
- `CLAUDE.md` — 7 stale `ManifoldBackends`/`ManifoldCloud`/`DefaultBackends` spots (lines 32,34,81,83,85,87 + table rows 65,67)
- `README.md:197,236,245`, `CONTRIBUTING.md:64,77,180`, `SECURITY.md:74` (dead path `Sources/ManifoldBackends/Cloud/*`), `FIPS.md:236`, `RELIABILITY.md:15`, `QUICKSTART.md:32`, `QUICKSTART-VOICE.md:41`
- DocC: `ManifoldInference.docc/ManifoldInference.md:22`, `ManifoldRuntime.docc/ManifoldRuntime.md:15,36` (lists retired `ManifoldCloud` + companion-moved MLX/Llama as in-repo families), `ManifoldUI.docc/.../GenerationComponents.md:94,124`
- `DefaultWebSearchRuntime` moved `ManifoldCloud` → `ManifoldCloudCore`; DocC still points at the old home.

### Generated artifact stale (CI-affecting)
- `scripts/affected-suites-graph.json:124,134` (+ edges) — nodes `Sources/ManifoldCloud` and `Sources/ManifoldBackendsUmbrella` point at **deleted** dirs. Regenerate (don't hand-edit).

## RC-6 — a SECOND, independent rot pattern: CLAUDE.md dep claims drifted from Package.swift

Separate from the retirement, CLAUDE.md's dependency descriptions no longer match
`Package.swift` — architecture docs weren't updated when edges moved in P-series:
- `ManifoldFoundation` documented as "**Contract only — no engine-state dependency**" but actually depends on **`ManifoldContract` + `ManifoldInference`** (the relocated `FoundationBackends` registrar needs the engine). (CLAUDE.md:29 vs Package.swift:381-385)
- `ManifoldCloudCore` documented as "Depends on `ManifoldInference`" but now also depends on **`ManifoldRuntime`** (for `DefaultWebSearchRuntime`'s port conformance). (CLAUDE.md:33 vs Package.swift:354-368)
- `ManifoldFuzzBackends` / `manifold-tools` deps described via the dead umbrella.

No test validates CLAUDE.md/AGENTS.md claims against `Package.swift` — `AgentsMdAuditTest` only aligns the two text files to each other and checks for a few literal substrings, not against package reality. So both files can (and did) drift freely.

## RC-3 status: NARROW (good news)
The tools-version/platform mismatch is a **single instance** (QUICKSTART-CLI §1,
line 64). Not a systemic pattern — every other snippet's tools-version matches its
platforms. One-line fix (6.1 → 6.2).

## Remediation plan (deeper)

1. **Sweep PR** — fix all build-breaking refs above (QUICKSTART-CLI/BYO-UI/AppStore/CLOUD-OAUTH docs + **the Example/Advanced app** + AGENTS.md:105 recipe + SWIFTUI-MULTI-SESSION §6), regenerate `affected-suites-graph.json`, bump QUICKSTART-CLI §1 tools-version. Decide the API intent first (re-vend `ManifoldBackends` product, or commit to per-family + `quickStart(backends:)`).
2. **Close the CI blind spot (the durable fix)** — in `scripts/extract-snippets.sh`, stop blanket-skipping manifest fragments: text-validate them instead (every `.product(name:)` exists in `Package.swift` `products:`; `swift-tools-version` ≥ repo floor). Strongest form: write full `Package.swift` fragments to a temp dir + trivial `main.swift` and run `swift package resolve`. Add `docs/SWIFTUI-MULTI-SESSION.md` to INPUTS + the `readme-snippets.yml` paths filter. This turns *both* DX blockers into red CI.
3. **CLAUDE.md + AGENTS.md accuracy PR** — fix the 7 retirement-stale spots + the 3 dep inaccuracies (RC-6). Respect AGENTS.md test landmines (keep literal `"umbrella module"` / `"BackendName.foundation"` substrings). Consider a lightweight audit that checks CLAUDE.md target/dep claims against `Package.swift`.
4. **MLX docs (RC-2)** and **local-path companion docs (RC-5)** — separate, lower urgency.

---

## Coverage gap to close next iteration

The drop-in `ChatView` + `quickStart` path (SwiftUI run-1) and the Foundation
SwiftUI path (run-2) have **no completed data point** — both stalled after their
cold builds. The "easy mode" SwiftUI happy path is therefore unverified on
v0.50.0. Re-run both to completion before declaring the SwiftUI DX healthy.
