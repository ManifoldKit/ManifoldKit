# Pre-1.0 API program — v1 rationalisation plan (2026-07-13, v4 — post adversarial + origin-app review)

**Status:** Active — roadmap reset 2026-08-16. Earlier demotion and
experimental-tier decisions are historical context; the remaining stable-tier
seal (C.2) is future work and cannot be represented as settled while the
Tier 1/2 release-health blockers in
[`docs/RELEASE-1.0.md`](../RELEASE-1.0.md#release-health--qualification-ledger)
remain open. C-D1, C-D2, B-D1 are decided; B-D2 remains recommended.

**Terminology:** several findings come from **the origin app** — the private
first-party app ManifoldKit was spun out of, its heaviest consumer (176
`import ManifoldRuntime` + 166 `import ManifoldInference` sites). It is not named
here; its adaptation work is planned in its own private repo. "First-party consumer
apps" refers to the three private apps surveyed alongside the public companions
(manifold-mlx, manifold-llama) and manifold-eval.

**Supersedes:** `api-review-wave2-2026-07.md` (executed: D1–D3 shipped via v0.69.0).
Absorbs: Track 3 seal (#2156 — Phase C below) and the origin-app-coupled subset of
#2128 (Phase B.5). Wave-2's **0.G local-app migration sweep is NOT dropped**: it
carries forward as the same decoupled, non-gating stream it always was (retired-shim
references remain in the three older local apps; 3× sonnet, app-repo worktrees,
whenever convenient). The wave-2 plan is closed on merge of this one.

**Thesis:** the cheapest time to shrink the public API is now, before 1.0 freezes it.
A full cross-reference of the checked-in api-surface baselines against every real
consumer shows only a minority of the 837 top-level public types are referenced by any
external consumer. Three levers:

1. **Phase A** — mechanical `public → package` demotions of undocumented internals in
   *stable-tier* modules (~85 types, zero consumer impact by construction,
   verification-gated). The payoff is a smaller frozen 1.0 contract (plus digester
   surface and autocomplete hygiene) — NOT compile time; source-distributed SwiftPM
   gains nothing at build time from `package` vs `public`.
2. **Phase B** — MK-side seam consolidation, landed additively on MK's own schedule;
   the origin app's adaptation happens in its own privately-planned upgrade, and the
   contingent demotions land only after it. Nothing in Phase C gates on it.
3. **Phase C** — declare an **experimental tier**: modules with zero real adopters do
   not enter the 1.0 stability promise, each with an explicit graduate-or-delete
   decision point so the tier cannot become a parking lot.

## Why a third pass is worth running (the regrowth barrier is live)

Wave-2 called the accretion-prevention levers "theater." That is no longer true — 0.A
shipped: AGENTS.md Part 2 inlines the visibility / delete-don't-deprecate /
layer-ownership rules with the standing review question; the `/ship` reviewer brief and
the skeptical-reviewer agent carry the question; `scripts/api-surface-baseline.sh`
covers all 28 modules and runs `--check` nightly (`nightly-slow-tests.yml`). Honest
caveat: the baseline is a **drift-gate**, not a growth blocker — it forces an
intentional same-PR baseline edit and asks for justification; it cannot enforce the
justification's quality. That is exactly why pruning now pays: with the drift-gate
live, surface removed by this plan stays removed visibly.

## Ground truth (2026-07-13, corrected post-review)

Method: dumped all top-level public types from `Tests/APIFreezeTests/api-surface-baseline/`
(28 modules, 837 unique types), word-boundary-grepped each against six consumer repos
(three first-party apps, manifold-mlx, manifold-llama, manifold-eval) plus in-repo
consumer surfaces (docs/, README, Example/, scripts/dx-walkthrough/). Four independent
classification passes grouped every zero-external type into seams and verified
anchoring against used entry points' actual public signatures. Three adversarial
reviews then re-verified samples (~40 candidates source-checked, all clean).

**Known limits of the scan (these shape the A.0 protocol):**
- The initial scan was NOT source-restricted: one consumer repo tracks build logs that
  name-match many Inference/Runtime types, so the headline "227 externally referenced"
  is an OVERCOUNT of real usage — the error direction is safe (the true demotable set
  is a superset), but per-type attributions must be re-derived with `rg -w -t swift`
  before acting. A.0 mandates this.
- Name-grep misses consumers touching API only through type inference or member
  access on an inferred type. Mitigation: A.0 also greps public member names.
- The repo is public; unknown consumers exist. Pre-1.0 policy (API-DESIGN §4):
  delete-don't-deprecate, migration note in the same PR.
- Backend-family adapter internals legitimately show zero external references (apps
  use registrars); excluded from candidacy.

Key facts (spot-verified by reviewers):
- 837 top-level public types; at most 227 externally referenced (overcount, see
  above); 373 referenced by nothing at all (no consumer, doc, example, walkthrough).
- Zero external imports of: ManifoldMCP, ManifoldMCPHost, ManifoldSkills,
  ManifoldAppIntents, ManifoldAnyLanguageModel, ManifoldTelemetryOTLP.
  **ManifoldVoice is adopted** — a shipping first-party app pins it in Package.swift
  and imports it from non-test code — and is therefore NOT experimental-tier eligible.
  ManifoldAppEval adoption is pending.
- The origin app's usage mixes canonical BYO-UI consumption with legacy reach-ins
  (Appendix 2, source-verified).
- **GenerationConfig is DONE:** Option C (runtime-hints extraction) shipped in #2169
  (`feat!`, 2026-07-08) — all six lossy fields moved to `GenerationRuntimeHints`;
  the remaining 25 init params are contract-tier-owned sampler/payload knobs per
  API-DESIGN §2. There is no init-slimming work left. (Follow-up: API-DESIGN.md
  §2 stale future-tense paragraph — fixed alongside this plan.)

---

## Phase A — mechanical demotions (public → package), stable-tier modules only

No behavior change, no consumer breakage by construction, **no companion-visible
items** (so no staged drafts and no companion-compat dispatch in this phase). Ships as
a cluster-batched train after A.0 lands.

Cut from v1 of this plan (review findings): A.6 GenerationConfig slimming (premise
false — #2169 already shipped it) and A.3/A.4 MCP/AppIntents/Skills internals
(~28 types — those modules are experimental-tier candidates in C.1; demoting internals
of modules outside the frozen contract buys nothing for 1.0. Their internals get
demoted as part of each module's graduation work instead — see C.1.)

### A.0 Verification protocol (blocking prerequisite, ships first)

A candidate graduates from "scan says unused" to "demotable" only after:

1. **Source-restricted** word-boundary grep (`rg -w -t swift`) of the type name AND
   its public member names across all six consumer repos. This grep is the PRIMARY
   gate: Swift's access-control checking only backstops in-repo anchoring — MK's own
   build cannot see cross-package consumers, and companion-compat.yml screens only
   mlx/llama (never eval or the first-party apps).
2. Confirmation the type is not a parameter/return/thrown/associated-value type on
   any public signature of a type that IS externally used.
3. Confirmation no doc (docs/*.md, DocC catalogs, README) instructs a consumer to
   construct/conform to it.
4. Schema history is structurally excluded (breaks migration for existing installs).
5. AppIntents-conformant types: check Apple's framework requirements first (N/A now
   that A.4 is cut; retained for graduation-time reuse).

Deliverable: `scripts/api-demotion-screen.sh <TypeName>` encoding steps 1–3; workers
paste its output per candidate in the PR body. Sizing honesty: common member names
(id, name, phase, …) will produce noisy grep output needing hand-adjudication — the
screen over-rejects (safe direction) but this is real per-candidate effort, budget for
it. Each demotion PR ships: regenerated module baseline(s), allowlist entries,
migration note, whole-target gate + audit suites.

### A.1–A.3 Candidate clusters (~85 types; full lists in Appendix 1)

| # | Cluster | ~Types | Notes |
|---|---------|--------|-------|
| A.1 | ManifoldInference internals | ~30 | `InferenceService.respond<T>` structured-output family (7 — verified: no consumer calls it; observed `.respond(` calls in a first-party app are Apple's `LanguageModelSession`); prompt-rendering internals (`RenderedPrompt`, `ResolvedSlot`, `PromptSlotRole` — `GenerationEvent.promptRendered` carries `String`); tool-dispatch plumbing (`ToolOutputPolicy`, `ToolSpillReaper`, `ToolApprovalDecision`, `PreToolUseOutcome`); `WedgeWatchdog` pair; compression cluster (10 — spot-check PromptAssembler's public init first); model-selection surface (4; do NOT touch `ModelFitScorer` — #2128 item) |
| A.2 | ManifoldUI + UIModelManagement internals | ~35 | Per Appendix 1: LinkPreview trio, diagnostics/inspector views, Spotlight/search internals, undocumented subviews and leaked render/error types. `AccessibilityAnnouncer` demotes (stays live for VoiceOver). Verify `APIConfigurationView` composition before demoting endpoint-editor subviews |
| A.3 | Leaf-module internals | ~18 | Hardware no-doc enums (11, individually screened); Contract `StreamTransform`, `SentenceCoalescer`; CloudCore `CacheBreakpointPlan`/`PromptCachePolicy` (verify prompt caching is live first — user-facing cost feature); ModelCatalog `NetworkPolicyGuard`, `DiagnosticsService`; HuggingFace `DiffusionDownloadProgress` |

Concurrency truth: A.1 and A.3-Contract share baselines with each other's modules —
rebase-serialize within clusters; A.2 is self-contained. All items append to the single
`.github/api-breakage-allowlist.txt` — serialize allowlist commits.

## Phase B — seam consolidation (MK-side, additive-first)

The origin app is the sole external consumer of 43 public types, 22 undocumented
(Appendix 2, source-verified). Structure per the scope review: **every B-item lands
its MK-side work additively on MK's own merits and schedule.** The origin app's
migration is a separate upgrade plan in its own private repo (B.0); the contingent
demotions of losing seams land only after that plan executes — and if it stalls, the
fallback is benign (a handful of types stay public into 1.0). **Phase C does not gate
on any of this.**

### B.0 Origin-app upgrade plan (deliverable, not a gate) — DECIDED (B-D1): go

**Corrected by the origin-app-context review (2026-07-13, fix-first) and narrowed by
the app-side plan drafting (2026-07-13, evidence re-verified against the app's current
main — the review had sampled a stale branch):** the app's live generation calls
`inferenceService.enqueue` plus its own streaming runner directly; it never runs
`ConversationTurnExecutor`. The pre-turn half of the adaptation is ALREADY DONE — the
app retired its #1518 prepareTurn workaround upstream and consumes
`TurnContext.appData` through the `ContextBudgetPlanner` planner path today, without
`ConversationRuntime` (MK's planner-path appData handoff exists and is adopted; the
"incremental escape hatch" question is moot). What remains coupled is the
**post-generation half**: `GenerationHook.postGeneration` fires only inside
`ConversationTurnExecutor`, so the hook migration, the extraction observer/token
migration, and the lifecycle-UI migration are consequences of: **precondition — the
app adopts `ConversationRuntime` for generation.** Severability still applies to that
remaining bundle as a whole.

The app-side upgrade plan is drafted (in the app's own private repo, where everything
this document cannot name is named). One requirement the MK side must weigh:
- **Branch-aware turn semantics:** the app persists turns into a branching node tree
  with regeneration-undo. Verify `ConversationRuntime`'s session/message model
  accommodates node-tree branching and partial persistence before committing to the
  re-base — if it cannot, that is an MK parity item, not an app problem.

### B.1 Context-seam ownership resolution (NOT a collapse)

Review finding (API-design, confirmed): `PromptContextProvider`/`ProviderBudget`/
`TurnContext`/`PromptSlot` (Inference tier, prompt-slot assembly) and
`HistoryProvider`/`HistoryContribution` (Runtime tier, message-level history) are
owned by different tiers on different data per API-DESIGN §2 — collapsing them would
invert §2, and a history insertion is not expressible as a prompt slot. The v1 shape
is **both seams stay, with documented ownership**:

- API-DESIGN §2 gains a row: per-turn context contribution — slots are
  contract/assembly-tier property, history contributions are runtime-tier property
  (recorded alongside this plan).
- DocC + AGENTS.md document both seams (today all of it is undocumented public API).
- The genuinely redundant residue is assessed for retirement: `HostTurnContextProvider`
  vs the planner-path appData handoff (the origin app already migrated — its
  prepareTurn workaround is retired upstream and `TurnContext.appData` via
  `ContextBudgetPlanner` is its live path; both mechanisms now have a consumer),
  `SummarisationHook` (folds into B.2), `HistoryShaper` overlap with compression
  policies.

### B.2 One hook system (within the Runtime tier)

Unify `GenerationHook`/`CompletedTurn` and `SummarisationHook` into
`HookRegistry`/`HookEvent` (extend with `postGeneration` etc.). The store post-write
hooks (`MessageStorePostWriteHook`/`SessionStorePostWriteHook`) stay a distinct
persistence-tier seam — B-D2, recommended: they fire on ANY store write (imports,
migrations, sync — not just generation turns), so folding them into a
generation-lifecycle hook system would misstate their trigger semantics and force
persistence adapters to depend on runtime hook machinery, an ownership inversion per
API-DESIGN §2. MK lands the extended HookRegistry additively; `GenerationHook`
retires after the origin app's post-generation extraction migrates.

### B.3 Turn-loop parity (MK-side) + contingent demotions

MK-side parity list, corrected by the origin-app review (the v2 plan named only a
repetition guard — that is largely the one item MK already HAS,
`config.loopDetectionEnabled` in `ConversationTurnExecutor`; what it needs is the
app's detector TUNING exposed, not a new boolean). The real gaps the app's streaming
runner covers that MK does not:

1. **Progress/stall timeout** — the runner cancels on a progress timeout and reports
   a distinct timed-out outcome; MK has no equivalent (no progress/stall monitor in
   Inference or Runtime). Needs a `TurnConfig`/`ConversationRuntime` knob and a
   timeout signal in the event/outcome surface.
2. **Thinking-block parity** — the app strips inline `<think>…</think>` from raw
   text tokens; MK relies on backends emitting structured `.thinkingToken` events.
   For local/Ollama reasoning models that emit `<think>` as plain text, a re-base
   could leak reasoning markup into user-visible output. Verify against the shipped
   local backends, or add inline-marker filtering to the turn executor.
3. **Outcome taxonomy** — the app's five-value generation-outcome enum (including
   timed-out and cancelled-empty) must be reconstructable from MK's events; today it
   is not.
4. Repetition-guard tuning exposure (thresholds, not just on/off).

App-side (in the B.0 upgrade plan): re-base generation on `ConversationRuntime`, AND
migrate the LIVE extraction path — a turn-observer driven by
`InferenceService.GenerationRequestToken`, which the app's memory package threads
through its own public API across 6+ files — onto the hook/appData path. Note: the
app's `GenerationHook` adapter is test-only today, NOT the live path (origin-app
review); the token demotion is tied to migrating the observer path.
`GenerationRequestToken`, `RepetitionDetector`, `AssembledPrompt` demote only after
all of the above; otherwise they ride into 1.0 public (accepted fallback).

### B.4 One lifecycle signal

Three overlapping signals: `BackendActivityPhase` (rendered by the origin app's input
bar), `GenerationStream.phase` (#2128: emitted, nothing renders),
`ModelLoadReadinessState` (warmup UI). MK decides the keeper (lean:
`GenerationStream.phase` for generation lifecycle + a model-load event stream for
load lifecycle) and documents it; the app migrates via B.0; losers demote after.
Resolves the #2128 `.phase` item with a consumer instead of a cut.

### B.5 #2128 adjudication — origin-app-informed subset only

Only the items where the new consumer evidence changes the answer (the rest of #2128
adjudicates as posted and rides whatever minor is next, outside this plan):

- `SettingsService` — #2128 says "never written, resolvers never called"; the origin
  app injects `SettingsService.shared` into its main store (3 injection sites,
  source-verified). Likely flips cut → keep-and-document.
  **Third disposition option recorded (2026-07-21 inert-surface sweep, #2128):**
  keep-and-demote-to-package. The "3 injection sites" evidence above is
  external-only (the origin app); independent of any external app,
  `GenerationSettingsView` (`ManifoldUI`) is a live **in-package** consumer —
  it reads/writes `SettingsService.shared.appearanceMode` directly, is wired
  into `ChatShellViews`, and is snapshot-tested
  (`Tests/ManifoldSnapshotTests/ModelAndSettingsControlTests.swift`,
  `ChatViewControlTests.swift`). Whether that in-package consumer alone
  justifies staying `public` (a companion/consumer app could still want to
  read `SettingsService` directly, the way the origin app does today) or
  whether `package` is sufficient once the origin app's injection sites
  migrate onto a public seam `ManifoldUI` already exposes is the open
  question this disposition leaves for adjudication. **Demotion is gated on
  the origin app's `SettingsService.shared` injection-site migration landing
  first** — do not demote while an external consumer still constructs/reads
  it directly.
- `AssembledPrompt`/`MessageRole` — **severed from any demotion** (origin-app
  review): the app's eval package uses `PromptAssembler`/`AssembledPrompt`/
  `MessageRole` to reproduce its production prompt-assembly and compression semantics
  across five backends for golden baselines; ManifoldAppEval is itself unadopted
  (experimental tier) and unproven for that job. These types stay public until
  ManifoldAppEval demonstrably reproduces the golden assembly — that migration is a
  graduation test FOR AppEval, not a debt the consumer owes MK.
- Reliability wrappers (`FallbackBackend`, `RouterBackend`, `RetryStrategy` + 4) —
  not on #2128 today; add and adjudicate: wire-and-document or demote (zero adopters,
  zero docs, well-tested).
- `BackgroundTaskScheduler` seam (4 types) — own DocC article, zero production
  instantiation, only conformer besides the default is a test mock (reviewer-verified).
  Principle 10: recommendation **delete**.

## Phase C — experimental tier + seal (absorbs #2156)

### C.1 Experimental-tier declaration

Modules with zero real adopters do not enter the 1.0 stability promise. Roster
(C-D1, decided): **ManifoldMCP, ManifoldMCPHost, ManifoldSkills, ManifoldAppIntents,
ManifoldAnyLanguageModel, ManifoldTelemetryOTLP, ManifoldAppEval** (7 — ManifoldVoice
is OUT: a shipping first-party app pins and imports it, which meets the graduation
bar). Mechanics — extends the API-DESIGN §7 semver-exempt precedent (§7b, recorded
alongside this plan):

- New §7b in API-DESIGN.md: "experimental products — may break in any minor, always
  migration-noted; graduate on first real adopter." **Adopter = a shipping app or
  companion that pins the product AND imports it from non-test code**, verified by
  grep — docs and examples are not adoption.
- **Forcing function (scope-review finding): experimental is not a parking lot.**
  Each module carries a named decision point — at 1.0+2 minors or the module's listed
  milestone, whichever first, it either graduates (has an adopter) or gets a
  wire-or-delete adjudication like any other inert surface. AppEval's milestone is
  its pending first-party adoption waves; MCP's is a consumer app built AND tested
  against it (C-D1, decided — docs are not adoption).
- Graduation work includes the module's internals demotion pass (the deferred lists
  in Appendix 1 are the pre-computed starting point).
- AGENTS.md Part 1 product table gains an **Experimental** marker; each module's DocC
  landing page states it. The api-surface baseline still tracks experimental modules
  (drift stays visible); the C.2 freeze discipline applies only to stable-tier
  modules.

### C.2 Seal (from #2156, updated — future work)

**Prerequisite.** First clear, or explicitly demote the affected
current-release claim for, every Tier 1/2 blocker in the
[release-health ledger](../RELEASE-1.0.md#release-health--qualification-ledger).
A decided #2211 policy or a tier table is not C.2 evidence.

1. Freeze the surface baseline at the post-Phase-A/B surface for **stable-tier**
   modules. Honest framing: the baseline is a drift-gate — growth forces an
   intentional same-PR baseline edit plus the AGENTS.md-cited justification; the gate
   makes growth visible and deliberate, it does not mechanically block it.
2. DX walkthrough re-run against the release.
3. Docs sweep: AGENTS.md target tables, MIGRATION notes (one per breaking item),
   companion release-notes capability lines, retire wave-2 plan references, record
   the B.1 ownership row and §7b (shipped with this plan's PR).
4. Declare 1.0-rc posture for the stable tier: Contract, Inference, Runtime,
   PersistenceSwiftData, backend families (Foundation/Ollama/CloudSaaS/CloudCore),
   Hardware, ModelCatalog, Networking, Secrets, UI, UIModelManagement, HuggingFace,
   Voice, umbrella. (Test-support products and ManifoldTools stay §7 semver-exempt.)

## Decisions (Rory)

- **C-D1 — DECIDED (2026-07-13): ManifoldMCP is experimental.** Docs are not
  adoption — MCP graduates only when a consumer app has been built AND tested against
  it. The stable-on-docs argument (scope review) is rejected; the tier is about
  validation. Roster stands as listed in C.1.
- **C-D2 — DECIDED (2026-07-13): export/import surface stays public** (15 types —
  coherent, live, documented). Revisit at 1.0-rc if still unadopted.
- **B-D1 — DECIDED (2026-07-13): go.** A worker drafts the origin app's upgrade plan
  in its own private repo once this plan merges, structured per B.0 (precondition +
  consequences, MK parity list from B.3).
- **B-D2 — RECOMMENDED: store post-write hooks stay a distinct persistence-tier
  seam** (rationale in B.2).

## Orchestration & routing

- Phase A: sonnet workers, one PR per cluster (A.1/A.2/A.3), draft-PR review loop,
  merge queue; A.0's screen script ships first, output pasted per candidate. No
  companion drafts, no compat dispatch needed.
- Phase B: MK-side items are normal MK PRs (sonnet, opus review; B.3 MK-side is
  small). The B.0 upgrade plan is drafted by one opus worker in the app's own repo
  (private — follow that repo's conventions) and handed to Rory for scheduling.
- Phase C: orchestrator + one sonnet docs worker.
- Gates: per-item whole-target + audit suites; `scripts/demo-apps-build.sh` blocking
  pre-release; ONE release at the end of Phase A and ONE after MK-side Phase B
  (changelog rewritten post-last-merge, Prisma Highlights).
- Decoupled stream (carried from wave-2 0.G): local-app migration sweep — the three
  older local apps still carry retired-shim refs; 3× sonnet, app-repo worktrees,
  non-gating.

## Risks

- **Scan false negatives/noise** → A.0 source-restricted per-type screen is the
  primary gate; compiler backstops in-repo anchoring only; staged review of grep
  output per candidate.
- **Origin-app migration stalls** → all demotions contingent on it are severable;
  MK-side work stands alone; Phase C unaffected.
- **Unknown external consumers** (public repo) → pre-1.0 policy + migration notes;
  the experimental tier reduces this risk class going forward.
- **Baseline/allowlist churn across parallel sessions** → rebase-serialize within
  clusters; single-allowlist commits serialized.

## Appendix 1 — Phase A candidate lists (2026-07-13 classification; ~40 sampled and
source-verified clean by the API-design review)

**A.1 ManifoldInference:** StructuredOutput, StructuredOutputError,
StructuredOutputSchema, SchemaProviding, ReaskPolicy, GBNFSchemaPreValidator,
JSONSchemaValidating; RenderedPrompt, ResolvedSlot, PromptSlotRole; ToolOutputPolicy,
ToolSpillReaper, ToolApprovalDecision, PreToolUseOutcome; WedgeWatchdog,
RealWedgeWatchdog; TurnHistoryCompressor, BudgetTurnHistoryCompressor,
NoOpTurnHistoryCompressor, BudgetPolicy, CompactionTrigger, CompressedTranscript,
ContextBudget, TurnHistoryRecord, DialogueSummariser, DefaultDialogueSummariser,
NoOpDialogueSummariser; ModelSelecting, ScoredModel, ModelSelectionGroup,
ModelSelectionSortOrder. (Second-pass pool, screen individually: ModelLoadStatus,
ExecutorState, LoadIntent, MessageKind, MessageStatus, OversizeAction, PartialSnapshot,
PostGenerationTask, ProbeResult, HuggingFaceProbe, MarkdownRendering,
CompositeURLSessionDelegate, RedirectGuardDelegate, ModelExecutorKey.)

**A.2 ManifoldUI:** LinkPreviewDetector, LinkPreviewMetadata, LinkPreviewRenderPhase,
DiagnosticsView, DiagnosticsDisclosure, PromptInspectorView, SpotlightIndexer,
SessionSearchScope, AccessibilityAnnouncer, GenerativeContextMenuItems,
MessageActionMenuModifier, ChatMessageRenderParameters, HandoffChipView,
IngestionIntent, ChatExporterError, SessionExportFormatOption, ToolErrorPresentation.
**ManifoldUIModelManagement:** APIEndpointEditorView, APIEndpointRow,
RemoteServerConfigSheet, DocumentLibraryView, DiffusionModelCatalogEntry,
ImageModelManagementSheet, DownloadProgressView, DownloadableModelRow,
StorageManagementView, WhyDownloadView, ModelPicker, ModelImportError.

**A.3:** Hardware: CancellationStyle, CategorizedError, ChatTemplateIntegritySidecar,
ContentFilteringDisclosure, DeviceCapability, DownloadedModelPackageManifest,
InferenceErrorCategory, LocalModelDescriptor, ModelPackageKind, ModelUseCase,
UnloadReason. Contract: StreamTransform, SentenceCoalescer. CloudCore:
CacheBreakpointPlan, PromptCachePolicy (verify live first). ModelCatalog:
NetworkPolicyGuard, DiagnosticsService. HuggingFace: DiffusionDownloadProgress.

**Deferred to experimental-module graduation (cut from Phase A by review):**
ManifoldMCP internals — AuthRetryDecision, MCPAuthorizationDescriptor, MCPCapabilities,
MCPClientConfiguration, MCPDisconnectReason, MCPKeychainConfiguration,
MCPLifecycleEvent, MCPLifecycleEventObserver, MCPNetworkPathObserver,
MCPNetworkPathStatus, MCPNotificationLifecycleEventObserver, MCPOAuthRedirectListener,
MCPOAuthTokens, MCPSessionLifecyclePolicy, MCPStdioCommand, MCPToolCountView,
MCPTransportKind. ManifoldAppIntents (gated on Apple-framework check) —
AppEntityResolver, AppIntentApprovalPolicy, CodingUserInfoKey,
DefaultAppEntityResolver, DiscoverableAppIntent, IntentEnumParameter,
IntentProgressReporter, ProgressReportingAppIntent, ResolvedEntityBox.
ManifoldSkills — AgentInstruction, AgentInstructionContextProvider,
AgentInstructionLoader, SkillDispatchError, SkillReferenceError.

**Explicitly NOT candidates** (KEEP or already-tracked): tracing/telemetry seam
(anchored by `SSECloudBackend.traceSink` + ManifoldTelemetryOTLP); media-gen spine
(deliberate new scaffolding, PR #2219 — experimental posture instead); GGUF
signed-manifest + StructuredOutputRouter (documented, seam-decision); CloudCore
transports/finalizers/security delegates; schema versions; backend-family adapters;
ManifoldKit umbrella types; MCPHost module (small, coherent, documented).

## Appendix 2 — origin-app-only public types (43) and adaptation paths

**No docs/example refs (22) — public purely as spin-out residue:**

| Type(s) | Origin-app use | v1 path |
|---|---|---|
| PromptContextProvider, ProviderBudget, TurnContext, PromptSlotPosition (+PromptSlot, docs'd) | memory-pipeline context providers; consumes `TurnContext.appData` via the planner path (its former #1518 workaround is already retired upstream) | B.1 — seam stays (Inference-tier owner); no migration pending |
| ContextBudgetPlanner, ContextBudgetEntry, PromptContextPipeline | budget-weighted context assembly | B.1 — stay public, gain docs |
| HistoryProvider, HistoryContribution, HistoryInsertionPosition | memory-brief history provider | B.1 — stays (Runtime-tier owner), gains docs |
| GenerationHook, CompletedTurn | post-generation extraction adapter — TEST-ONLY today; the live extraction path is a turn-observer via GenerationRequestToken (origin-app review) | B.2 — hook seam is staged/not-live; retires after the observer path migrates (B.3) |
| GenerationRequestToken, RepetitionDetector | hand-rolled streaming runner (bypassed turn loop); token threaded through the memory package's public API driving LIVE extraction | B.3 — MK parity (timeout, thinking-filter, outcome taxonomy, tuning) + B.0 re-base + observer-path migration, then demote (severable as a whole) |
| AssembledPrompt (+MessageRole) | eval package reproduces production prompt assembly for golden baselines | stays public — severed from demotion until ManifoldAppEval reproduces the golden assembly (B.5) |
| BackendActivityPhase, ModelLoadReadinessState | input-bar progress; model warmup UI | B.4 — one lifecycle signal |
| SettingsService (docs'd) | main-store dependency (`.shared`, 3 injection sites) | B.5 — re-adjudicate #2128 item with this evidence. Third option recorded 2026-07-21: keep-and-demote-to-package, since `GenerationSettingsView` (`ManifoldUI`, wired into `ChatShellViews`, snapshot-tested) is a live in-package consumer independent of the origin app's 3 injection sites. Demotion gated on the origin app's injection sites migrating first — not yet landed. |
| GenerationParameter | settings-sheet capability check | keep or fold into BackendCapabilities (B.5) |
| MemoryPressureEvent | memory-pressure handling in the main store | legit host concern — keep, document |
| ManifoldSchemaV4, ManifoldSchemaV5 | test comments only | no action |
| EndpointBackendKeychainConfigurable, EndpointBackendURLModelConfigurable | eval benchmark runtime conformance | screen in B.5 (may migrate with AppEval move) |

**Docs-referenced origin-app-only types (21):** canonical toolkit surface
(APIEndpointRecord, ConversationRuntime, ClaudeBackend, OpenAIBackend,
CloudSaaSBackends, OllamaBackends, SSECloudBackend, TokenProvider, APIProvider,
APIConfigurationView, ContextIndicatorView, KeychainService, MockBenchmarkRunner,
ModelContainerFactory, SwiftDataPersistenceProvider, ManifoldSchemaV9,
NLEmbeddingBackend, PromptSlot, …) — no action beyond Phase C tiering.

## Review record (2026-07-13; three adversarial personas + one origin-app-context
review, all fix-first; v1 → v4)

- **Feasibility/release-engineering:** (1) CONFIRMED A.6's premise false — Option C
  shipped in #2169; A.6 CUT, ground truth corrected, API-DESIGN stale paragraph fixed
  alongside this plan. (2) CONFIRMED B.3 demotion under-scoped — the origin app's
  memory package threads GenerationRequestToken through its own public API across 6+
  files; re-base is necessary-not-sufficient; B.3 rewritten. (3) CONFIRMED compiler
  backstop is in-repo-only; A.0 reworded — six-repo source grep is the primary gate.
  (4) A.0 member-grep noise sizing note added.
- **API-design/consumer-advocate:** (1) CONFIRMED A.6 violated Phase A's no-breakage
  invariant (moot — cut). (2) CONFIRMED Voice roster contradiction — a shipping
  first-party app pins + imports it; Voice moved to stable tier and the adopter
  definition tightened (pin + non-test import, grep-verified). (3) CONFIRMED B.1
  "one seam" would invert API-DESIGN §2 — reframed to ownership resolution, both
  seams stay documented. (4) CONFIRMED the scan counted a consumer repo's build-log
  noise — ground truth corrected, A.0 mandates `-t swift`. (5) C.2 "ratchet" reworded
  to drift-gate. Sampled ~40 demotion candidates across clusters: all safe.
- **Root-cause/scope skeptic:** (1) CONFIRMED regrowth barrier is now LIVE — stated,
  with the honest drift-gate caveat. (2) CONFIRMED A.3/A.4 double-spend vs Phase C —
  CUT from Phase A, folded into graduation work. (3) CONFIRMED wave-2 0.G would be
  orphaned — carried forward explicitly. (4) CONFIRMED Phase B coupled the seal to a
  consumer app's refactor — restructured: MK-side additive, app migration in its own
  plan (B.0), demotions contingent, Phase C independent. (5) Forcing function added
  to the experimental tier (graduate-or-delete decision points). (6) Payoff framing
  corrected to "smaller frozen contract," not compile time.
- **Origin-app-context review:** (1) CONFIRMED the B.0 items all gate on the app
  adopting ConversationRuntime — the replacement seams (`HostTurnContextProvider`,
  `GenerationHook`) only fire inside `ConversationTurnExecutor`, a path the app's
  live generation never runs; B.0 restructured as precondition + consequences,
  severable only as a whole. (2) CONFIRMED B.3's MK parity list was wrong: loop
  detection largely exists (`loopDetectionEnabled`) while the real gaps are
  progress/stall timeout, inline-`<think>` filtering parity, a reconstructable
  outcome taxonomy, and repetition tuning exposure — B.3 rewritten. (3) CONFIRMED
  the app's `GenerationHook` adapter is test-only; live extraction is a turn-observer
  via `GenerationRequestToken` — Appendix 2 corrected, token demotion tied to the
  observer-path migration. (4) CONFIRMED the app's eval package reproduces production
  assembly for golden baselines and ManifoldAppEval is unproven for that job —
  severed from demotion; reframed as an AppEval graduation test. (5) The app wants:
  an incremental appData handoff on the planner path, repetition tuning knobs, and
  branch-aware turn semantics verified before the re-base — recorded in B.0.
- **App-side plan drafting (post-merge correction, 2026-07-13):** the review's
  evidence had been sampled from a branch behind the app's main. Re-verified against
  current main: the #1518 prepareTurn workaround is ALREADY retired and the planner-
  path `TurnContext.appData` handoff is the app's live mechanism — B.0's pre-turn
  consequence was done, not pending, and only the post-generation bundle remains
  coupled to ConversationRuntime adoption (B.0/B.1/Appendix 2 corrected). Also
  clarified: the app's five-value outcome enum is completed / cancelled-by-user /
  timed-out / looped / interrupted (cancelled-empty is a derived telemetry string),
  and MK's structured thinking events exist — the B.3 parity risk narrows to
  verifying which shipped local backends emit `<think>` as plain `.token` text.

## Addendum — Runtime residual sweep (2026-07-15)

**Origin:** a post-Phase-A opus review (2026-07-15, all six consumer repos
grepped with `rg -w -t swift`) found that Phase A's clusters (A.1 Inference,
A.2 UI, A.3 leaves) never swept **ManifoldRuntime** or
**ManifoldPersistenceSwiftData**. All new findings live there. Everything else
came back clean: recent feature PRs (#2237–#2259) are live+wired+documented
with no over-exposure; no member-level demotions are mechanically safe
(view-model members can't be trusted to name-grep under SwiftUI dynamic
dispatch); no baseline drift. The addendum was adversarially reviewed once
(opus, FIX-FIRST — all six findings folded; see Review record below), then
all decision items were **decided by Rory on 2026-07-15**.

Thesis unchanged from the parent plan: the cheapest time to shrink the public
API is before the 1.0 freeze, and `package → public` re-promotion post-1.0 is
additive/non-breaking while the reverse is a major — bias toward demote now,
re-promote on first adopter. The review added a corollary: a demotion of a
*documented* surface must carry its doc rewrite in the same PR (a banner over
an impossible recipe is a documented lie; `no-build` fences dodge the
snippet-compile gate, so the doc has to actually change).

### D.1 — Mechanical demotions (landed via this PR)

Zero external refs, zero docs, not on any public signature, re-verified with
corrected consumer-repo paths:

- `BM25Scorer` (`ManifoldRuntime/Services/BM25Scorer.swift`) — only consumer
  is `FlatFileVectorStore` (`ManifoldPersistenceSwiftData`, same SwiftPM
  package — `package` visibility crosses that module boundary fine).
- `ReciprocalRankFusion` (`ManifoldRuntime/Services/ReciprocalRankFusion.swift`)
  — only consumer is `RAGService.retrieve`.

Also bundled: fixed `scripts/api-demotion-screen.sh`'s consumer-repo defaults
(they didn't match this machine's layout, so every screen run WARN-skipped
all six repos and returned a vacuous PASS) and made it hard-fail when a
consumer repo root is missing instead of silently skipping it.

### D.6 — HostTurnContextProvider — DECIDED: demote to `package`

Not a mechanical delete: live-wired (`ConversationTurnExecutor.swift:1441-1442`
calls `appData(for:)` on the real turn path), a public param on three
`ConversationRuntime.init` overloads plus a public `ConversationRuntimeOptions`
property, behaviorally tested, and DocC-documented with a conformance
walkthrough. Zero external adopters (the origin app's live mechanism is the
planner-path `appData` handoff, not this protocol). Decision: demote the
protocol, the three init params, and the options property to `package`;
rewrite `ContributingConversationHistory.md` and the `ManifoldRuntime.md`
symbol link to drop the host-conformance walkthrough, carry the api-digester
allowlist entry for the public-init-signature change, and a migration note
pointing at the planner-path `TurnContext.appData` replacement. Own PR,
rebase-serialized on the shared `ManifoldRuntime` baseline.

### D.2 — Agentic Run subsystem — DECIDED: demote the whole surface to `package`

Full surface: ~10 public types (`ConversationRun`, `RunEvent`, `RunStatus`,
`RunStep`, `RunStore`, `RunStoreError`, `RunInputProvider`,
`FixedGoalRunInputProvider`, `ResumableRunDriver`, `SwiftDataRunStore`), 4
`ConversationRuntime` methods (`startRun`/`resumeRun`/`pauseActiveRun`/
`cancelActiveRun`), the `enableResumableRuns: Bool = false` params on public
`ManifoldBootstrap` init signatures, and the public property
`ManifoldBootstrap.runStore: SwiftDataRunStore?`. Wired and test-exercised,
not #2261-shaped dead code — but zero adopters and about to freeze silently
into the stable-tier 1.0 contract. `SwiftDataRunStore`'s `@Model` rows live in
frozen `ManifoldSchemaV10`; demotion preserves migration integrity but leaves
a permanently-dormant public schema version no host can exercise while the
flag is `package` — accepted and stated, not hidden. `RunStore` is removed
from the persistence-ports KEEP list (it backs only the Run subsystem, unlike
the conscious-KEEP ports which back live adopted features) and follows this
decision. Own `refactor(runtime)!` PR, same gates, shared baseline
(rebase-serialize).

### D.3 — ConversationRuntimeBackgroundBridge + ManifoldBackgroundTaskIdentifiers — DECIDED: demote to `package`

Documented (`BackgroundTaskSupport.md` instructs host construction), but
constructed only in tests/docs — zero adopters across all six consumer repos.
Same shape as the #2261 BackgroundTaskScheduler removal, but the host-side
companion to #1713's BGContinuedProcessingTask support. Decision: demote to
`package` and rewrite `BackgroundTaskSupport.md` from a host-recipe to an
internal-seam note in the same PR (the article's fences are `swift,no-build`,
so the snippet-compile gate would not catch a recipe for a now-unconstructable
type). A `package`-visibility host-facing seam is functionally unavailable to
hosts — deliberate: unadopted host seams should not be frozen speculatively.
Rides the D.2 PR (same module, same doc-and-baseline gates).

### D.4 — AccessibilityAnnouncer — DECIDED: wire it internally and demote to `package`

Kept public by #2254 with an explicit "human call" flag: zero call sites
in-repo (only a `// should drive` comment), zero adopters across all six
repos, but a `## How to use it` doc describing direct host construction —
currently lying twice (unwired code, and host-facing docs for a seam nothing
validates). Decision: wire it internally (`ChatView` drives VoiceOver
announcements from the real streaming-completion path) and demote to
`package` in the same PR, rewriting its host-facing doc to match. This is
honest feature work (correct lifecycle from the streaming path,
completion-reason mapping, rate-limiting, plus an a11y behavior test — the
`post` seam is injectable, so testable), not a trivial wire-up: ships as
`feat(ui):` + demotion in one PR. Not release-gating; can follow the sweep at
its own pace.

### D.5 — Release sequencing (corrected by review)

**The sweep does not gate release 0.72.0.** The shrinkage only needs to
precede the **C.2 seal (#2156)** — the baseline freeze — not the release
closeout. 0.72.0 (#2260) closes out on its own timeline, independent of this
sweep. D.1 → D.6 → D.2(+D.3) land next, rebase-serialized on the shared
`ManifoldRuntime` baseline (single-allowlist commits), riding whatever
release train is open when they merge (`bump-minor-pre-major: true` keeps any
`refactor!` a minor bump). **The C.2 seal runs only after the sweep lands**,
so the frozen stable-tier baseline includes this shrinkage — that ordering is
the one hard dependency. D.4 is fully decoupled.

### Out of scope

#2208 enum-growth sweep (shape hygiene, scheduled separately); the
single-conformer persistence ports backing live adopted features (PersonaStore,
UsageStore, BenchmarkCache, WebSearchRuntime, TransactionalMessageStore —
conscious KEEP, `RunStore` removed per D.2 above); Appendix-2 origin-app
contingent demotions (still gated on the private B.0 migration); member-level
view-model demotions (no mechanically safe candidates, revisit only with
adopter telemetry).

### Review record (2026-07-15, one adversarial opus review — FIX-FIRST, all folded)

- **F1 CONFIRMED (blocker):** HostTurnContextProvider is live-wired, on 3
  public init overloads + an options property, tested, and DocC-documented
  with a conformance walkthrough → pulled out of mechanical D.1 into decision
  item D.6.
- **F2 CONFIRMED (blocker):** RunStore appeared in both D.2's demote set and
  the persistence-ports KEEP list → resolved: keep-list ports back live
  adopted features, RunStore has no life outside the Run subsystem.
- **F3 CONFIRMED:** D.2's surface list understated the bootstrap-init impact
  (missed the public `ManifoldBootstrap.runStore` property); dormant-schema
  consequence now stated.
- **F4 CONFIRMED:** D.3's "demote + banner over the DocC recipe" was
  doc-incoherent (`swift,no-build` fences dodge the snippet gate) → article
  rewrite bound into the same PR, banner option removed.
- **F5 CONFIRMED:** `api-demotion-screen.sh` default consumer paths didn't
  match this machine → vacuous PASSes; BM25Scorer/ReciprocalRankFusion
  re-verified genuinely clean with corrected paths across all six repos;
  script hard-fail fix bundled into D.1.
- **F6 CONFIRMED:** sweep decoupled from the 0.72.0 release — only the C.2
  seal depends on it.
- **F7 PLAUSIBLE:** D.4 sizing corrected from "small feature work" to honest
  feature work with lifecycle/rate-limit/test scope.
- Positive confirmations: zero-adopter claims for Run subsystem, bridge, and
  AccessibilityAnnouncer verified across all six consumer repos; BM25/RRF
  anchoring and cross-module `package` visibility sound; release-train math
  right.
