# ManifoldKit Documentation

**Audience:** consumer
**Status:** living

The single, ordered way in. Read top-to-bottom for the guided path from "why
this exists" to "install → first token → add a capability → ship it", or jump
straight to the section you need. Every newcomer-facing doc is listed here; the
deep contributor/launch material is grouped separately at the bottom so it
doesn't clutter the path.

> New to ManifoldKit? The fastest start is **[Why ManifoldKit](WHY-MANIFOLDKIT.md)**
> → **[Quickstart](QUICKSTART.md)**. Everything else branches off those two.

---

## Start here — why ManifoldKit

| Doc | What it gives you |
|-----|-------------------|
| [**WHY-MANIFOLDKIT.md**](WHY-MANIFOLDKIT.md) | The honest "what it solves, why trust it, what it deliberately doesn't do" narrative, with every claim pointing at the source or test that backs it. Read this first. |
| [POSITIONING.md](POSITIONING.md) | The full category argument — "ManifoldKit vs. the field", the four pillars, and the standing list of what isn't done yet. |

## Getting started

The spine: **install → first token → multi-session UI.** Pick a branch only if
the default SwiftUI path isn't yours.

1. [**QUICKSTART.md**](QUICKSTART.md) — from an empty SwiftUI project to a working
   `ChatView` in under five minutes via `ManifoldKit.quickStart()`. Backend
   selection, companion packages, storage, and error handling.
2. [**SWIFTUI-MULTI-SESSION.md**](SWIFTUI-MULTI-SESSION.md) — the canonical
   end-to-end guide for a session sidebar, persisted chats, and relaunch restore.
   Go here once the single-session quickstart makes sense.

Branch points:

- [QUICKSTART-CLI.md](QUICKSTART-CLI.md) — building a CLI, server, or other
  non-SwiftUI consumer. Compile-tested `Package.swift` + `main.swift` for
  Foundation Models, local GGUF, and Ollama / OpenAI-compatible endpoints.
- [QUICKSTART-SERVER.md](QUICKSTART-SERVER.md) — running ManifoldKit as a
  standalone OpenAI-compatible HTTP server (`manifold-server`). Install via
  Homebrew, run, and point Cursor / Continue / any OpenAI SDK at `127.0.0.1:8080/v1`.
- [QUICKSTART-BRING-YOUR-OWN-UI.md](QUICKSTART-BRING-YOUR-OWN-UI.md) — the
  inference layer with your own SwiftUI surface (no `ChatView`). The canonical,
  single-source BYO-UI walkthrough.

