# UI Refresh 2026 — implementation plan

**Audience:** contributor
**Status:** living

> Companion to [`UI-REFRESH-2026.md`](UI-REFRESH-2026.md) (the design spec —
> read it first) and tracking issue #2307. This plan is written for a cold
> **orchestrator** session: it names not only each unit's entry points, touched
> files, new API, tests, and review criteria, but *who executes each tranche,
> in which worktree, and in what order* — see **Orchestration model** below.
> **Release gate: OPEN.** v0.72.0 shipped 2026-07-17 (#2307); implementation
> may start now. File:line anchors reflect `main` at the time of writing
> (2026-07-17); re-verify before relying on them.

## Ground rules (from the spec + review)

- New look ships as the **default**; classic presets restore the old look.
  The defaults flip happens in the **last** layer of Unit 2 — no intermediate
  merge state ships half-flipped.
- `accent` resolves to the host's `Color.accentColor` — never a literal.
- Composer seams (`ManifoldConfiguration.Features` flags,
  `ComposerPermissionGate`, `chatComposerAccessory`) behave identically.
- macOS chrome is system-owned: contribute toolbar items, never draw bars.
- New declarations default to `package`; only the spec §8 protocol surface and
  the theme root go `public`, claimed explicitly in the PR body.
- Every new rule ships its tripwire in the same PR (Principle 4).

---

## Orchestration model (multi-worker execution)

This plan runs as an **orchestrator session fanning work out to parallel worker
agents**, not one cold session working linearly. The technical substance of
every unit below is unchanged — this section adds only *who does what, in what
order, in which worktree*. The dependency graph and the exact per-tranche file
ownership live in **[Worker tranches & dependency graph](#worker-tranches--dependency-graph)**
at the foot of this document; the rules a cold orchestrator must obey are here.

### Estate execution rules (non-negotiable)

- **Flat dispatch tree.** The orchestrator spawns *every* worker and *every*
  reviewer directly. Workers implement and **never spawn sub-agents**; a worker
  that needs more hands reports back and the orchestrator fans out.
- **Cheap models by default.** Writer workers run on **sonnet**; purely
  mechanical probes (literal inventories, allowlist edits, grep-shaped file
  sweeps) run on **haiku**. Reviewers run the `skeptical-reviewer` agent. The
  orchestrator holds the judgment; workers hold the diffs.
- **Isolated worktree per writer.** Every writer worker gets its **own git
  worktree branched off `origin/main`** (Unit 1) or off the named base branch
  of its tranche (Unit 2 stacked drafts). No two writers share a checkout.
  Reset the fresh worktree to the intended base immediately — the `wt` helper
  starts from the primary checkout's (often stale) HEAD, not `origin/main`.
- **Adversarial review per change.** Each worker draft is reviewed by an
  independent `skeptical-reviewer` dispatch: correctness, premise/assumptions,
  scope discipline, conventions, and *is the change live or inert* (the #2064
  lesson — a read path with no writer is dead code). Fix pushes get a **delta
  re-review** to the same reviewer. A **ship verdict on the current HEAD** is
  required before any merge — a stale "looks good" on an earlier push does not
  count.
- **Draft PR = zero-CI staging.** Open a draft the moment a worker branch
  compiles (protect work early). CI is gated off drafts, so the draft is where
  review and fix iterate. The single deliberate CI trigger is `gh pr ready`,
  flipped only when the change is review-clean **and** the local gate is green.
- **Local gate before every ready-flip.** `scripts/test.sh --profile local`
  (full — never `--filter <featureSuite>`; the cross-cutting audits live
  outside feature suites, so a filtered run goes green while CI goes red) plus
  the audit suites by name. Unit 2 adds
  `swift build --build-tests --traits Server,Macros` and the live-demo
  verification.
- **Merge through the queue.** `gh pr merge <N> --squash --auto`. Never
  `--admin`, never `gh api`-direct.

### Roles

- **Orchestrator** — owns the dependency graph and the synchronization points
  below; spawns workers and reviewers; packages worker branches into the
  sanctioned PRs; drives the merge queue. Holds no diffs itself.
- **Writer worker (sonnet)** — implements one tranche in one worktree; opens and
  keeps its draft; applies review findings; runs its local gate.
- **Probe worker (haiku)** — mechanical fan-out only (inventory a literal set,
  verify an allowlist, confirm a file boundary); returns data, makes no
  judgment call.
- **Reviewer (`skeptical-reviewer`)** — adversarial, read-only; verdicts on the
  current HEAD.

### Synchronization points (hard gates — cross only when the predecessor has landed where stated)

1. **Characterization before migration.** `DefaultAppearanceCharacterizationTests`
   (§1.1) exist and pass *before* any literal-migration worker touches a view
   file. The rewiring must prove itself against a locked baseline.
2. **Token type before literals.** `ManifoldTheme` (§1.2) exists on the Unit-1
   base branch before the ManifoldUI / ManifoldUIModelManagement / Voice
   migration workers start — they read tokens that must already be defined.
3. **Unit 1 merged before Unit 2.** The full Unit-2 stack branches off a `main`
   that already carries the token refactor; Unit 2 never re-does token plumbing.
4. **L1 before L2/L4.** Glass/chrome — and the per-OS `glass` resolution it adds
   to `ManifoldTheme` — is in the integration branch before the style-protocol
   and state-screen workers branch off it.
5. **L2's `ComposerStyle` before L3.** The composer redesign consumes it.
6. **L5 last, always.** The defaults flip runs only after L1–L4 are integrated;
   no intermediate state ships a half-flipped default.
7. **Ship-verdict-on-current-HEAD before each merge** — Unit 1's PRs, and the
   single Unit 2 integration PR.

### PR sizing vs. no-phased-splits (the reconciliation)

The estate's ~40-changed-file / ~800-net-line cap and the "no phased feature
splits" rule pull against parallelism, and the resolution differs per unit:

- **Unit 1 splits mechanically, not by phase.** PRs 1a/1b are the sanctioned
  mechanical split (both zero-visual-change; 1b is "remove allowlist entries +
  migrate"). Parallel migration workers *feed* those two PRs — they do not
  multiply them.
- **Unit 2 stays ONE merged feature.** Parallelism happens *inside a stacked
  draft series*, not across CI-triggering PRs. Workers build L1–L5 on stacked
  branches, each **reviewed while draft (zero CI)**; the layers integrate onto
  one Unit-2 branch that is the **single** ready/merge event. The ~40-file cap
  governs *independently-mergeable, CI-triggering* PRs; the repo's own escape
  hatch — *"if it's too big to review at once, stack it behind a draft and merge
  the stack as one — do not open a CI-triggering PR per phase"* — is exactly
  this case. Review quality is bought by per-layer draft review, **not** by
  cutting the merge into phase-PRs. **Parallel workers must never turn Unit 2
  into per-layer ready PRs.**

---

## Unit 1 — token refactor (one feature, PRs 1a/1b, zero visual change)

**Goal:** every themeable color/shape/type decision routes through one
environment-injected token root; today's rendered appearance is byte-for-byte
unchanged and locked by characterization tests.

### 1.1 Characterization tests first

New `DefaultAppearanceCharacterizationTests` (ManifoldUI test target):
value-level assertions (not pixel snapshots) that resolve the default theme
and assert today's constants — bubble fills (`ChatTheme.swift:22-29`), fonts
(`:47-51`), `cornerRadius`/paddings (`:32-43`), the tool-view status fills
(`ToolInvocationView.swift:135,237`), composer field fill + radius
(`ChatInputBar.swift:61`), status indicator colors
(`MemoryIndicatorView.swift:32-34`, `ContextIndicatorView.swift:26-28`),
model-management badge colors (`ModelPicker.swift:256-259`,
`DownloadableModelRow.swift:165-229`). Land these **before** the refactor
commit so the rewiring diff proves itself against them.

### 1.2 `ManifoldTheme` root

`Sources/ManifoldUI/Theming/ManifoldTheme.swift`, **`package` access in
Unit 1** (publicized with docs in Unit 2):

- Embeds the existing `ChatTheme` (bubble tokens) unchanged — `.chatTheme(_:)`
  keeps working by writing through to the embedded value.
- Adds semantic tiers per spec §7: `accent` (default: `Color.accentColor`),
  surfaces (`ground`/`surface`/`surface2`), inks (`ink`/`ink2`/`ink3`),
  status (`ok`/`warn`/`error` + `.soft` fills — typed as `AnyShapeStyle` like
  ChatTheme's tokens), `glass` (material reference; resolves per-OS in
  Unit 2, plain material in Unit 1), `shape` scale (xs 6 / sm 11 / md 14 /
  lg 20 / capsule, `@ScaledMetric`-consumed like today), type roles.
- `@Entry var manifoldTheme` + `.manifoldTheme(_:)` cascading modifier,
  mirroring `ChatTheme.swift:119-137`.

### 1.3 Migration sites (~65 literals across ~28 files; the inventory)

Group per file; each change is mechanical (literal → token read):

- **ManifoldUI:** `ToolInvocationView` (`.quaternary.opacity(0.5)`:135,
  `.green` checkmark:183, `.orange` error icon:229,
  `.orange.opacity(0.15)` badge:237);
  `ChatShellViews` (`.blue.opacity(0.08)`:45, `.red.opacity(0.1)`:270,
  `.yellow`, `.green`, `.blue`); `SessionListView` swipe tints
  (`.orange/.blue/.yellow`:159-181); `TypingIndicatorView` (`.secondary`:15);
  `StreamingCursorView` (`.primary`:12); `MessagePartsView`
  (`.gray.opacity(0.15)`:281 + placeholder styles); `CitationsView`
  (highlight `.accentColor.opacity(0.18)` and `.fill.quinary` row fills,
  :149-160);
  `MemoryIndicatorView`/`ContextIndicatorView` (status tiers);
  `AudioMessageView` (role-conditional fills); `MessageBubbleView`
  hardcoded white-opacity metadata styles (:171,176).
- **ManifoldUIModelManagement:** `ModelPicker.typeBadge()` (:256-259),
  `DownloadableModelRow.fitTint()/speedTint()/badgeColor()` (:165-229),
  `HuggingFaceBrowserView` curated/best badges (:308, tint :317),
  `DocumentLibraryView` (:186 drop target, `.orange` info),
  `APIConfigurationView` (`.yellow` warning), plus the literal-bearing
  secondary views the first sweep missed: `SessionExportSheet`,
  `BackendCapabilityView`, `RemoteServerConfigSheet`,
  `APIEndpointEditorView`, `APIEndpointRow`, `LocalModelStorageView`,
  `WhyDownloadView`, `StorageManagementView`, `DownloadProgressView`,
  `ImageModelInstallView`.
- **ManifoldVoice:** recording `.red` → `status.error`
  (`VoiceComposerAccessory`, `VoiceInputButton`).
- **Exempt (functional/data — taxonomy category b):**
  `MessageBubbleView.agentColor(for:)` (:327-338, UUID-hash palette),
  `ImagePlaceholderView.color(for:)` (hash grids).
- **Exempt (diagnostic — category c, per-file allowlist):**
  `ArchitectView`, `DiagnosticsView`, `EventTimelineView`,
  `PromptInspectorView`, `ContextSlotInspectorView`.

### 1.4 `HardcodedColorAuditTest`

Placed with the UI test target (pattern: `SilentCatchAuditTest`). Scans
`Sources/ManifoldUI`, `Sources/ManifoldUIModelManagement`,
`Sources/ManifoldVoice` for color literals in style positions
(`Color.red`-family, bare `.orange`-style members in `foregroundStyle`/
`tint`/`background`/`fill` calls). Allowlist = the category-b functions by
symbol and category-c files by path, each with a comment naming its taxonomy
category. In-file `test_sabotage_hardcodedColor` plants a literal in a temp
scan target and asserts detection; register with
`AuditSabotageCoverageAuditTest`.

### 1.5 Gate & PR

- `scripts/test.sh --profile local` (full), plus the audit suites by name.
- Docs: CHANGELOG line only (internal refactor); no consumer docs yet
  (`ManifoldTheme` is still `package`).
- Review criteria: zero rendered-appearance change (characterization green on
  both sides of the diff); no new `public` symbols; audit sabotage registered.

**Size check:** ~28 view files + 3 new files + tests — tight against the
~40-file soft cap, so the mechanical split fires: PR 1a =
`ManifoldTheme` + characterization + audit + ManifoldUI migrations, PR 1b =
ManifoldUIModelManagement/Voice migrations. Both are zero-visual-change, so
this is a mechanical split, not a phased feature split; `HardcodedColorAuditTest`
lands in 1a with the 1b files temporarily allowlisted, and 1b's diff is
"remove allowlist entries + migrate."

**Worker fan-out (see the tranche table):** `T1-tokens` (sonnet) is the
synchronization gate — it lands `ManifoldTheme` + characterization + audit and
owns `Sources/ManifoldUI/Theming/**` plus the new test files. Once its branch
exists, three migration workers run in parallel off it against **disjoint**
directories — `T1-migrate-ui` (sonnet, `Views/**`+`Extensions/**`),
`T1-migrate-mmgmt` (`Sources/ManifoldUIModelManagement/**`),
`T1-migrate-voice` (haiku, `Sources/ManifoldVoice/**`) — so no two writers ever
touch the same file. `T1-migrate-ui` integrates into **PR 1a**; the mmgmt and
voice migrations integrate into **PR 1b** (which rebases after 1a merges and
drops the allowlist entries).

---

## Unit 2 — the visual overhaul (stacked drafts, merged as one)

One feature. Build as a stacked draft series off `main` (post-Unit-1) — each
layer built by its own **writer worker in an isolated worktree**, reviewed
while draft (zero CI) — and merge the integrated stack as a single unit through
the queue. Layer order is dependency order (§sync points 4–6); once L1 lands in
the stack, `L2-protocols` and `L4-screens` run as **parallel** workers off L1
against disjoint paths, `L3-composer` follows L2, and `L5-flip` is always last.
Per-layer owned paths are in the [tranche table](#worker-tranches--dependency-graph);
the guardrail is that no two concurrently-live layer workers own the same file,
and **no layer worker flips its own PR ready** — only the orchestrator's
integration branch does, once.

### L1 — glass & material chrome

- Per-OS material resolution for `ManifoldTheme.glass`:
  `#available(iOS 26, macOS 26, *)` → `glassEffect`/`GlassEffectContainer`;
  below → `.regularMaterial`. iOS: composer + toolbar go translucent,
  transcript scrolls edge-to-edge beneath (replace the `Divider` seam,
  `ChatView.swift:248`).
- macOS: move title/model-chip/actions into `.toolbar { }` items (stop
  drawing any bar); docked width-constrained composer geometry; hover states
  on interactive rows/buttons (`.onHover` + pointer style).
- Scroll-to-bottom control in `ChatHistoryView` (owns anchoring logic
  already; the control appears when scrolled up during streaming).
- Tests: availability-seam build coverage (macOS 15 CI exercises fallback);
  a11y: control has a VoiceOver label; Reduce Motion honored.

### L2 — style protocols + part renderer

- `ComposerStyle`, `ThinkingBlockStyle`, `ToolInvocationStyle`,
  `SessionRowStyle` — each mirrors `MessageBubbleStyle.swift`'s shape
  (protocol + `Configuration` data struct + `@Entry` + cascading modifier +
  static accessors). Configurations carry the typed states from spec §8.
- `chatMessagePartRenderer` seam (deferred hook noted at
  `ChatMessageRenderer.swift:95-97`, issue #1640): per-part override with
  `defaultPartView()` fallthrough, LAST-WINS like the message renderer.
- Publicize `ManifoldTheme` (+ DocC).
- Built-in styles at this layer implement the **current** look (these become
  the `.classic` presets in L5); the new-look styles are added alongside but
  are not yet default.
- Tests: dispatch matrices (tool ×4, composer ×4, thinking ×3 states reach a
  recording test style); part-renderer fallthrough; LAST-WINS composition.

### L3 — composer + model picker

- Composer: "+" menu assembled from the existing `Features` flags
  (`ChatInputBar.swift:87-99` gating preserved item-by-item — the permission
  gate keeps *removing* unavailable items); platform-adaptive geometry via
  the default `ComposerStyle`; draft-attachment strip + quick-action pills
  restyled onto tokens in the accessory band.
- Unified switcher: a `package` selection-union type over
  `ModelRegistry.availableModels` + `EndpointStore` endpoints (mutual
  exclusion already in `ModelRegistry.swift:37-55` — presentation merge, not
  a selection-model change). Capability glyphs from
  `supportsReasoning` (`ModelInfo.swift:136`) / `toolCallClaim` (:149) /
  `mmprojURL` (:31);
  fit dot from `ModelLoadPlan.canRunModel`; dimmed rows from
  `FrameworkCapabilityService`; inline download progress from
  `DownloadStatus`; endpoint-fault rows with fix action.
- Thinking-budget control: maps Off→`maxThinkingTokens = 0`, Auto→`nil`,
  Extended→named budget; rendered only when
  `ModelManifest.supportsThinking` (`ModelManifest.swift:97`); sampler knob
  visibility gated on `supportedSamplingParameters` (:120; the
  `SamplingParameterSet` OptionSet itself is :27-41).
- Tests: switcher union (endpoints + models co-listed, selection mutual
  exclusion preserved); manifest gating (no thinking row for
  non-thinking models); "+"-menu flag mapping (each flag off → item absent);
  permission-gate behavior unchanged (existing tests must stay green
  untouched).

### L4 — state screens, generated media, MCP services

- §6A screens: first-run funnel, milestone-named bootstrap loading, model
  loading w/ cancel, empty-session suggestions (via `chatEmptyState`),
  in-transcript turn-failure card, composer fault banner.
- Generation progress card wiring `ChatViewModel.imageGenerationProgress` /
  `videoGenerationProgress` (data currently unrendered) — step bar, blurred
  preview, cancel; settles in place. AVKit player for generated video
  (replaces prompt-text rendering, `MessagePartsView.swift:220-236`);
  missing-media statusWarn treatment; system viewer on tap.
- Connected Services (experimental, `ManifoldUIModelManagement`): promote the
  demo's `ConnectedServicesView` pattern — services list (status tier),
  consent-before-exposure card, reauth via `ToolErrorPresentation`
  "mcp.reauthenticate", `MCPToolCountView` for counts/cap.
- Branch origin chip (reuses `HandoffChipView` pattern) + pin glyph in bubble
  metadata.
- Tests: state-screen rendering per state; progress-card lifecycle
  (progress → settled → missing); consent flow (no tool exposure before
  consent); chip/glyph presence logic.

### L5 — defaults flip + classic + migration

- Flip the built-in defaults to the new-look styles; ship
  `ChatTheme.classic` / classic style presets.
- Characterization tests re-anchor: new defaults pinned; a parallel suite
  pins `.classic` == the Unit-1 characterization values (the old look must
  remain reproducible).
- Migration note + CHANGELOG lead; AGENTS.md Part 1 theming update.

### Unit 2 gates (before the stack merges)

- `scripts/test.sh --profile local` (full) + audit suites by name +
  `swift build --build-tests --traits Server,Macros`.
- **Live verification (mandatory — UI change):** drive both demo apps
  (`Example/Examples/MinimalExample`, Advanced) on macOS and iOS simulator;
  compare against the spec's drawn mockups; persona walkthrough (below).
- `scripts/demo-apps-build.sh` at Unit-2 merge time (early, not just at
  release — a visual break is the case the demo gate exists for).

---

## Documentation plan (ships inside the units)

| Doc | Unit/Layer | Notes |
|---|---|---|
| CHANGELOG (internal refactor line) | U1 | |
| `Theming.md` rewrite (token model, `ManifoldTheme`, coverage table, a11y checklist) | U2-L2 | Replaces bubble-only scope |
| Per-protocol DocC pages ×5, one compile-gated snippet each | U2-L2 | Snippets join the single-build snippet gate |
| Connected Services DocC (experimental, wiring + consent contract) | U2-L4 | |
| Liquid Glass adoption note (auto behavior, fallback, opt-out) | U2-L1 | |
| "White-label your chat" recipe (worked brand swap) | U2-L5 | The templatability showcase |
| **Migration note — the 0.x visual break** (change inventory + `.classic` restore + retired APIs) | U2-L5 | CHANGELOG leads with it |
| AGENTS.md Part 1 (new theming surface; hallucination entries) | U2-L5 | `AgentsMdAuditTest` keeps honest |
| QUICKSTART / SWIFTUI-MULTI-SESSION / README snippet refresh | U2-L5 | See DX testing — onboarding changes |

## DX testing (onboarding changes — explicit requirement)

The refresh changes what a new consumer sees on first run and how they theme.
Per `docs/QA-PRACTICES.md`, four lanes:

1. **Cold-start gate refresh:** the cold-start consumer projects rebuild
   against the new defaults; add one cold-start scenario that (a) boots the
   minimal app and asserts the first-run funnel renders, (b) applies a custom
   `ManifoldTheme` + one custom style, (c) applies `.classic`. Compile +
   run-assert level, CI-run via the existing cold-start workflow.
2. **Doc-snippet compile gate:** every new snippet (theming, five protocols,
   connected services, migration examples) joins the single-build gate — no
   snippet lands undocumented in the gate manifest.
3. **Cold-start human / persona walkthrough (pre-merge of Unit 2):** a
   scripted walkthrough as three personas — *new consumer* (README →
   quickstart → first message), *brander* (re-theme to a fake brand using
   only the docs), *upgrader* (existing 0.71-style app, apply the migration
   note, then `.classic`). Findings block ready-for-review like code
   findings. The `cold-start-human.yml` lane hosts it.
4. **AgentsMdAuditTest + hallucination check:** after docs land, prompt-test
   an assistant against Part 1 for the known failure shapes (inventing
   `vm.setTheme(_:)`, effort enums, per-model presets) and add observed
   hallucinations to the Part-1 list.

## Release checklist (the release after current)

- [ ] Release Please PR: rewrite CHANGELOG — lead with the visual break,
      Prisma-style Highlights with a theming snippet and the `.classic`
      restore line.
- [ ] `scripts/demo-apps-build.sh` green (re-run at release even though
      Unit 2 ran it).
- [ ] Companion heads-up: manifold-mlx / manifold-llama maintainers notified
      of any new `BackendCapabilities`-adjacent fields (none planned; confirm
      at release).
- [ ] Artifact mirror updated from the repo HTML if the spec changed during
      implementation.

## Worker tranches & dependency graph

Each tranche is one writer worker in one isolated worktree. **Owned paths are
disjoint across any set of concurrently-live tranches**, so parallel workers
never touch the same file; the boundaries are drawn from the real source layout
(verified in the worktree). "Base branch" is where the worker branches from and
resets to.

### Unit 1 (release gate open — starts now)

| Tranche | Model | Base branch | Owns (disjoint) | Depends on | Packaged into |
|---|---|---|---|---|---|
| **T1-tokens** *(sync gate)* | sonnet | `origin/main` | `Sources/ManifoldUI/Theming/ManifoldTheme.swift` (new, `.chatTheme` write-through) + the new `DefaultAppearanceCharacterizationTests` and `HardcodedColorAuditTest` files | §1.1 characterization precedes the refactor commit | **PR 1a** |
| **T1-migrate-ui** | sonnet | T1-tokens | `Sources/ManifoldUI/Views/**`, `Sources/ManifoldUI/Extensions/**` literal→token migration | T1-tokens (`ManifoldTheme` must exist) | **PR 1a** |
| **T1-migrate-mmgmt** | sonnet | T1-tokens | `Sources/ManifoldUIModelManagement/**` migration + allowlist removal | T1-tokens | **PR 1b** |
| **T1-migrate-voice** | haiku | T1-tokens | `Sources/ManifoldVoice/**` (`VoiceComposerAccessory`, `VoiceInputButton`) | T1-tokens | **PR 1b** |

### Unit 2 (one merged feature; stacked drafts)

| Tranche | Model | Base branch | Owns (disjoint) | Depends on |
|---|---|---|---|---|
| **L1-glass** *(stack sync gate)* | sonnet | `main` (post-U1) | `Views/Chat/ChatView.swift`, `Views/Chat/ChatHistoryView.swift`, macOS toolbar contribution, per-OS `glass` resolution in `Theming/ManifoldTheme.swift`, scroll-to-bottom control | Unit 1 merged |
| **L2-protocols** | sonnet | L1 | new `Theming/{ComposerStyle,ThinkingBlockStyle,ToolInvocationStyle,SessionRowStyle}.swift`, `Theming/ChatMessageRenderer.swift` (part-renderer seam), publicize `ManifoldTheme` + DocC | L1 |
| **L4-screens** | sonnet | L1 | `Views/Chat/MessagePartsView.swift` (video/media), new state-screen views under `Views/Chat/`, `Views/Chat/HandoffChipView.swift` (branch chip), `ManifoldUIModelManagement/Views/Settings/**` (Connected Services) + `Views/Image/**` — consumes **tokens only**, not L2's new protocols, which is what keeps it parallel to L2 | L1 (∥ L2) |
| **L3-composer** | sonnet | L2 | `Views/Composer/**`, `Views/Chat/ChatInputBar.swift`, `ManifoldUIModelManagement/Views/Models/ModelPicker.swift` + the `package` switcher-union type, thinking-budget control | L2 (`ComposerStyle`) |
| **L5-flip** *(last, always)* | sonnet | integrated L1–L4 | defaults flip across `Theming/**` (ChatTheme + built-in style defaults), `.classic` presets, characterization re-anchor, migration note + CHANGELOG lead + AGENTS.md Part 1 | L1–L4 all integrated |

Within `ManifoldUIModelManagement`, L3 owns `Views/Models/**` and L4 owns
`Views/Settings/**` + `Views/Image/**` — disjoint, so the two run without
collision even though both touch that module.

### Dependency graph

```
v0.72.0 shipped (release gate OPEN)
  └─ Unit 1:  T1-tokens ─┬─► T1-migrate-ui ───────► PR 1a ──► merge
       (sync gate)        ├─► T1-migrate-mmgmt ─┐
                          └─► T1-migrate-voice ─┴─► PR 1b ──► merge
                                (three migration workers parallel off T1-tokens,
                                 disjoint dirs; PR 1b rebases after 1a)
       └─ Unit 2 stack (ONE merged feature):
            L1-glass ─┬─► L2-protocols ─► L3-composer ─┐
             (gate)   └─► L4-screens ───────────────────┼─► L5-flip ─► integrate ─► ONE PR ─► merge queue
                          (L2 ∥ L4 off L1; L3 after L2;   (defaults flip last)
                           L5 after all)
release PR → DX walkthrough sign-off → ship
```

Orchestrator loop per tranche: spawn writer (sonnet/haiku) in a fresh worktree →
draft PR on first compile → spawn `skeptical-reviewer` → workers fix, reviewer
delta-re-reviews to a ship verdict on current HEAD → orchestrator runs the local
gate and packages/integrates. Unit 1 flips 1a then 1b ready through the queue;
Unit 2's integration branch is the single ready/merge event for the whole stack.
