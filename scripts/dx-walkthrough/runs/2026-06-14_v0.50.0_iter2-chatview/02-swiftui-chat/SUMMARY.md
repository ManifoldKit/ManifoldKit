# swiftui-chat archetype — iter2 (v0.50.0, ChatView happy-path gap-fill)

**Date**: 2026-06-14
**MK version**: 0.50.0 (post #1847/#1849/#1851/#1852)
**Agent model**: Opus 4.8 (1 run)
**App outcome**: ✅ working — **the drop-in `ChatView` happy path is HEALTHY on v0.50.0**

## Why this run exists

The v0.50.0 iter-1 walkthrough left the **drop-in `ChatView` + `quickStart()` "easy mode" path unverified** — run-1 (Ollama+ChatView) and run-2 (Foundation) both stalled after their cold builds (8 parallel builds saturated the machine) and never produced a completed data point. iter-1's confirmed SwiftUI data came only from the *hand-assembled* (run-3) and *MLX* (run-4) paths. This run closes that gap.

Harness note: dispatched **without `isolation: worktree`** (per the RC-4 lesson — DX agents only read MK, so isolation only invites the worktree-GC deliverable-loss path). Deliverables landed intact in the main checkout; no harvest dance needed.

## Result

A ~90-line macOS SwiftUI app using **`ManifoldKit.quickStart()`** (one-call bootstrap) + drop-in **`ChatView`** + `SessionListView` sidebar — the documented multi-session shape, **no hand-assembled view models** — backed by a pre-seeded Ollama endpoint (`localhost:11434`, `llama3.1:8b`).

| Acceptance criterion | Result |
|---|---|
| Compiles clean (both products) | ✅ |
| Launches a SwiftUI window + chat UI | ✅ (screenshot) |
| Generation works end-to-end | ✅ streamed from `llama3.1:8b`; Ollama `/api/ps` showed the model resident in VRAM |
| Sessions persist across quit+relaunch | ✅ session restored; SwiftData row count held at **1** (restore-then-mint — **no #1464 duplicate-blank-row regression**) |

## Findings (all minor / positive)

1. **Model-selection step past the "one call" headline** [API-ERGONOMICS, minor] — `quickStart()` registers backends but deliberately does **not** select a model (the documented "backend cliff"). For Ollama the host must fetch `result.bootstrap.endpointStore`, insert an `APIEndpointRecord(provider: .ollama, modelName:)`, then `setAvailableEndpoints` / `selectedEndpoint` / `await loadSelectedEndpoint()` — ~4 calls reaching through `result.bootstrap` and `result.viewModel`. Slightly at odds with the "one-call easy mode" framing, but **fully documented** in `docs/QUICKSTART.md` ("Seeding an Ollama endpoint") and `docs/SWIFTUI-MULTI-SESSION.md`. Not a blocker — working as designed.
2. **Discoverability is strong** [positive] — `kit.viewModel` / `kit.sessionManager` / `kit.bootstrap.modelContainer` all compiled first try with zero source-peeking; `SWIFTUI-MULTI-SESSION.md` is a solid consolidated source of truth.
3. **GUI automation is an environment limit, not an MK gap** [papercut] — a bare SwiftPM-executable `.app` doesn't raise/focus reliably for synthetic clicks; token streaming was proven via a headless `VerifyGen` target reusing the identical `InferenceService` path.

## Verdict

The drop-in `ChatView` + `quickStart()` SwiftUI happy path is **healthy and well-documented** on v0.50.0. The iter-1 coverage gap is closed; the only friction is the intentional, documented model-selection step. No follow-up code work indicated.
