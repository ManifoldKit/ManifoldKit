# Overnight run — 2026-06-14 (evening)

**Orchestrator:** Claude (main loop). **MK base:** `origin/main` @ ab4671a8 (0.51.0 released). **manifold-llama base:** `origin/main` @ 38d7117.

## Scope (maintainer-approved 2026-06-14 evening)
Two parallel lanes — recommended scope:
- **Lane A (MK):** Reusable model-selection train, remaining units **PR 2 → PR 3** (PR 0 #1866 + PR 1 #1864 merged today). Plan: `reusable-model-selection-surfaces.md`.
- **Lane B (manifold-llama):** Grammar conformance suite, lands skipping-empty. Plan: `model-family-grammar-conformance-suite.md`. Fully parallel (separate repo, zero collision).

## Operating rules
- **Versioning OFF-LIMITS.** Land on `main`; never touch release PRs / CHANGELOG / tags / companion pins. Release-Please accumulates; maintainer cuts. manifold-llama has no changelog-lint — leave CHANGELOG to maintainer.
- Worktree-isolated workers off `origin/main`; named branch; unique `TMPDIR` per concurrent gate; **never stage `Package.resolved`**.
- **CI is the authoritative gate. Orchestrator owns CI-watch + merge + adversarial diff review** (subagent gate-wait failure mode: reviewers background the ~15min gate and return early). Workers: implement → `swift build --build-tests` compile-check → **DRAFT PR** only.
- PR 2 is **signature-breaking** → `feat!:` + `BREAKING CHANGE:` footer + api-break-allowlist entry (NO `#` comments in the allowlist). Merges first; PR 3 rebases.
- Serialize merges within a repo; rebase the rest. Orchestrator sanity-checks each diff before merge (CI-green is necessary, not sufficient).

## Lane A units (sequenced)
| Unit | Summary | Break? | Status |
|------|---------|--------|--------|
| PR 2 | Headless `ModelSelection` in ManifoldInference + `#1312` synchronous dual-write collapse; hoist `ModelSelectionSortOrder`/`sortModels()`; grouping seam; `protocol ModelSelecting`; new `docs/QUICKSTART-MODEL-SELECTION.md` registered in `extract-snippets.sh` | feat! | **DRAFT #1873**, reviewed+fixed, rebased; awaiting maintainer ready+merge |
| PR 3 | Promote `ModelSelectionTabView` → public `ModelPicker` thin sample; re-express `ModelManagementSheet`; fold `#1298` attachImage + `#1300` togglePin; snippet-gate fix (add ManifoldUIModelManagement to extract-snippets-test scaffold) | feat | HELD until PR 2 merges |

Required characterization tests for PR 2 (per plan §Validation): two-surface topology (no progress leak), synchronous endpoint-clear, public-setter still syncs, headless latest-wins. Keep green: LoadDispatchCoordinationTests, InterleavingTests, CoordinatorClosureIsolationTests.

## Lane B unit
| Unit | Summary | Status |
|------|---------|--------|
| Grammar conformance | `LlamaGrammarConformanceTests` parametrized over family table; C1–C5 battery; Gemma carve-out assertion; Qwen thinking-gate; `GrammarFixtures` helper; lands skipping-empty | dispatched |

## Lane C/D — tool-call robustness backlog (dispatched after "keep working through issues")
| Lane | Issue(s) | Summary | Break? | Status |
|------|----------|---------|--------|--------|
| C | #1856 | Auto-inject `ToolSystemPromptBuilder.preferTools` in `GenerationQueue` when `supportsToolCalling && tools nonempty` and template renders no native tool block (no-op for `.gemma4`) | feat | **PR #1874**, reviewed APPROVE+ready, CI running. Found broader bug: `GenerationPreflightTrimmer` (local path) never forwarded tools to `format` — fixed both paths via shared `toolAugmentedSystemPrompt` + new `PromptTemplate.rendersToolsNatively` |
| D | #1857 + #1858 | Tool-call parse-failure diagnostic + opt-in truncated-block surfacing. Adds `GenerationEvent` case(s) — **freeze-aware** (pre-1.0 vocab completion): update freeze doc + ~30 switch sites + `GenerationEventClosedAuditTest` + sabotage + allowlist; `feat!:` | feat! | dispatched |

Lanes C/D are file-disjoint (C: GenerationQueue/PromptTemplate/ToolSystemPromptBuilder; D: ToolCallTransform/GenerationEvent) → parallel-safe; serialize merges. D is signature-breaking → if it lands near PR 2 (#1873), merge the breaking one first and rebase the other.

## Merge record (all on `main`, rolls into next Release-Please; versioning untouched)
| PR | Unit | Commit | Notes |
|----|------|--------|-------|
| #1873 | A — headless ModelSelection + #1312 collapse (`feat!`) | 635f44dd | orchestrator caught+fixed supersession stuck-spinner; sabotage-verified; known-flake re-run |
| #1874 | C — #1856 auto-inject tool system prompt (`feat`) | ff8b42d6 | worker found broader bug (GenerationPreflightTrimmer dropped tools on local path); both paths fixed |
| #1875 | D — #1857/#1858 tool-call diagnostics (`feat(contract)!`) | 578a892e | freeze-aware GenerationEvent additions; fixed bad title `feat!(contract)`→`feat(contract)!` + rebased allowlist conflict |

| #1877 | PR 3 — public ModelPicker over ModelSelection + #1298/#1300 (`feat`) | 502f416a | groupModels hoisted to static (shared impl); snippet-gate scaffold +ManifoldUIModelManagement; digester clean (additive) |

**RUN COMPLETE 2026-06-15.** Issues resolved tonight: **#1298, #1300, #1312, #1856, #1857, #1858** (6). Reusable-model-selection train PR 0→3 fully landed (PR 0 #1866 + PR 1 #1864 were earlier today; PR 2 #1873 + PR 3 #1877 tonight). Tool-call robustness cluster #1856/#1857/#1858 landed. Lane B (grammar suite) was a verified no-op (manifold-llama #11). All on `main`; versioning untouched for Release-Please (maintainer cuts).

### Left for maintainer
- **Versioning/release:** Release-Please will roll #1873/#1874/#1875/#1877 into the next minor (two `feat!`/`feat(contract)!` → still MINOR pre-1.0). Cut when ready; rewrite CHANGELOG to Highlights; bump companion pins after tag.
- **Remaining autonomous-fit backlog:** #1842 (MCPHost HTTP/SSE transport), #1834 (Contract API hardening deferred items).
- **NOT autonomous:** P4b/P4c media-generify + audio TTS (lockstep MK+manifold-mlx release); #1811 Jinja impl (daytime); #1710/#1577 (SDK-gated); #1641 imagery (design).

## Run log
- 2026-06-14 evening — run started; Lane A PR 2 + Lane B dispatched as worktree-isolated background workers. PR 3 held on PR 2 merge.
- 2026-06-15 — Lanes A/C/D all MERGED (see merge record). Standing merge authority granted for the run. PR 3 dispatched off post-PR2 main; still implementing.
- 2026-06-14 evening — **Lane B NO-OP: already shipped.** The grammar conformance suite is already on manifold-llama `main` (PR #11, merged 08:07 UTC today) incl. the #1595 thinking-grammar phase-gate file. Worker verified vs spec, cleaned up its throwaway worktree (nothing pushed). Stale spec deltas the merged suite already handles: (1) no `ToolCallMarker.Dialect` enum — Llama uses `LlamaToolMarkers.markers()` delimiter pairs; (2) Gemma does NOT throw on a grammar — `LlamaGenerationDriver.run` applies the sampler whenever `config.grammar != nil`; carve-out asserts the capability flag, not a throw (manifold-mlx#13's throw doesn't apply here); (3) `findGGUFModel(nameContains:)` falls back to smallest model on no-match — suite defeats it by requiring the path to contain the fragment; (4) thinking detection uses `manifest?.supportsThinking` not `capabilities.supportsThinking`; (5) sequential-generate race needs drain-then-poll on `isGenerating`. **No action.**
