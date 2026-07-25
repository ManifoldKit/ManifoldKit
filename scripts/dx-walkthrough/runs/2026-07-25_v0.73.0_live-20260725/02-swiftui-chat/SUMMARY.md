# swiftui-chat archetype — live (v0.73.0, 2026-07-25)

**Date**: 2026-07-25  
**MK version**: 0.73.0 (checkout `d023b1a6`, describe `v0.73.0-29-gd023b1a6`)  
**Agent model**: Grok Build general-purpose subagents (3 runs)  
**App outcome**: **all three runs working** — generation + session persistence verified on each path

First full three-path `02-swiftui-chat` completion since v0.50.0 (iter-1 left Ollama+ChatView and Foundation incomplete; iter-2 only closed the ChatView gap). Forced-blindness held; no worktree isolation (RC-4 lesson).

## Backend / path coverage

| Run | Path | Outcome | Persistence verified? |
|---|---|---|---|
| 1 | Ollama + `quickStart()` + drop-in `ChatView` / `SessionListView` | ✅ working | yes — same session id across restarts |
| 2 | Apple Foundation Models + `quickStart()` multi-session | ✅ working | yes — messages 2→4→6 across launches |
| 3 | Manual `ManifoldBootstrap.build` + Ollama + multi-session UI | ✅ working | yes — same session UUID + message rows |

## Blockers

**None.** Every path compiled, launched, generated, and restored sessions without source-peeking.

The v0.50-era blockers are gone or out of scope this run:

| Prior | Status this iteration |
|---|---|
| B1 `DefaultBackends` unreachable in §6 | **Disappeared** — run-3 used explicit family registrars; no agent hit `DefaultBackends` |
| B2 MLX metallib / companion path | **Out of scope** — no MLX run this iteration |

## Major findings

### M1 — Doc contradiction: does `quickStart()` auto-load Foundation? [run-2, DOC-WRONG]

`SWIFTUI-MULTI-SESSION.md` §2 claims `quickStart()` dispatches a load for the built-in policy (Foundation-first, then on-disk GGUF). `QUICKSTART.md` says Foundation is registered but **not** auto-selected and requires `foundationModelProvider` + `loadFoundationModelIfAvailable()`. Runtime matched **QUICKSTART** — without those two steps, generation fails. A fresh macOS 26 evaluator following multi-session alone ships a dead composer.

### M2 — "Full recipe" §6 under-documents Ollama model load [run-1, run-3, DOC-MISSING]

`SWIFTUI-MULTI-SESSION.md` §6 inserts an `APIEndpointRecord` but never sets `selectedEndpoint` / `setAvailableEndpoints` / `await loadSelectedEndpoint()`. Result: clean UI, inert composer (`isModelLoaded == false`). The triad lives only in `QUICKSTART.md` "Seeding an Ollama endpoint". Run-1 (quickStart post-seed) and run-3 (manual first-launch **and** relaunch) both hit this.

### M3 — Manual path: endpoint not re-bound on relaunch [run-3, DOC-MISSING / API-ERGONOMICS]

After `configureAndLoad` → `selectInitialSession` → `switchToSession`, sessions restore correctly but `chatVM.selectedEndpoint` stays `nil` unless the host re-selects and `loadSelectedEndpoint()`s. QUICKSTART documents this as automatic for the `quickStart` relaunch story; the manual scaffold has no equivalent paragraph.

### M4 — `.environment(\.endpointStore, …)` not on umbrella [run-1, DOC-WRONG]

Documented multi-session / AGENTS bootstrap injection fails with only `import ManifoldKit`: `EnvironmentValues` has no `endpointStore`. Key lives with `ManifoldUIModelManagement` (needed for `APIConfigurationView` anyway). Snippets that show the injection without that product/import mislead.

### M5 — Foundation + session churn: `isModelLoaded` false positive [run-2, API-ERGONOMICS | API-GAP]

