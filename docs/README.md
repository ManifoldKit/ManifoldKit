# ManifoldKit Documentation

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
   selection, trait profiles, storage, and error handling.
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
> **The trait cliff — a *runtime* throw, not a compile error.** If your build
> compiles in **zero** inference backends for the active trait / OS combination,
> `ManifoldKit.quickStart()` throws `ManifoldKitError.noBackendsRegistered` when
> you call it — it compiles fine, then fails at launch. The defaults
> (`MLX`, `Llama`, `HuggingFace`) always include a backend, so you only hit this
> with a custom `traits:` array that selects none, or `--disable-default-traits`.
> Pick at least one of `MLX`, `Llama`, `CloudSaaS`, `Ollama`, or `FoundationOnly`.
> See [QUICKSTART.md → Customizing backends](QUICKSTART.md#customizing-backends)
> for the per-profile trait sets.

## Add a capability

Already have chat working? Layer these on, in roughly increasing specialisation.

| Capability | Doc |
|------------|-----|
| **Tools / function calling** | [QUICKSTART-TOOLS.md](QUICKSTART-TOOLS.md) — `ToolRegistry`, the local-model tool ceiling, approval gates, streaming results. |
| **Expose an App Intent to the model** | [QUICKSTART-APPINTENTS.md](QUICKSTART-APPINTENTS.md) |
| **RAG — answer from your documents** | [QUICKSTART-RAG.md](QUICKSTART-RAG.md) — ingestion, semantic + keyword retrieval, reranking, and inline citations. |
| **Voice (STT / TTS)** | [QUICKSTART-VOICE.md](QUICKSTART-VOICE.md) — usable standalone, not just in chat. |
| **On-device image generation** | [QUICKSTART-IMAGE-GEN.md](QUICKSTART-IMAGE-GEN.md) — FLUX.1 Schnell / SDXL Turbo. |
| **Cloud video generation** | [QUICKSTART-VIDEO-GEN.md](QUICKSTART-VIDEO-GEN.md) |
| **Share Extension handoff** | [share-action-extension-recipe.md](share-action-extension-recipe.md) — ingest text/URLs from the system share sheet. |

## Reference

| Doc | Covers |
|-----|--------|
| [MIGRATION-0.48.md](MIGRATION-0.48.md) | v0.48 packaging-release migration — retired traits, the manifold-mlx / manifold-llama companion packages, indexed by the literal error strings. |
| [FeatureMatrix.md](FeatureMatrix.md) | The full trait → backend → capability table (generated from source). |
| [TRAIT-COSTS.md](TRAIT-COSTS.md) | Per-trait binary impact, build-time cost, and dependency weight (generated from measured data). Explains why the checkout is large regardless of trait set. |
| [PROVIDER-BRIDGE.md](PROVIDER-BRIDGE.md) | The AnyLanguageModel bridge — Gemini, xAI, Groq, Mistral, OpenRouter, and OpenAI/Anthropic-compatible endpoints. |
| [CLOUD-OAUTH.md](CLOUD-OAUTH.md) | OAuth flows for cloud providers. |
| [LOCAL-GGUF.md](LOCAL-GGUF.md) | Local model storage contract and discovery. |
| [llama-runtime.md](llama-runtime.md) | The llama.cpp runtime surface. |
| [LLAMA_CONTRACT.md](LLAMA_CONTRACT.md) | The full llama.cpp C-API contract ManifoldLlama upholds. |
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
| [AppStoreSubmission.md](AppStoreSubmission.md) | App Store submission notes, including the lean `FoundationOnly` build. |

---

## Internal / contributor

Not part of the newcomer path — launch planning, scope decisions, QA machinery,
and forward-looking design notes. Most are also linked from
[CONTRIBUTING.md](../CONTRIBUTING.md).

| Doc | Covers |
|-----|--------|
| [LAUNCH-BRIEF.md](LAUNCH-BRIEF.md) | Distribution-readiness audit, imagery briefs, draft announcement, post-WWDC sequencing. |
| [SCOPE_DECISION.md](SCOPE_DECISION.md) | Scope rationale for what's in vs. out. |
| [QA-PRACTICES.md](QA-PRACTICES.md) | The four cross-cutting QA practices (DX walkthroughs, audit tests, the sabotage suite, cold-start gates). |
| [wwdc-2026-trait-stubs.md](wwdc-2026-trait-stubs.md) | The pre-wired stub traits for whatever Apple ships next. |
| [voice-realtime-agent-design.md](voice-realtime-agent-design.md) | Forward-looking design note for a realtime voice agent. |
| [plans/](plans) | In-flight release plans. |
