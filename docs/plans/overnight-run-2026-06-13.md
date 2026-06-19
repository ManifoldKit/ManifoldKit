# Overnight run — 2026-06-13 → 06-14

**Status:** 🔶 DRAFT — assembled from a grounded recon sweep (this session). Every workstream below was verified against `origin/main` / the actual source, not just issue text. Where an issue's headline turned out to be marginal or a wontfix, that is called out so no worker wastes a night re-deriving a rejected design.

**Premise:** tokens are effectively unlimited tonight; bias to **breadth + verified-real work**. A 131-agent correctness/security audit already ran 2026-06-13 (shipped #1790–#1794) and drained that well — so this run is **features + the one open correctness bug + small verified perf**, not another audit.

---

## 0. Recon meta-finding (why the shape is what it is)

Every "find hidden problems" axis came up **clean** — which is a signal about codebase health, not a search failure:

| Hunt axis | Result | Evidence |
|---|---|---|
| Correctness / security | drained | today's 131-agent audit shipped #1790–#1794 |
| #1796A perf backlog | **1 real fix**, rest marginal | see §W1 |
| #1682 SwiftData | **top item is a wontfix** | `SwiftDataPersistenceProvider.swift:402-409` + `SwiftDataTransactionalMutationTests` |
| Companion boundary | clean split, no dup | shared `ManifoldTestSupport`/`ManifoldBackendTestKit` ARE reused; GGUF/tokenizer "overlap" is a false positive |
| Build time | clean | **37.81s** full build, 645 files / 1454 units; only 2 SwiftUI bodies >100ms (131ms, 100ms) |

→ The substance is in **feature/bug** work, not hunting. CI's ~8-min cold floor is dependency-compile (llama.cpp xcframework) + test build/exec — **not** first-party type-checking — so a source-level build audit can't move it.

---

## 1. Gate (sequential, owner = orchestrator)

Workers do NOT start until this clears.

1. **#1799** (`feat/deep-backend-routing-799`, per-request Deep-backend routing seam) — wait for `test` + `lint` green → squash-merge.
2. Release Please refreshes **#1779** (`chore(main): release 0.49.0`). Rewrite its CHANGELOG to **Prisma Highlights** format (hook-gated; `gh api … merge` bypass), then merge → **MK @ 0.49.0**.
3. Companion pin coordination: manifold-mlx / manifold-llama pin `ManifoldKit` `.upToNextMinor(from: 0.48.0)` — a 0.49 bump stays in-range, no companion change required tonight. Re-confirm after tag.

---

## 2. Per-item pipeline: implement → independent review+fix → merge-on-green

Every workstream is a **two-stage pipeline**, not a single worker:

1. **Implementer** (own worktree off `origin/main`@0.49, named branch): build the change + tests + docs, run full `scripts/test.sh --profile local` gate, open the PR. Never touch `main`. Never stage `Package.resolved`.
2. **Reviewer-fixer** (a *different* worker — independent perspective): run `/code-review` on the PR diff, apply the fixes to the branch, re-run the gate, then **merge when green** (`--admin` squash; `enforce_admins` is off). Reviewer must reproduce/verify, not rubber-stamp — for W2 that means re-running the determinism test red→green.

Wait for CI green on each PR before the reviewer merges. Serialize merges (one at a time) so a signature-breaking change doesn't strand the others — rebase the rest after each merge.

## 2b. Workstreams (parallel; **serialize pushes + merges** — hook collisions, interleaved-merge breakage)

### W1 — perf: streaming + preflight hot paths  · MK · `perf:`
- **RepetitionDetector tail-bounding** (the one verified high-value item). `looksLikeLooping` (`RepetitionDetector.swift:17`) does `Array(trimmed)` over the *entire* accumulated text on every token via `shouldStopForLoop(content: accumulator.visibleText)`, but only inspects the tail (≤360 chars 3x / ≤400 chars 2x). Fix: operate on `text.suffix(500)`. Genuine per-token O(n²)→O(n). Add a test asserting detection still fires on a tail-repeat in a long prefix + a perf guard.
- **Fold-in (lower value, same PR):** `GenerationPreflightTrimmer.format()` assemble-once on the cold trim path; `PromptTemplate` `[String].joined()` instead of `+=` (note: Swift `+=` is amortized O(1) — frame as readability, not a hot fix); the 2 build-time SwiftUI bodies (`GenerationSettingsView.swift:34`, `LinkPreview.swift:113`) — split sub-expressions into typed `let`s to drop under the 100ms type-check limit.
- Closes the actioned half of **#1796** §A; leave the contested §B items as a wontfix note.

### W2 — fix(llama): KV-reuse greedy determinism  · **manifold-llama** · `fix:`
- **#1677.** KV-prefix-reuse is unconditionally on; the −2 re-decode batch can flip argmax on near-tied logits for non-Qwen archs (Metal parallel-reduction differs by batch shape). Fix: enforce identical batch shape on the KV-reuse re-decode. Flip the `XCTExpectFailure` in the llama KV-persistence suite (the issue's `Tests/ManifoldBackendsTests/...` path is **stale** — the suite moved to manifold-llama in the v0.48 split; locate it there).
- ⚠️ Subtle / hardware-coupled. Worker must reproduce the non-determinism first (red test), then fix, then green — no blind edit.

### W3 — ci/test hygiene  · MK · `ci:` / `test:`
- **#1709** triage: nightly `slow` job failed (run 27119252332). `gh run view --log > /tmp/x` once, grep locally (don't re-run). Fix or, if flake/stale, document + close.
- **#1706** verify-and-close: `TrafficBoundaryAuditTest` per-PR move — plan doc says shipped via #1772. Confirm the `RUN_SLOW_TESTS=1` guard is actually gone + it's in the per-PR filter, then close. If NOT actually shipped, do the move.

### W4 — feat: recommender wiring (v0.49 Workstream A)  · MK · `feat:`
- Wire `ModelFitScorer` into `quickStart()` seed (`Sources/ManifoldKit/QuickStartSeed.swift` — today hardcodes Qwen3-0.6B for every device) + surface a recommendation in the bundled model-management UI (`ModelManagementViewModel`). Mostly expose-and-compose — primitives shipped in #1783. Tests + DocC in the same PR.
- This is the headline the open 0.49.0 release is *meant* to deliver as an experience, not just a callable library.

### W5 — feat: image-gen live preview event  · MK + **manifold-mlx** · `feat:`
- **#1747.** Additive `ImageGenerationEvent.preview` + `ImageGenerationConfig.previewStride` (opt-in, throttled) in MK core (`Sources/ManifoldModelCatalog/ImageGenerationEvent.swift`) + runtime translation. Emit side (VAE-decode throttled latents) ships in manifold-mlx's `MLXDiffusionBackend` / `FluxDiffusionBackend`.
- Decide payload (URL vs in-memory buffer) per the issue's design questions — lean in-memory throttled to avoid per-tick disk re-encode.
- Cross-repo: MK contract PR first (so manifold-mlx can pin it), emit PR second.

### W6 — feat: RAG demo wiring  · MK · `feat:` / `test:`
- **#1575.** Wire real `nomic-embed-text` (on disk) RAG + 3–5 sample Markdown docs under `Sources/ManifoldTestSupport/Fixtures/` into the Glass Box demo bootstrap; assert ≥1 `Citation` structurally on an assistant message; ensure pre-turn compression fires against the real context window. Local-only, fully testable.

### W7 — docs/chore: tracker truth-up  · MK · `docs:` / `chore:`
- **#1682**: annotate the `transaction {}` item as a documented wontfix (cite the defending comment + test); record that `#Unique` is CloudKit-blocked; the real remaining work is the **post-WWDC-2026 SwiftData API re-diff** (now possible — keynote dropped) + a benchmark-driven `#Index` decision (run `LargeSessionListPerformanceTests`, only add indices if latency shows). If the benchmark warrants `#Index`, split a follow-up `perf:` PR.
- **Companion boundary**: short "clean — no action" writeup (shared test kits reused, no dup) folded into the target-architecture or a brief note; do NOT open a new issue (CLAUDE.md hygiene).

---

### W8 — feat(fuzz): wire the two disabled detectors  · MK · `feat:`
- Both `MemoryGrowthDetector` (growth-budget branch, `:50`) and `ContextExhaustionSilentDetector` (`:31`) are stubbed on the **same** missing primitive: no token/memory budget on `ConfigSnapshot`/`PromptSnapshot`/`ModelSnapshot`. Add the snapshot fields, enable both gated branches (`promptTokens < contextLimit/2` filter; declared-budget vs `peakBytes`), add detector tests. One PR — completes the fuzz harness's two silent-failure detectors.

### W9 — fix(ollama): surface `.loading` phase during model-load stall  · MK · `fix:`
- **#189** (TODO live at `OllamaBackend.swift:632`). Pre-first-token stall still reports `.streaming`. Add a monitoring task that detects the stall window and sets `GenerationStream` phase `.loading`. Concurrency-sensitive (Swift 6: no `Task.detached` in `@MainActor`; monitor hops off-actor in the callee). Test with a stubbed slow-first-byte `MockURLProtocol` (UUID hostname).

### W10 — ci(scenarios): nightly live-backend Glass Box E2E  · MK · `ci:`/`test:`
- **#1576.** Add `test_allRegisteredScenarios_passInLiveMode` (parallel to the existing scripted gate) guarded by `--traits Ollama`; assert only the structural `[ConversationEventKind]` subsequence. Add a nightly CI job (distinct failure notification from the per-PR gate so a flaky live model doesn't block PRs). Ollama target.

### W11 — docs(voice): scope a ManifoldVoice realtime surface  · MK · `docs:` (design-note only)
- **#1415.** Audit the `Voice` trait current state; decide transport(s) (OpenAI Realtime / Apple Speech local-first / deferred Anthropic); decide `VoiceBackend` protocol vs riding existing backends (likely separate — full-duplex lifecycle); write a one-page `docs/` design note + v0.1 milestone. **No implementation.** Either file concrete impl issues from the note or apply the `parking-lot` label with a documented why. Real ecosystem gap (no production Swift voice-agent SDK as of mid-2026).

### W12 — test(mlx): cover FluxDiffusionBackend + TransformersTokenizerLoader  · manifold-mlx · `test:`
- Verified gaps: `FluxDiffusionBackend.swift` (entire Flux image-gen backend, **0 test refs**) and `TransformersTokenizerLoader.swift` (0 refs). `MLXDiffusionBackendTests` covers only `MLXDiffusionBackend`.
- Add unit tests for the deterministic, non-Metal-bound surface: config/preset resolution, latent-shape/scheduler math, error paths (bad tokenizer dir, missing files). Gate any GPU-bound assertions behind the integration tier (`MLXMetalGuard` pattern). Coordinates with W5 — Flux is the preview-event emit path.

### W14 — feat(foundation): adopt StructuredHistoryReceiver  · MK · `feat:` (0.50 multimodal prep, buildable NOW)
- Per the #1710 Phase-0 resolution (comment 4698307321): the CGImage Attachment API lands at **27.0** (not 26.4), and the real MK work is that `FoundationBackend` is **String-only today** — it must adopt `StructuredHistoryReceiver` (already in `ManifoldContract/BackendOptInProtocols.swift:80`; Claude/OpenAI/mock already conform) before image attachments are possible.
- This adoption is **buildable now** — MK-side protocol, no 27.0 SDK. Conform `FoundationBackend` to `StructuredHistoryReceiver`, read unflattened `parts` via `GenerationHistoryInstaller`, gate the eventual CGImage attachment behind a runtime-conditional flag (no-op until 27.0). Reuse `GenerationQueueStructuredHistoryTests` + the `BackendContractMixins` structured-history conformance.
- De-risks the 0.50 multimodal headline; leaves only the 27.0-runtime-gated attachment flip for later. **Stays compile-clean on the current toolchain.**

### W13 — docs: DocC review + fix  · all 3 repos · `docs:`
- **Review by compiler, not eyeball** (4823 public decls in MK). Build docs (`swift package generate-documentation` / docc plugin) per module; collect warnings: missing abstracts on public symbols, broken `` `` symbol links, unresolved `<doc:>` references, empty curation. Fix them.
- **Add the two missing companion landing pages:** `manifold-mlx/Sources/ManifoldMLX/ManifoldMLX.docc` and `manifold-llama/Sources/ManifoldLlama/ManifoldLlama.docc` — neither product currently ships any DocC catalog. Minimal: a top-level article + symbol curation + a getting-started ("add the package, pass the registrar") snippet matching the README.
- Respect the `readme-snippets` CI constraint (iOS-only snippets need `swift,no-build`; DocC articles are compiled).

## 3. Dispatch order & dependencies

- **Independent implementers, dispatch together after gate:** W1, W2, W3, W4, W6, W7, W8, W9, W10, W11.
- **W5** is cross-repo (MK contract → manifold-mlx emit) — sequence its two PRs.
- Each implementer PR → hand to a **different reviewer-fixer** (§2) → merge-on-green.
- **Serialize pushes AND merges** (pre-push hook collisions; interleaved-merge main breakage). Merge one PR at a time, rebase the rest. Merge signature/API-breaking PRs first (W4/W5/W8 touch public types).
- **One feature = one PR** (CLAUDE.md). Each ≤ ~40 changed files / ~800 net lines or it splits.
- Tests + docs ship *in* each feature PR, never as follow-ups. No new tracking issues (CLAUDE.md hygiene) — reference existing ones.

## 4. Explicitly OUT (don't let a worker wander in)
- #1682 `transaction {}` rewrite (wontfix), `#Unique` (CloudKit-blocked).
- A fresh correctness/security audit (drained today).
- Companion-boundary refactor PR (split is clean).
- **#1710 attachment flip** — the CGImage `Attachment` API is **27.0** (Phase-0 resolved, comment 4698307321); the runtime-conditional flag flip is 27.0-runtime-gated. But the *prerequisite* (`StructuredHistoryReceiver` adoption) is buildable now → pulled forward as **W14**.
- **#1577 `LanguageModelExecutor`** — the real extensibility surface is `FoundationModels.LanguageModelExecutor` (no separate ManifoldSystemAI framework needed; Phase-0 resolved, comment 4698308131); 0 refs in Sources today, 27.0/entitlement-gated. The loud flag on the tool-loop fork is the only now-safe slice and is not worth a standalone PR tonight.
- #1605 — WWDC-gated umbrella phases; re-assess separately.
- `@_exported` shim retirement (#P7) — needs ≥2-minor window.

## 5. Workstream roster (11)
| W | Type | Repo | Source |
|---|---|---|---|
| W1 | perf | MK | #1796A (RepetitionDetector + fold-ins) |
| W2 | fix | manifold-llama | #1677 KV determinism |
| W3 | ci/test | MK | #1709 triage + #1706 close |
| W4 | feat | MK | v0.49-A recommender wiring |
| W5 | feat | MK + manifold-mlx | #1747 preview event |
| W6 | feat/test | MK | #1575 RAG demo |
| W7 | docs/chore | MK | #1682/#1706 truth-up + companion note |
| W8 | feat | MK | fuzz detector stubs (2 detectors) |
| W9 | fix | MK | #189 Ollama `.loading` phase |
| W10 | ci/test | MK | #1576 nightly live Glass Box E2E |
| W11 | docs | MK | #1415 voice scoping note |
| W12 | test | manifold-mlx | FluxDiffusionBackend + TransformersTokenizerLoader coverage |
| W13 | docs | all 3 | DocC review+fix + 2 companion landing pages |
| W14 | feat | MK | FoundationBackend adopts StructuredHistoryReceiver (0.50 multimodal prep, buildable now) |

Each = implement → independent review+fix → merge-on-green (§2).

## 6. Notes for maintainer
- 11 workstreams, ~12 PRs across 3 repos. All verified-real and independent. This is a *broad* night — if review bandwidth is the bottleneck, the natural drop order is W11 (design note, lowest urgency) → W10 (CI nicety) → W6.
- Highest-risk: W2 (Metal/llama determinism), W9 (Swift 6 actor-hopping monitor). Both need reproduce-first discipline.
- Headline: W4 (what 0.49.0 is meant to deliver as an experience).
