# Overnight run — 2026-06-14 (kickoff 02:00 AEST)

**Status:** ✅ **COMPLETE (2026-06-14 ~16:48 UTC / 02:48 AEST).** See the Outcome record at the bottom. Supersedes `overnight-run-2026-06-13.md` (that plan's workstreams W1/W3/W4/W7/W8/W14 all merged this afternoon; 0.49.0 + 0.49.1 shipped). This is a fresh plan grounded against `origin/main` and live PR/issue state at 2026-06-13 23:xx.

**Premise:** tokens effectively unlimited; bias to breadth + verified-real work. Today's 131-agent correctness/security audit (#1790–#1794) drained the hunt well — so this run is **in-flight cleanup → fresh features → one companion bug**, not another audit.

**Maintainer decisions (2026-06-13):** broad night (cleanup + fresh features) · #1811 Jinja = **spike-first, no merge** · #1677 companion work **included** (manifold-llama).

**⚠️ Versioning is OFF-LIMITS this run.** All merged work targets **0.50** by landing on `main` — Release-Please accumulates it into the open 0.50.0 PR automatically. The run must **NOT** merge/cut #1806, rewrite its CHANGELOG, tag a release, or bump companion pins. The maintainer manages versioning + the release cut **tomorrow (daytime, manual)**. Leave #1806 untouched and refreshing.

---

## Phase 0 — Land the in-flight PRs into `main` (sequential, owner = orchestrator)

Four PRs are already open from the afternoon run; two are RED. Merge them into `main` (they roll into 0.50 via Release-Please) before dispatching fresh workers so a signature-breaking change doesn't strand new work. **Do NOT cut the release** — see the versioning note above.

1. **#1814** RAG real retrieval (#1575) — ❌ `Verify Package.resolved is up to date`. A dep was pulled into resolution. Fix: `swift package resolve && git diff Package.resolved` on the branch, commit the resolved file (this is the legitimate exception to "never stage Package.resolved" — the gate *requires* it current). Re-run `scripts/test.sh --profile local`, push, merge on green.
2. **#1815** image-gen preview event (#1747) — ❌ API-break gate. Adding `case preview(...)` to the public `ImageGenerationEvent` enum is source-breaking for exhaustive switches (your known gotcha — enum-case adds need `feat!:` or the gate rejects). Resolve per the gate's contract: confirm whether the digester flags it as a tolerable additive break for a MINOR, or whether the case must ride a `feat!:`. Do NOT silence the gate — adjust the change/commit type to match policy. Re-gate, merge on green.
3. **#1816** DocC symbol-link fixes — verify green, merge. Cheap, no-build-risk.
4. **#1817** nightly Glass Box live gate (#1576) — verify green, merge. Confirm the nightly job is `workflow_dispatch`/schedule-gated (distinct failure notification from per-PR) so a flaky live model can't block PRs.
5. **#1806** Release-Please **0.50.0** — **LEAVE UNTOUCHED.** Do not merge, do not rewrite its CHANGELOG, do not tag. Each merge above lets Release-Please refresh it; the maintainer cuts the release manually tomorrow. Companion pin bumps (`.upToNextMinor(from: 0.50.0)`) also wait for tomorrow's tag — **not this run**.

**Serialize merges** (one at a time, rebase the rest). Merge #1815 first if it lands as a public-type change (signature-breaking), then the rest. All merges land on `main`; the version bump is the maintainer's, tomorrow.

---

## Phase 1 — Fresh features (per-item: implement → independent review+fix → merge-on-green)

Two-stage pipeline per workstream (your standard): implementer in own worktree off `origin/main` (post Phase-0 merges), named branch, full `scripts/test.sh --profile local` gate, open PR → a **different** reviewer-fixer runs `/code-review`, applies fixes, re-gates, merges on green. Merging lands the feature on `main` → rolls into 0.50 via Release-Please; **do not bump the version or touch #1806**. Never stage `Package.resolved` (except the Phase-0 #1814 case). Serialize pushes + merges.

### W-A — feat(rag): NLEmbedding on-device EmbeddingBackend default · MK · `feat:`
- **#1812 Stage 1.** `EmbeddingBackend` is fully wired (RAGConfiguration → RAGService → FlatFileVectorStore) but every conformance is a test mock — a host can't embed without bringing its own. Add an `NLEmbedding`-backed conformance (NaturalLanguage, zero download, no heavy dep) as the **default** so RAG works out of the box.
- **Verify first:** confirm `NLEmbedding` dimensionality/quality is adequate for the existing `FlatFileVectorStore` retrieval path before committing the surface.
- **Wiring:** surface through `quickStart()`/bootstrap so a host gets working RAG with zero injected embedder. Preserve the host-injected-backend override path.
- **Tests (in the PR):** integration test embed → store → retrieve with a relevance sanity assertion + sabotage check (force a mismatched query, assert retrieval drops). Don't mock persistence — in-memory store.
- **Pairs with #1814** (RAG retrieval, merging in Phase 0) — this is what makes that demo work without a host embedder.
- **Stage 2 (MLXEmbedders in manifold-mlx) is explicitly OUT** — tracked on #1812, not blocking; cross-repo + Metal-in-sim gating. Note it in the issue, don't open a new one.

### W-B — spike(inference): real GGUF Jinja chat-template rendering · MK · **spike doc only, NO merge of impl**
- **#1811.** Today templates are approximated by the hardcoded `PromptTemplate` enum (`ManifoldHardware/PromptTemplate.swift`); GGUF Jinja templates are only pattern-matched for detection, not rendered. Silent-correctness gap.
- **Spike deliverables (land a doc/writeup, defer the impl PR):**
  1. **Verify it's a real consumer problem** — find a model in actual use whose embedded Jinja template does NOT map cleanly to an enum case, and show the enum mis-renders it.
  2. Render that template via `swift-jinja` (swift-transformers 1.0 module) and **diff against the current enum output**.
  3. **Placement decision:** core (`ManifoldContract`/`ManifoldHardware`, companions depend up) vs the companions directly (MLX/Llama are the only consumers; cloud doesn't need it). Document the dependency-edge rationale.
  4. Note the resolve-check / `Package.resolved` / `.build/checkouts` cache-key impact of a new external dep (known local-gate blind spot) so the eventual impl PR budgets for it.
- **Output:** `docs/plans/1811-jinja-rendering-spike.md` with the diff evidence + placement recommendation + a concrete impl-PR plan. **Do not adopt the dep on a branch tonight** — multi-repo dep snags want an interactive daytime session.

---

## Phase 2 — Companion bug (manifold-llama)

### W-C — fix(llama): KV-reuse greedy determinism across non-Qwen archs · **manifold-llama** · `fix:`
- **#1677.** KV-prefix-reuse is unconditionally on; the −2 re-decode batch can flip argmax on near-tied logits for non-Qwen archs (Metal parallel-reduction differs by batch shape). Fix: enforce identical batch shape on the KV-reuse re-decode.
- ⚠️ **Reproduce-first, no blind edit.** Worker must produce the non-determinism as a RED test first, then fix, then green. The KV-persistence suite moved to manifold-llama in the v0.48 split — the issue's `Tests/ManifoldBackendsTests/...` path is **stale**; locate the suite in the companion repo and flip its `XCTExpectFailure`.
- Hardware-coupled; this is the highest-risk workstream. Own worktree off the companion's `origin/main`, named branch, companion gate, PR. Companion has no changelog-lint — rewrite CHANGELOG by hand on release.

---

## Dispatch order & dependencies
- **Phase 0 is the gate.** No fresh worker starts until #1814/#1815/#1816/#1817 are green-merged into `main` (so worktrees branch off current `main`, not a stale base). The release cut (#1806) is NOT a gate item — it stays open for the maintainer tomorrow.
- **Phase 1 + 2 dispatch together** after the gate: W-A (MK feat), W-B (MK spike — independent), W-C (manifold-llama fix — different repo, fully parallel).
- Each impl PR → **different** reviewer-fixer → merge-on-green. Serialize pushes + merges within a repo; cross-repo (W-C) is independent.
- One feature = one PR. Tests + docs ship IN the PR. No new tracking issues (CLAUDE.md hygiene) — reference #1812/#1811/#1677.

## Explicitly OUT (don't let a worker wander in)
- **#1811 full impl / dep adoption** — spike only tonight (maintainer decision).
- **#1812 Stage 2** MLXEmbedders — companion, demand-gated; tracked not built.
- **#1641** positioning imagery — design/asset work, poor autonomous fit; daytime.
- **#1710 / #1577** — SDK/entitlement-gated (Phase-0 probes confirmed no FoundationModels image/executor surface in shipping SDK). Re-probe on next module bump.
- **#1682** — `transaction {}` rewrite (wontfix), `#Unique` (CloudKit-blocked).
- **#1605** — WWDC-gated umbrella phases; re-assess separately.
- **`@_exported` shim retirement** — needs ≥2-minor window.
- A fresh correctness/security audit (drained today, #1790–#1794).

## Roster
| W | Type | Repo | Source | Disposition |
|---|---|---|---|---|
| Phase 0 | ci/cleanup | MK | #1814/#1815/#1816/#1817 | fix RED + merge into `main` (rolls into 0.50). #1806 + companion pins = maintainer, tomorrow |
| W-A | feat | MK | #1812 Stage 1 | NLEmbedding RAG default — full impl + merge |
| W-B | spike | MK | #1811 | Jinja render spike doc — NO impl merge |
| W-C | fix | manifold-llama | #1677 | KV determinism — reproduce-first, full fix + merge |

## Notes for maintainer
- **Versioning left for you tomorrow.** The run lands everything on `main`; #1806 (0.50.0) stays open and refreshing. Tomorrow: rewrite its CHANGELOG to Highlights, merge → tag, then bump both companion pins to `.upToNextMinor(from: 0.50.0)` + rewrite their CHANGELOGs by hand.
- ~4–5 PRs (Phase 0 merges 4; Phase 1 adds W-A; W-C in companion) + 1 spike doc. Tighter than the 06-13 run by design — most of the backlog is now merged or SDK-gated.
- Highest-risk: **W-C** (Metal/llama determinism, hardware-coupled — reproduce-first discipline) and **Phase-0 #1815** (API-break gate; resolve by policy, don't silence).
- Headline of the night: **W-A** — makes RAG (shipped v1 + #1814) actually usable with zero host-supplied embedder, closing the local-first/offline pillar gap.

---

## Outcome record (2026-06-14, kickoff 16:00 UTC)

All merged to `main` (rolls into the open 0.50.0 release PR #1806, left untouched per the versioning fence). Each PR ran the full local `scripts/test.sh --profile local` gate before push and was merged on green.

| Item | Result | PR / ref |
|---|---|---|
| Phase 0 — #1814/#1815/#1816 | Already merged in the afternoon (RED issues fixed there); confirmed on main | — |
| Phase 0 — #1817 nightly live Glass Box gate | **Merged.** Real root cause was NOT the reachability probe (already bounded, verified 3.04s skip) — it was the CI **stall-watchdog `progress_pattern`** not matching build-phase output, so a slow cold build (tipped over 240s by the new test file's compile units) was misread as a stall → SIGABRT. Fix widened the watchdog to count build progress; genuine hangs still trip it. | #1817 (`c31761e`) |
| W-B — #1811 Jinja rendering spike | **Merged (doc only).** Finding: the mismatch is **real and consequential** — the `PromptTemplate` enum silently drops the `tools` argument for all cases except `.gemma4`, so Qwen3.5 + Llama 3.1 tool-calling runs with the wrong convention. Recommends rendering in `ManifoldHardware` via `swift-jinja` direct (+1 net dep). Impl deferred per maintainer decision. | #1821 |
| W-A — #1812 Stage 1 NLEmbedding default | **Merged (headline).** `NLEmbeddingBackend` in `ManifoldInference`; `quickStart()` now enables RAG by default; fails closed to keyword search; host override preserved. Independently reviewed (APPROVE-WITH-FIXES: one misleading comment corrected). Integration tests with a kept negative assertion. | #1822 (`#1812`) |
| W-C — #1677 llama KV determinism | **No PR needed — already fixed.** manifold-llama#5 (`99d61e0`, merged) implements the exact batch-aligned re-decode. Worker *verified*: reproduced the RED on a real non-Qwen model (llama3.1-8b) by sabotaging back to the old logic, confirmed green with the merged fix. **Action left for maintainer:** close stale ManifoldKit#1677 (auto-mode classifier blocked the close — not explicitly authorized). | manifold-llama#5 |

### Left for the maintainer (daytime, manual)
- **Versioning / release:** #1806 (0.50.0) untouched and refreshing — rewrite its CHANGELOG to Highlights, merge → tag, then bump both companion pins to `.upToNextMinor(from: 0.50.0)` + rewrite their CHANGELOGs by hand.
- **Close ManifoldKit#1677** (resolved by manifold-llama#5; close was classifier-blocked this run).
- **#1818** (docs hero/companion refresh) — out of scope, still open and **CONFLICTING**; needs a rebase against the night's merges before it can land.

### Notes
- iOS `ci-ios-file-protection` flaked once on #1822 (`Unable to find a device … iPhone 16` — known runner variance, the test never ran); cleared on the next run. Not a data-protection regression despite the new default vector-store file.
- Worktrees created this run (`_wt/wa-nlembed`, `_wt/wb-jinja`) removed. The `.mk-worktrees/w1–w14` set is afternoon-run residue (already-merged features) — left untouched.
