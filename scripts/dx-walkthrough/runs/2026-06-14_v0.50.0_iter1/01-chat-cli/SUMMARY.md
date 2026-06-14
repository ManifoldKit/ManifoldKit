# chat-cli archetype — iteration 1 (v0.50.0)

**Date**: 2026-06-14
**MK version**: 0.50.0 (git `v0.50.0-6-ge929ca40`)
**Agent model**: Opus 4.8 (all 4 runs)
**App outcome**: **3/4 reached working CLIs; 1 partial (MLX)**

First DX walkthrough since the v0.48 packaging split and the pre-1.0 "P-series"
API cleanup. Four runs deliberately spread across backend surfaces (methodology:
variation is signal).

## Backend coverage this iteration

| Run | Path | Outcome | Notes |
|---|---|---|---|
| 1 | Ollama (`llama3.1:8b`) | ✅ working | ~5 min from docs to multi-turn streaming CLI |
| 2 | Apple Foundation Models | ✅ working | 2 real cycles, clean EOF |
| 3 | Local GGUF via `manifold-llama` companion | ✅ working | real on-device Llama-3.1-8B on Metal |
| 4 | MLX via `manifold-mlx` companion | ⚠️ partial | builds/loads/streams **only** after a manual `default.metallib` workaround |

Overall verdict across runs: the cloud/Ollama/GGUF CLI story is **strong** —
fast, low-guesswork, gotchas spelled out. Two doc/packaging defects block a
*verbatim* copy-paste, and the MLX path has an undocumented structural cliff.

## Blockers (must-fix)

### B1 — `ManifoldBackends` SwiftPM product does not exist [4/4, blocker]
**The unanimous finding.** Every run's `Package.swift`, copied from
`docs/QUICKSTART-CLI.md`, declares `.product(name: "ManifoldBackends", package:
"ManifoldKit")` (doc lines 84 / 165 / 404 — all three CLI sections). That product
was retired in the P-series cleanup (post-v0.50.0 tag; commits `efb0c6f8`,
`e929ca40`). It is exposed as **neither a `.library` product nor a target** in
v0.50.0's `Package.swift`. A fresh dev pinning v0.50.0 and copy-pasting the
"compile-tested" quickstart is **hard-stopped at dependency resolution**:
`product 'ManifoldBackends' ... not found in package 'ManifoldKit'`.

The examples are internally contradictory: the manifest names the phantom
umbrella product, while each example's `main.swift` already imports the *real*
modules (`ManifoldFoundation` / `ManifoldOllama` / `ManifoldCloudSaaS`). CLAUDE.md
also still describes `ManifoldBackends` as a live umbrella. See ROOT_CAUSES.md RC-1.

**Fix**: either (a) vend a `ManifoldBackends` `.library` product that re-exports
the families, or (b) rewrite the quickstart manifests to list the three per-family
products (or just the `ManifoldKit` umbrella). Sweep CLAUDE.md too.

### B2 — MLX cannot generate under plain `swift run` [run-4, blocker]
mlx-swift hardcodes a relative `default.metallib` path, but a SwiftPM executable
build never compiles/bundles the Metal kernels — there is no `default.metallib`
anywhere in `.build/`. MLX aborts at Metal init
(`mlx-c/mlx/c/stream.cpp:115 — Failed to load the default metallib`). Discovery,
classification (`[mlx]`), registry wiring and load-plan all worked perfectly up to
that boundary. The agent only got tokens by hand-compiling the 8 `.metal` kernels
with `xcrun metal`/`metallib` — out of reach for a docs-only dev. The docs warn
about the *Simulator* Metal caveat but not the far-more-common macOS-CLI case.
Cross-confirmed by swiftui/run-4. See ROOT_CAUSES.md RC-2.

## Major

### M1 — QUICKSTART-CLI §1 won't parse: tools-version 6.1 vs `.macOS(.v26)` [run-2, major]
§1 (the Foundation example) declares `// swift-tools-version: 6.1` but uses
`.macOS(.v26)`, introduced in PackageDescription 6.2 — SwiftPM rejects the
manifest before any dependency resolves (`'v26' is unavailable`). A Foundation
example *must* target macOS 26, so it *must* use 6.2. The README's own
Requirements section even says so; §1 contradicts it. (§2/§3 correctly use 6.1
because they target `.macOS(.v15)`.) **Fix**: bump §1 to `6.2`.

### M2 — No MLX CLI recipe [run-4, major]
`QUICKSTART-CLI.md` has worked recipes for Foundation (§1), GGUF (§2), Cloud (§3)
but **no MLX section** — MLX appears only as a commented-out `.package(...)` line.
The one backend with the runtime cliff (B2) is also the one with no end-to-end
recipe.

### M3 — No documented `ModelInfo` for a local MLX directory [run-4, major]
Public docs document `ModelInfo(ggufURL:)` only. There is no documented way to
build a `ModelInfo` for an MLX directory for the headless
`InferenceService.loadModel(from:plan:)` path — the real route is
`ModelStorageService().discoverModels()` → registry, undiscoverable from docs.
Cross-confirmed by swiftui/run-4.

## Minor / papercut

- **Umbrella-product-vs-submodule import mismatch** [run-1, minor] — examples depend on the (phantom) `ManifoldBackends` product but `import` the granular modules; the relationship isn't spelled out. Moot once B1 is fixed.
- **`provider: .ollama` vs README's `OpenAIBackend` framing** [run-1, minor] — the README "Supported Model Types" table lists Ollama under `OpenAIBackend`, while §3 uses `APIEndpointRecord(provider: .ollama)`. Not contradictory, but the `APIProvider`-case ↔ backend-class mapping isn't documented.
- **Companion + local-path identity** [run-3, minor] — when evaluating against a local ManifoldKit checkout *and* a companion package, the companion's URL-pinned ManifoldKit dependency must unify with the local-path core. SwiftPM emits `Conflicting identity for manifoldkit ... will be escalated to an error in future versions`. Resolves today; latent forward-compat hazard. Docs only ever show the URL form. See ROOT_CAUSES.md RC-5.

## Harness defect (not a ManifoldKit issue)

**Worktree GC destroyed deliverables** [run-2 logged it; run-1 & run-3 victims].
Agents ran in isolated git worktrees; Write/Edit pinned to the worktree path; the
harness pruned worktrees on agent completion. run-3's worktree was GC'd and its
`FRICTION.md`/`NOTES.md`/`session.log` were lost (only `app/` was harvested in
time); run-1 likewise lost its friction log. run-2 alone survived intact because
it detected the trap and wrote deliverables via `Bash` heredoc to the persistent
main checkout. **Content was recovered from agents' completion reports**, so this
synthesis is unaffected — but the raw logs are gone. See ROOT_CAUSES.md RC-4 for
the harness fix.

## Positives (worth preserving)

- Headless CLI DX is genuinely fast once B1 is worked around: ~5 min docs→multi-turn streaming on Ollama; multi-turn history and clean Ctrl-D "just worked."
- Local on-device GGUF via the companion package produced real Metal-backed inference with near-zero guesswork (run-3).
- The GGUF/Foundation quickstart *narrative* (gotchas, multi-turn, reasoning) is strong — the defects are packaging/version drift, not pedagogy.
