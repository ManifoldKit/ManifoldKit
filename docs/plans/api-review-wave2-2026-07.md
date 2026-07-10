# Pre-1.0 API program — Wave 2 execution plan (2026-07-10, v2 — post adversarial review)

**DECISIONS MADE (Rory, 2026-07-10):** D1 = (a) fix APIProvider in place (stable opaque
raw codes + `displayName` + legacy display-string decode migration; enum stays closed).
D2 = rename `Score`→`EvalScore` WITH a pre-staged manifold-eval adapt draft.
D3 = keep `Log` as-is; document module-qualification as the collision workaround.
D4 (#2128 adjudication) remains open and decoupled — does not gate the wave.

Successor to `api-review-2026-07.md` (v2), which is ~80% executed (Phases 0–1 + most of
Phase 2 shipped in v0.67.0). Covers: the residue of that plan, the 2026-07-10 independent
review findings (N1–N8 below), and the process gaps the execution audit exposed.

**v1 → v2:** three adversarial persona reviews (release-engineering/feasibility,
API-design/consumer-advocate, root-cause/scope skeptic — all FIX-FIRST) produced material
corrections. Every load-bearing change is recorded in the Review record at the end.
Headlines: the regrowth barrier the predecessor plan claimed to ship is half-theater and
must be installed BEFORE any new breaking work; the "11 independent parallel items" claim
was false (shared schema files, shared Hardware module, single allowlist/baseline files);
APIProvider must NOT become an open struct (it is a wire-routing discriminant); `Log` is
load-bearing cross-module infra, not a leaked internal; two v1 items are cut outright;
the open v0.68.0 release PR must be drained before the first `feat!:`.

## Verified ground truth (2026-07-10, HEAD b8f0bbb1)

- v0.67.0 shipped the first breaking wave; companions adapted via staged drafts
  (mlx#139, llama#136) merged green ~1h after the tag — the staged-draft machinery works.
- companion-compat.yml dispatch for that wave FAILED (it checks out companion main, which
  still had adapt code in drafts) and was never re-run green. It screens ONLY
  manifold-mlx/manifold-llama — manifold-eval is never screened by it; eval exposure is
  caught only by the post-release core-bump red pin.
- No evidence `scripts/demo-apps-build.sh` ran before release PR #2161 merged.
- 0 of 5 local consumer apps migrated to 0.67 (existing drafts ChatbotUI-iOS#6,
  grok-app#9, LocalImage#2 predate the wave; cover only the P7 shim retirement).
- api-digester breaking gate: REAL and biting — all 28 library-product targets
  (ci.yml:644-670), including PersistenceSwiftData/Hardware/Skills/test kits. @Model
  visibility demotions ARE visible to it.
- Accretion-prevention levers: THEATER as of today —
  - `docs/API-DESIGN.md` is referenced from nowhere live (not AGENTS.md, not CLAUDE.md).
  - The "standing review question" it claims the /ship reviewer brief carries is absent
    from the live `.claude/skills/ship` and `skeptical-reviewer` agent.
  - `scripts/api-surface-baseline.sh` self-declares prototype, is wired into ZERO
    workflows, covers 7/28 modules. (The XCTest `PublicSurfaceBaselineTests` wrapper
    does run `--check` for those 7 modules inside the test suite.)
- Regrowth already demonstrated: N4 (TurnConfig sampler dup) is API-DESIGN.md's own §2
  counter-example, still live.
- Still-open breaking backlog: #2153 capability naming (arch-1.3 tripwire NOT built —
  no updating(...) copy-with, no correspondence test; AnyLanguageModelBackend still
  hand-rebuilds 25 fields), ModelType enum→struct (arch 4.1), claims-registry
  instance-scoping (arch 4.2), TestSupport persistence split (arch 4.4),
  deprecated-enqueue sweep (arch 5.3).
- Release PR #2179 (v0.68.0) is OPEN — Release Please accumulates continuously; the
  first merged `feat!:` folds the wave into whatever release PR is rolling.
- #2158 checkboxes for #2150/#2151/#2152/#2154 are stale (all closed).

## Review findings folded in (N1–N8, all hand-spot-verified; v2 dispositions)

- N1 `APIProvider` persists display-string raw values ("OpenAI Responses", "LM Studio")
  decoded `?? .custom` (SchemaV3:243/V4:263). REAL, but v1's open-struct remedy is WRONG:
  APIProvider drives four exhaustive switches including backend-class wire routing
  (CloudSaaSBackends.swift:18-24); an unenumerated open value hits `default: return nil`
  — no backend at all, strictly worse than the working `.custom → OpenAIBackend`
  OpenAI-compat fallback (how Gemini/xAI/Groq work today). → Decision D1, reframed.
- N2 21 public `@Model` classes across 10 public `ManifoldSchemaVN` enums, zero
  cross-module code references. Demotion CONFIRMED COHERENT by the design review:
  `Persisted*` aliases point at V9 classes, which V12 (current) carries forward verbatim;
  V10–V12 only add types; `ManifoldMigrationPlan` type-erases. Keep V9 + aliases public,
  demote V3–V8, V10–V12. Worker gate assertion: nothing public directly names
  `V4.APIEndpoint` / `V4.ModelBenchmarkCache` / `V5.RagDocument` / `V6.TurnUsageModel`.
- N3 `ConversationEvent`/`FinishReason`/`CompressionReason` lack GenerationEvent's freeze
  mechanics; `ConversationEventKind` raw values ride persisted JSONL traces with no
  unknown-tolerant decode. Posture decided (was D2, now a recommendation — see 0.6):
  existing Kind raw values immutable, new kinds APPEND-ONLY (not "frozen"), readers must
  tolerate unknown kind strings; `@unknown default` guidance on all three enums.
- N4 `TurnConfig` re-declares temperature/topP/repeatPenalty byte-identical to
  GenerationConfig — the one live RC4 instance; API-DESIGN.md's own counter-example.
  Shape specified (design review): COMPOSITION — `TurnConfig.generation: GenerationConfig`
  (preserves one-knob ergonomics for BYO-UI consumers); runtime OWNS tools — document
  that `generation.tools` on a TurnConfig is not the tool source (ToolRegistry is).
  Cross-module constructors (ManifoldAppEval, ManifoldMCPHost, ChatViewModel) → S/M.
- N5 Bare generic public names under the umbrella: `Message`, `Agent`, `Skill`, `Log`,
  `Score`. KEEP `Message` (kernel type; three-name split already documented). `Log` is
  NOT demotable — ~145 call sites across 20 modules; separate decision line (D3).
  Matched suffixes: `Agent`→`AgentDefinition`, `Skill`→`SkillDefinition` (not
  Descriptor/Definition mix). `Score`→`EvalScore` breaks manifold-eval through
  ManifoldTools' public signatures (BFCLScorers.swift:16,35) which companion-compat
  cannot screen → only with a pre-staged eval adapt draft, else skip (D2).
- N6 `MessageBubbleStyle.content: AnyView` — CUT (skeptic + design concur: idiomatic
  SwiftUI configuration-pattern erasure; generic-izing ripples the whole theming protocol
  for marginal benefit).
- N7 `APIEndpointRecord: Codable` with deliberate CodingKeys — additive, ships in
  Track 0. Confirmed low-risk.
- N8 Doc-truth: AGENTS.md cloud recipe step 3 `runtime.endpointStore` → `bootstrap.…`;
  DocC "errors surface as ManifoldKitError" vs the send path's `SendMessageError`.
  Ships in Track 0.

---

## Track 0 — Install the regrowth barrier + close the 0.67 loop (non-breaking, FIRST)

Nothing in Track 2 dispatches until 0.A–0.C are merged (skeptic F1: cleanup without the
barrier schedules wave 3).

| # | Item | Worker | Gate |
|---|------|--------|------|
| 0.A | **Make the levers live**: (a) inline the visibility / delete-don't-deprecate / layer-ownership rules into AGENTS.md Part 2 with a pointer to API-DESIGN.md; (b) add the standing surface question to the live `/ship` reviewer brief AND the `skeptical-reviewer` agent definition; (c) wire `api-surface-baseline.sh --check` into nightly and expand baseline 7→28 modules NOW (moved up from old Track 3.1) | 1× sonnet | script green on all 28; nightly run green |
| 0.B | Drain the release train: merge v0.68.0 (PR #2179) with rewritten changelog + demo-apps gate, so the wave gets its own clean minor | orchestrator | demo-apps-build.sh result POSTED on the release PR |
| 0.C | Re-dispatch companion-compat.yml (companion mains now carry 0.67 adapt code); record green run URL on #2155 | orchestrator | green run |
| 0.D | Build the arch-1.3 capability tripwire (copy-with `updating(...)`, field-completeness + requirement↔field correspondence test, fix AnyLanguageModelBackend rebuild + stale `union`) — non-breaking, unblocks 2.6 | 1× sonnet | whole-target + new tripwire green |
| 0.E | Doc-truth + additive batch (1 PR): N8 both fixes; `APIEndpointRecord: Codable`; N3 append-only posture paragraphs (per 0.6 below) on the three runtime enums + unknown-tolerant Kind decode note for trace readers | 1× sonnet | --profile local (affected targets) + draft-review loop |
| 0.F | Housekeeping: tick #2150/#2151/#2152/#2154 on #2158; file N-findings as issues; post the D-decisions comment | orchestrator | n/a |
| 0.6 | POSTURE (recommend-and-proceed, was v1's D2): runtime event enums stay open with `@unknown default` guidance; ConversationEventKind existing raw values immutable, new kinds append-only, readers tolerate unknown kinds | — | folded into 0.E |

DECOUPLED from the critical path (own stream, not wave-blocking — skeptic F5):
- 0.G Local-app migration sweep (5 apps; extend the 3 stale drafts to 0.67 breaks; new
  branches for fireside/idlewick). The wave's contract to apps is the migration note;
  the demo-apps gate is the release-blocking canary. 3× sonnet, own worktrees per app
  repo, whenever convenient.

## Track 1 — Decisions (Rory; only what's genuinely contested)

- **D1 — APIProvider: fix-in-place or leave.** Open-struct is OFF the table (routing
  discriminant — see N1). Remaining choice: (a) keep enum closed, migrate raw values to
  stable opaque codes + `displayName` + legacy-string decode migration (kills the
  persisted-display-string wart while pre-1.0 is cheap; M, persistence-migration risk);
  or (b) leave as-is + document the raw values as a frozen persisted contract and the
  `.custom`/BackendDescriptor-registry hatch as the third-party path (zero risk, wart
  frozen forever). Skeptic recommends (b); design review recommends (a). Orchestrator
  lean: (a) — pre-1.0 is the only cheap window to change persisted raw values, and the
  migration test shape is well-understood (seed legacy `providerRawValue` → open
  container → read back → re-encode round-trip; in-memory SwiftData, no mocks).
- **D2 — `Score`→`EvalScore`: rename with a pre-staged manifold-eval adapt draft, or
  skip.** Eval consumes it through ManifoldTools' public signatures; compat workflow
  can't screen eval; arch X3 treats eval's types as wire contract. Skip is the cheap
  call; rename is the clean-namespace call (Eval namespace already has ModelFitScore /
  CaseScore). Orchestrator lean: rename, WITH the staged eval draft — ManifoldTools is
  semver-exempt and eval exact-pins, so the window is controlled.
- **D3 — `Log`: keep as-is, or rename `ManifoldLog`.** NOT demotable (~145 sites,
  20 modules, companions/apps log through it). Keep = zero churn, cosmetic collision
  risk remains; rename = bounded but real 145-site + 2-companion sweep. Orchestrator
  lean: keep, document the collision workaround (module-qualify) — spend the breaking
  budget elsewhere.
- **D4 — #2128 wire-or-cut (13 surfaces): adjudicate the posted comment, decoupled from
  the wave** (skeptic F6 — taste-heavy product calls must not stall type-design breaks).
  One v1 default overturned by the design review: UsageStore read APIs move from "cut"
  to "document-as-seam" — token/cost read APIs are on-identity for a toolkit whose
  flagship consumers build their own UI; cutting the reader while every schema version
  keeps persisting TurnUsageModel is a writer-with-no-reader inversion. Cuts that ride
  a later break window ride whatever minor is next — they do NOT gate this wave.

## Track 2 — Breaking pass (loose train: clustered where coupled, rolling where not)

Prereqs: 0.A–0.E merged; D1/D2 decided (D3 only if rename chosen; D4 fully decoupled).

**Concurrency truth (feasibility F1/F2):** every item appends to the single
`.github/api-breakage-allowlist.txt` and most regenerate a shared per-module
`api-surface-baseline/*.txt` — items sharing a module rebase-serialize. The real
topology is three sequential clusters + one parallel lane, not 11 parallel workers.
Per-item deliverables ALWAYS include: regenerated module baseline(s), allowlist entries,
migration note, whole-target gate + audit suites.

**Cluster A — Persistence (strictly ordered):**
1. A1 = D1(a) if chosen: APIProvider stable codes + decode migration (M, **opus** —
   persisted-data migration; test shape per D1). Touches SchemaV3/V4 accessor.
2. A2 = N2 schema demotion V3–V8, V10–V12 → internal; keep V9 + `Persisted*` public
   (M, sonnet). Rebases on A1. Gate assertion per N2 note.

**Cluster B — Hardware (strictly ordered; single module baseline):**
1. B1 = ModelType enum→struct (arch 4.1) (M, sonnet).
2. B2 = #2153 capability naming (S, sonnet) — gated on 0.D's tripwire, which then
   enforces requirement-case ↔ field-name correspondence.

**Cluster C — mechanical batch (ONE PR, sonnet — skeptic F8, precedent #2153-style):**
N4 TurnConfig composition (per the specified shape) + arch 5.3 deprecated
enqueue/generate overload deletion + N5 renames as decided (AgentDefinition /
SkillDefinition; EvalScore only per D2 with staged eval draft). Cross-module: AppEval /
MCPHost / ChatViewModel TurnConfig constructors; 2 llama + 2 eval enqueue sites → staged
companion/eval drafts.

**Parallel lane (genuinely independent modules):**
- P1 arch 4.2 claims-registry instance-scoping (M, sonnet; 3-repo staged drafts).
- P2 arch 4.4 TestSupport persistence split (S/M, sonnet; semver-exempt product —
  can also land rolling before the train, per skeptic F4).

Wave mechanics:
- companion-compat.yml dispatched mid-wave after Cluster C and P1 (the companion-risky
  items) and once after the last item; staged adapt drafts per §II.2 for mlx/llama AND
  a staged manifold-eval draft for Cluster C (compat workflow cannot screen eval).
- `scripts/demo-apps-build.sh` is a BLOCKING pre-release step with its result posted on
  the release PR (0.67's silent skip does not repeat).
- Merge queue throughout; ready in batches of 2–3; no unrelated `feat:` PRs deliberately
  scheduled mid-wave (accepted risk: parallel sessions may still land some — the release
  simply carries them).
- ONE release at the end; changelog rewritten (Prisma Highlights) AFTER the last merge,
  never mid-wave (release-please self-recognition hazard).

## Track 3 — Seal (after the wave's release)

- 3.1 Freeze the (now 28-module, per 0.A) surface baseline at the post-wave surface;
  from here growth requires a same-PR baseline bump + the AGENTS.md-cited justification.
- 3.2 DX walkthrough re-run against the released version (last tracked: v0.54).
- 3.3 Docs sweep: AGENTS.md/CLAUDE.md target tables, MIGRATION notes, companion
  release-notes lines.
- 3.4 #2157 residue not already consumed by 0.A/0.D: Voice AsyncStream overloads
  (additive), BackendError media/embedding extension, quickStart OS-gated diagnostic,
  digester parallel-job hoist.
- 3.5 Declare 1.0-rc posture: frozen baseline + live reviewer question hold the line;
  further breaks need a named exception. (No 1.0 date exists; this plan ends at posture,
  and that is deliberate — the barrier, not the tag, is the deliverable.)

## Orchestration & routing

- Orchestrator: dispatch, cluster sequencing, merge-queue shepherding, CI watch,
  compat/eval dispatch timing, #2158 bookkeeping. No orchestrator full local gates for
  fleet items (worker whole-target + audits + queue is THE gate).
- Workers: sonnet default; opus only for A1 (persisted-data migration). Max 4–5
  concurrent; clusters run internally sequential; pushes serialized; ready in
  batches of 2–3.
- All workers: own worktree off origin/main, compile→commit→draft-PR before long gates,
  conventional commits, no --admin merges.

## Cut / out of scope (v2)

- N6 theming AnyView rework — CUT (idiomatic erasure; disproportionate ripple).
- APIProvider open-struct — CUT (routing discriminant; see N1/D1).
- `Log` demotion — CUT as infeasible; `Message` rename — kept out deliberately.
- #2128 wiring work (product build-out) — post-1.0 features; only decided cuts ride
  whatever break window is next, not necessarily this one.
- Everything the predecessor plan's out-of-scope list already excluded; 1.0 tagging.

## Review record (v1 → v2)

Three adversarial persona reviews, all FIX-FIRST. Material changes:
1. **Regrowth barrier moved to Track 0 as a hard gate** (skeptic F1: API-DESIGN.md
   orphaned; standing question absent from live reviewer briefs; tripwire in zero
   workflows; N4 proves regrowth). Old Track-3.1 baseline expansion moved to 0.A.
2. **Parallelism claim corrected** (feasibility F1/F2): schema files shared by
   APIProvider-fix and schema-demotion → Cluster A ordered; Hardware items → Cluster B
   ordered; single allowlist/baseline files serialize; genuine parallel lane is only
   claims-registry + TestSupport split. Baseline-regen named a per-item deliverable (F6).
3. **APIProvider open-struct killed** (design F1: wire-routing discriminant; unknown
   value → `default: return nil`, strictly worse than `.custom` fallback; BackendName is
   a label, not a precedent). D1 reframed to fix-in-place (stable codes) vs leave.
4. **arch-1.3 tripwire dependency made real** (feasibility F3: it doesn't exist; nobody
   was building it). New item 0.D; #2153 gated on it explicitly.
5. **manifold-eval blast radius surfaced** (feasibility F4): compat workflow screens only
   mlx/llama; `Score` rename reaches eval through ManifoldTools public signatures →
   D2 + staged eval draft requirement recorded in wave mechanics.
6. **Release-train collision handled** (feasibility F5): drain #2179 (0.B) before the
   first `feat!:`; changelog rewrite only after the last wave merge.
7. **Cuts** (skeptic F2/F3, design concurring on both): N6 AnyView item removed;
   APIProvider de-fanged per (3).
8. **Decoupling** (skeptic F5/F6): local-app migration (0.G) and #2128 adjudication (D4)
   off the wave's critical path; UsageStore reads flipped cut→document-as-seam
   (design F6: writer-with-no-reader inversion, on-identity for toolkit-first).
9. **Batching** (skeptic F8): the S/mechanical breaks consolidated into Cluster C's
   single PR, mirroring the v0.67 precedent (#2153-style batch), reserving solo PRs for
   the M migrations.
10. **D2 (runtime-event posture) demoted from decision to recommendation** (skeptic F7)
    with the design review's precise wording: append-only kinds, immutable existing raw
    values, unknown-tolerant readers — "freeze" was the wrong word.
11. **TurnConfig shape specified** (design F5): composition (`generation:
    GenerationConfig` member), runtime owns tools, `generation.tools` documented as
    not-the-tool-source. Sizing bumped S→S/M (three cross-module constructors).
12. **Rename suffixes matched** (design F3): AgentDefinition + SkillDefinition;
    `Log` recharacterized (design F2) as load-bearing infra → decision D3, demotion off
    the table.