After `createSession()` + `switchToSession`, ChatViewModel can report `isModelLoaded == true` while `sendMessage` fails with `InferenceError.inferenceFailure("No model loaded")`. Worked around by staying on the restored session and re-calling Foundation load; dirty store needed a wipe during smoke. Sharp edge, not a first-launch blocker.

### M6 — `platforms: [.macOS(.v26)]` needs tools-version 6.2 [run-2, DOC-WRONG]

`'v26' is unavailable` under `// swift-tools-version: 6.1`. QUICKSTART-CLI is correct (6.2); general QUICKSTART still says 6.1+ without warning when targeting macOS 26 / Foundation.

### M7 — Bare SwiftPM executable is a fragile SwiftUI host [run-1, run-2, major→minor env]

No `.app` bundle → flaky activation, missing bundle identifier, AppKit layout crash with extra wrappers around `NavigationSplitView` (run-2 SIGTRAP). Packaging a minimal `.app` (run-1) or matching docs' root shape (run-2) recovered. Environment limit for DX harnesses more than product API, but still undocumentated for consumers who skip Xcode.

## Minor / papercut

| Finding | Run(s) | Sev |
|---|---|---|
| Happy path split across QUICKSTART + multi-session + MinimalExample (no single copy-paste) | 1, 2, 3 | minor–major cluster above |
| MinimalExample is single-session `quickStart` only — no Foundation seed, no sidebar | 2, 3 | minor |
| Mic banner without `NSMicrophoneUsageDescription` (opt-out via features flag not in multi-session snippet) | 1 | papercut |
| `import SwiftData` required for `.modelContainer` but omitted from some §6 snippets | 3 | papercut |
| `ManifoldUIModelManagement` second product for model browser / API config | 3 | minor |
| `quickStart(backends:configuration:)` argument order (`backends` first) | 2 | papercut (known since v0.50) |
| Documents-folder access prompt on bare SPM executable (Ollama path) | 3 | minor |
| stdout buffering / TCC black screenshots under automation | 1–3 | papercut (env) |

## Positives (preserve)

- **All three paths ship end-to-end** without opening Sources — core chat APIs are discoverable from docs.
- **Persistence is still a standout**: same session UUID / growing message counts across quit+relaunch on every run; `#1464` `configureAndLoad` + restore-before-mint guidance works.
- **Umbrella `import ManifoldKit`** covers `ChatView`, `SessionListView`, `SessionManagerViewModel`, `quickStart`, Ollama seed types, Foundation registrars (model-management UI correctly opt-in).
- **Cold consumer builds ~47–57s** with warm caches against local path dep; explicit `name: "ManifoldKit"` works first try.
- **Drop-in `ChatView` + `SessionListView`** look production-ready once a model is actually loaded.
- **v0.50 B1 (`DefaultBackends`) is gone** from the evaluator experience — family registrars are the live path.

## Verdict

The SwiftUI multi-session surface is **healthy on v0.73.0** across Ollama (quickStart + manual) and Foundation. Remaining pain is **doc seams and load-ceremony**, not missing chat/session APIs:

1. Make multi-session §2 and QUICKSTART agree on Foundation auto-load (or change runtime to match one story).
2. Finish §6 / multi-session Ollama recipes with the `selectedEndpoint` + `loadSelectedEndpoint()` triad (first launch **and** manual relaunch).
3. Qualify `.environment(\.endpointStore)` with `import ManifoldUIModelManagement`.
4. Optionally wire Foundation + multi-session into MinimalExample so the "canonical sample" is not a dead-composer trap on macOS 26.

## Follow-up for next iteration

- Re-run after doc fixes to M1–M4; expect majors to drop to papercuts.
- Optional fourth run: MLX companion path (re-check B2 / metallib guidance post-0.48 split).
- Prefer Xcode `.app` or pre-bundled SwiftPM `.app` in harness to reduce host noise (M7).