> [!IMPORTANT]
> **The backend cliff — a *runtime* throw, not a compile error.** If nothing
> registers an inference backend (pre-iOS 26 / macOS 26, no cloud endpoint
> configured, no companion packages), `ManifoldKit.quickStart()` throws
> `ManifoldKitError.noBackendsRegistered` when you call it — it compiles fine,
> then fails at launch. For local inference add a companion package
> ([manifold-llama](https://github.com/ManifoldKit/manifold-llama) for GGUF,
> [manifold-mlx](https://github.com/ManifoldKit/manifold-mlx) for MLX) and pass its
> registrar to `quickStart(backends:)`. See
> [QUICKSTART.md → Customizing backends](QUICKSTART.md#customizing-backends).

## Add a capability

Already have chat working? Layer these on, in roughly increasing specialisation.

| Capability | Doc |
|------------|-----|
| **Tools / function calling** | [QUICKSTART-TOOLS.md](QUICKSTART-TOOLS.md) — `ToolRegistry`, the local-model tool ceiling, approval gates, streaming results. |
| **Tool calling on a local model** | [LOCAL-TOOL-CALLING.md](LOCAL-TOOL-CALLING.md) — the Llama/Qwen/Mistral recipe: rendering tools into the system prompt, the `<tool_call>{JSON}</tool_call>` envelope, GBNF constraint, and the silent-drop failure modes. |
| **Expose an App Intent to the model** | [QUICKSTART-APPINTENTS.md](QUICKSTART-APPINTENTS.md) |
| **RAG — answer from your documents** | [QUICKSTART-RAG.md](QUICKSTART-RAG.md) — ingestion, semantic + keyword retrieval, reranking, and inline citations. |
| **RAG tuning** | [RAG-TUNING.md](RAG-TUNING.md) — chunk size, reranker tradeoffs, citation surface. |
| **Voice (STT / TTS)** | [QUICKSTART-VOICE.md](QUICKSTART-VOICE.md) — usable standalone, not just in chat. |
| **On-device image generation** | [QUICKSTART-IMAGE-GEN.md](QUICKSTART-IMAGE-GEN.md) — FLUX.1 Schnell / SDXL Turbo, download → load → generate. The diffusion backends ship in the [manifold-mlx](https://github.com/ManifoldKit/manifold-mlx) companion package. |
| **Cloud video generation** | Moved to the [manifold-mlx](https://github.com/ManifoldKit/manifold-mlx) companion package docs (the `VideoGenerationBackend` protocol and persistence wiring stay in core). |
| **Model management UI** | [MODEL-MANAGEMENT.md](MODEL-MANAGEMENT.md) — browser, download, storage sheet. |
| **Model selection / load plans** | [QUICKSTART-MODEL-SELECTION.md](QUICKSTART-MODEL-SELECTION.md) — `ModelSelection` and `ModelLoadPlan`. |
| **Recipes (short patterns)** | [RECIPES.md](RECIPES.md) — tool loop, RAG, on-device pick, structured output. |
| **App eval goldens** | [APP-EVAL.md](APP-EVAL.md) — golden-scenario regression via `ManifoldAppEval`. |
| **Share Extension handoff** | [share-action-extension-recipe.md](share-action-extension-recipe.md) — ingest text/URLs from the system share sheet. |
| **Migrating from Foundation Models** | [MIGRATING-FROM-FOUNDATION-MODELS.md](MIGRATING-FROM-FOUNDATION-MODELS.md) — session / tools / structured-output map. |

## Reference

| Doc | Covers |
|-----|--------|
| [**MIGRATION-INDEX.md**](MIGRATION-INDEX.md) | **Every migration note, newest first, with the release that shipped it.** Start here when a version bump breaks your build — the individual notes below are the highlights, not the full set. |
| [MIGRATION-0.48.md](MIGRATION-0.48.md) | v0.48 packaging-release migration — retired traits, the manifold-mlx / manifold-llama companion packages, indexed by the literal error strings. **Shim sections are historical** — `ManifoldBackends` / `DefaultBackends` are gone; see [MIGRATION-shims-retired.md](MIGRATION-shims-retired.md). |
| [**MIGRATION-shims-retired.md**](MIGRATION-shims-retired.md) | **Current** import/registrar model after P7 removed `ManifoldBackends` / `DefaultBackends` / `ManifoldCloud`. Read this before trusting any 0.48 "still compiles" shim note. |
| [MIGRATION-api-demotions-0.71.md](MIGRATION-api-demotions-0.71.md) | Public→package demotions in the 0.71 train. |
| [FeatureMatrix.md](FeatureMatrix.md) | Remaining **SwiftPM traits only** (`Macros`, `Server`, WWDC stubs) — not the full product capability map. Most capabilities compile unconditionally or live in companion packages; see products in [AGENTS.md](../AGENTS.md) and [COMPANION-BACKENDS.md](COMPANION-BACKENDS.md). |
| [TRAIT-COSTS.md](TRAIT-COSTS.md) | Per-trait binary impact for the remaining opt-in traits (`Server`, `Macros`). Heavy ML checkouts are companion-optional since v0.48. |
| [COMPANION-BACKENDS.md](COMPANION-BACKENDS.md) | Building or consuming a companion backend package (manifold-mlx / manifold-llama). |
| [ANATOMY-OF-ONE-TURN.md](ANATOMY-OF-ONE-TURN.md) | File:line walk of one message turn — send → runtime → engine → backend → UI. |
| [MIGRATION-anylanguagemodel-retired.md](MIGRATION-anylanguagemodel-retired.md) | The AnyLanguageModel bridge was retired (#2435) — xAI, Groq, Mistral, OpenRouter (and Gemini via OpenRouter) now reach ManifoldKit via `APIProvider.custom` + `OpenAIBackend`. |
| [CLOUD-OAUTH.md](CLOUD-OAUTH.md) | OAuth flows for cloud providers. |
| [LOCAL-GGUF.md](LOCAL-GGUF.md) | Local model storage contract and discovery. |
| [LLAMA_CONTRACT.md](LLAMA_CONTRACT.md) | Tombstone — the llama.cpp C-API contract moved to [manifold-llama](https://github.com/ManifoldKit/manifold-llama). |
| [SOURCEKIT_DIAGNOSTICS.md](SOURCEKIT_DIAGNOSTICS.md) | Non-destructive investigation of stale SourceKit module errors. |

## Security & reliability

| Doc | Covers |
|-----|--------|
| [THREAT_MODEL.md](THREAT_MODEL.md) | The full threat model — TLS pinning, SSRF/DNS-rebind guards, Keychain, sanitisation. |
| [RELIABILITY.md](RELIABILITY.md) | The source-backed reliability contract and deferred items. |
| [FIPS.md](FIPS.md) | The answer to "are your cryptographic primitives FIPS 140-3 validated?" for regulated deployments. |

## Ship it

| Doc | Covers |
|-----|--------|
| [AppStoreSubmission.md](AppStoreSubmission.md) | App Store submission notes, including the lean core-only build (no companion packages). |

---

## Internal / contributor

Not part of the newcomer path — launch planning, scope decisions, QA machinery,
and forward-looking design notes. Most are also linked from
[CONTRIBUTING.md](../CONTRIBUTING.md).

| Doc | Covers |
|-----|--------|
| [SCOPE_DECISION.md](SCOPE_DECISION.md) | Scope rationale for what's in vs. out. |
| [QA-PRACTICES.md](QA-PRACTICES.md) | The four cross-cutting QA practices (DX walkthroughs, audit tests, the sabotage suite, cold-start gates). |
| [QA-EVALUATION-PROCESS.md](QA-EVALUATION-PROCESS.md) | How a release candidate is evaluated before it ships — the hand-run checks that sit outside `swift test`. |
| [UI-REFRESH-2026.md](UI-REFRESH-2026.md) / [UI-REFRESH-2026-PLAN.md](UI-REFRESH-2026-PLAN.md) | The 2026 UI refresh: the design rationale and the unit-by-unit delivery plan (issue #2307). Consumer-facing change inventory is in [MIGRATION-ui-refresh.md](MIGRATION-ui-refresh.md). |
| [wwdc-2026-trait-stubs.md](wwdc-2026-trait-stubs.md) | The pre-wired stub traits for whatever Apple ships next. |
| [plans/](plans) | In-flight release plans. |
