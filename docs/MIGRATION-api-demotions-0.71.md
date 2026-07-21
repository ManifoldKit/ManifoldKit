# Migration: Phase A API demotions (0.71)

**Audience:** consumer
**Status:** historical

Part of the [v1 rationalisation plan](plans/api-v1-rationalisation-2026-07.md) — Phase
A mechanically demotes undocumented, zero-consumer internals from `public` to
`package` visibility. `package` types are not part of the public SwiftPM contract:
code outside this package can no longer import or reference them. No behavior change;
this is a pure visibility reduction.

If your app or companion package references any of the symbols below directly, pin to
an earlier ManifoldKit version or open an issue — none were used by any of the six
surveyed consumer repos (three first-party apps, manifold-mlx, manifold-llama,
manifold-eval) or documented anywhere in `docs/`, `README.md`, or a DocC catalog as of
2026-07-13.

## A.2 — ManifoldUI + ManifoldUIModelManagement

**ManifoldUI:**

- `LinkPreviewDetector`
- `LinkPreviewRenderPhase`
- `PromptInspectorView` (and its `samplePrompt` preview helper)
- `HandoffChipView`
- `MessageActionMenuModifier` — hosts should use the `View.messageActionMenu(message:viewModel:)` / `View.messageActionMenu(message:viewModel:contextMenuItems:)` extension methods, which remain public and return an opaque `some View`; they never required constructing the modifier type directly.
- `SessionExportFormatOption`

**ManifoldUIModelManagement:**

- `APIEndpointEditorView`
- `APIEndpointRow`
- `DownloadProgressView`
- `DownloadableModelRow`
- `WhyDownloadView`

All of the above are internal implementation detail of `APIConfigurationView`,
`GenerationSettingsView`, `ChatHistoryView`, `SessionExportSheet`, or
`HuggingFaceBrowserView` — composed only inside this package, never a parameter,
return, or thrown type on another public API's signature.

### A.2 candidates that were screened but rejected (stayed public)

The A.0 verification screen (`scripts/api-demotion-screen.sh`) flagged these as
`NEEDS-HAND-ADJUDICATION`; hand adjudication found each one either documented,
composed by a live public seam, or would break another public declaration's
signature if demoted. Recorded here so the next pass over Appendix 1 doesn't
re-propose them without re-deriving the same reasoning:

- `LinkPreviewMetadata` — return type of the public `LinkPreviewProvider` typealias,
  itself a public init parameter on `ChatView` and `MessageBubbleView`.
- `SessionSearchScope` — type of the public, settable `SessionManagerViewModel.searchScope` property.
- `ToolErrorPresentation` — its nested `ReauthenticationCTA` is the parameter type of `ToolInvocationView.onReauthenticate`, a public closure property.
- `ChatMessageRenderParameters`, `GenerativeContextMenuItems`, `SpotlightIndexer` — each documented with a runnable usage example in a `ManifoldUI.docc` article (`Theming.md`, `GenerationComponents.md`).
- `AccessibilityAnnouncer` — **resolved, see "D.4 — AccessibilityAnnouncer" below.** This entry originally flagged it `NEEDS-HAND-ADJUDICATION` for carrying a `## How to use it` runnable example despite zero in-repo call sites; Rory's decision (2026-07-15, residual sweep D.4) was wire-and-demote, landed in a follow-up PR, not this one.
- `ModelPicker` — documented in its own DocC article (`ModelPickerSample.md`) as "a thin, public **sample**" with runnable usage.
- `RemoteServerConfigSheet` — carries its own `## Usage` runnable example; not composed by `APIConfigurationView` or anything else in-repo.
- `StorageManagementView` — canonical + `@available(*, deprecated)` legacy init, i.e. a real historical external API contract; not composed by `ModelManagementSheet` (which uses the separate `LocalModelStorageView`).
- `ImageModelManagementSheet` — documented as "Sibling to `ModelManagementSheet` for text models," a standalone host-facing sheet.
- `DocumentLibraryView` — documented as embeddable directly by host apps ("present it as a sheet... or embed it in a settings tab"), a second usage path alongside `DocumentLibrarySheet`.
- `DiffusionModelCatalogEntry` — parameter type of the public `ImageModelInstallView.init(catalog:)`, which is not itself a demotion candidate.
- `ModelImportError` — thrown type of the public `ModelManagementViewModel.importModel(from:)`.
- `ChatExporterError` — thrown type of the public `ChatExporter.exportFile(...)`.
- `IngestionIntent` — parameter type of the public `ChatViewModel.ingestPendingPayload(_:intent:)`.

### Tooling fix bundled in this PR

`scripts/api-demotion-screen.sh`'s Step 3 DocC-catalog glob (`*.docc/**`) never
matched — ripgrep needs `**/*.docc/**` to catch a `.docc` catalog nested under
`Sources/<Module>/`. Every prior screen run (including this one, initially) silently
reported "clean: no docs/README/DocC hits" even when a candidate had a full DocC
article. Fixed; re-running the screen for `ModelPicker`, `ChatMessageRenderParameters`,
`GenerativeContextMenuItems`, and `SpotlightIndexer` after the fix produced a `FAIL`
each. Other Phase A clusters should re-screen anything they already marked
`NEEDS-HAND-ADJUDICATION` or `PASS` before this fix landed.

## D.1 — Runtime residual sweep (ManifoldRuntime, 2026-07-15)

Part of the [v1 rationalisation plan's residual-sweep addendum](plans/api-v1-rationalisation-2026-07.md#addendum--runtime-residual-sweep-2026-07-15)
— Phase A's clusters (A.1/A.2/A.3 below) never swept `ManifoldRuntime` or
`ManifoldPersistenceSwiftData`; this section (and the D.6/D.2/D.3 sections
follow-up sweep PRs append below it) covers what that pass found there. Same
contract as Phase A: `package` types are not part of the public SwiftPM
surface, and no behavior changed — pure visibility reduction.

- `BM25Scorer` (`ManifoldRuntime/Services/BM25Scorer.swift`, plus its nested
  `Document` type, `defaultK1`/`defaultB` constants, `init`, and `score`) —
  only consumer is `FlatFileVectorStore` in `ManifoldPersistenceSwiftData`
  (a different target, same SwiftPM package — `package` visibility crosses
  that boundary fine).
- `ReciprocalRankFusion` (`ManifoldRuntime/Services/ReciprocalRankFusion.swift`,
  plus `defaultK` and `fuse`) — only consumer is `RAGService.retrieve`.

Verified clean via `scripts/api-demotion-screen.sh` against the real six
consumer repos (three first-party apps + manifold-mlx + manifold-llama +
manifold-eval); the script's default consumer-repo paths were also fixed in
this PR (they didn't match this machine's layout, so every prior screen run
WARN-skipped all six repos and returned a vacuous PASS — the script now
hard-fails on a missing consumer repo root instead of silently skipping it,
unless `MK_ALLOW_MISSING_CONSUMERS=1` is set).

## D.6 — HostTurnContextProvider (ManifoldRuntime, 2026-07-15)

Unlike D.1, this is not a mechanical zero-consumer demotion: `HostTurnContextProvider`
was live-wired (`ConversationTurnExecutor` still calls `appData(for:)` on the real turn
path) and DocC-documented with a host-conformance walkthrough, but had zero external
adopters across all six consumer repos — the origin app's live per-turn-data mechanism
is the `turnContextProvider` planner-path handoff below, not this protocol. Decided by
Rory 2026-07-15 (see [the plan's D.6 entry](plans/api-v1-rationalisation-2026-07.md#d6--hostturncontextprovider--decided-demote-to-package)):
demote, not delete — the framework keeps using it internally.

**What moved to `package`:**

- `HostTurnContextProvider` (protocol) and its `appData(for:)` requirement
  (`Sources/ManifoldRuntime/Protocols/HostTurnContextProvider.swift`).
- `ConversationRuntimeOptions.hostTurnContextProvider` — the property is no longer
  settable from a public initializer; only `ManifoldBootstrap` (same SwiftPM package)
  reads it.
- The `hostTurnContextProvider:` parameter on `ConversationRuntime`'s public
  convenience initializer — removed outright, not just retyped. The old 18-parameter
  public initializer split into two: a slimmer public initializer without the
  parameter, and a `package`-visible sibling that still accepts it (used by
  `ManifoldBootstrap` and test targets in this package). The `package` overload makes
  `hostTurnContextProvider` a *required* parameter (no default) specifically so it can
  never become ambiguous with the public overload at a call site that omits the label
  entirely — omitting the label always resolves to the public initializer; supplying it
  always resolves to the `package` one.

**What did not move:** `TurnContextBuildRequest` stays `public` — it is also the type
of `HistoryShaper`'s `turnContextRequest` property, a still-public, still-adopted seam.

**Replacement for hosts:** the `turnContextProvider: (@Sendable (UUID) -> (any
Sendable)?)?` closure parameter on `ConversationRuntime`'s public initializer is
unaffected and remains the supported way to seed `TurnContext.appData` — the "planner
path" referenced above and in `Sources/ManifoldRuntime/ManifoldRuntime.docc/Articles/ContributingConversationHistory.md`.
It's synchronous and session-ID-only rather than `HostTurnContextProvider`'s
async/throwing, full-request-metadata shape; hosts that need throwing/async
resolution should resolve it ahead of the turn and capture the result in the closure,
or read host state from inside a `HistoryProvider`/`PromptContextProvider`
conformance instead.

**Digester allowlist:** unlike D.1's pure visibility demotion (invisible to the
digester by construction — see the note at the end of this file), removing a
parameter from a public initializer signature IS digester-visible. Two entries were
added to `.github/api-breakage-allowlist.txt`:

```
API breakage: constructor ConversationRuntime.init(messageStore:sessionStore:inferenceService:pipeline:budgetPlanner:ragService:auxiliaryInferenceService:usageStore:generationHooks:compressionPolicy:preTurnCompressionPolicy:historyShaper:historyProviders:hostTurnContextProvider:turnContextProvider:sessionToolSources:hookRegistry:runStore:) has removed default argument from parameter 13
API breakage: constructor ConversationRuntimeOptions.init(pipeline:budgetPlanner:generationHooks:compressionPolicy:preTurnCompressionPolicy:historyShaper:historyProviders:hostTurnContextProvider:turnContextProvider:auxiliaryInferenceService:runStore:) has been removed
```

Verified clean via `scripts/api-demotion-screen.sh HostTurnContextProvider
ManifoldRuntime` (PASS) run after the docs rewrite above. Before the rewrite, the
screen FAILed on a single hit: `ContributingConversationHistory.md`'s host-conformance
walkthrough (the `ActivePersonaProvider` example) and its symbol links in
`ContributingConversationHistory.md` / `ManifoldRuntime.md`, all removed/replaced by
this PR — see "What did not move" above for what stayed, and the article's own
"Per-turn host data" section for the rewritten guidance pointing hosts at
`turnContextProvider`.

## A.1 — ManifoldInference

- `TurnHistoryCompressor` (protocol) and its two in-tree conformers,
  `BudgetTurnHistoryCompressor` and `NoOpTurnHistoryCompressor`
- `CompactionTrigger`, `CompressedTranscript`, `TurnHistoryRecord` — the
  `TurnHistoryCompressor` family's supporting value types
- `NoOpDialogueSummariser` (the `DialogueSummariser` protocol and
  `DefaultDialogueSummariser` stay public — see rejected list below)
- `ModelSelecting` (protocol only — `ModelSelection`, the concrete class, and every
  type its own public methods return, e.g. `ScoredModel`, stay public; see below)
- `StructuredOutputSchema`
- `ToolSpillReaper`
- `HuggingFaceProbe`

All of the above are internal implementation detail: never a parameter, return,
thrown, generic-constraint, or default-argument type on another public declaration's
signature, and (re-confirmed with the corrected `**/*.docc/**` glob after the A.2
DocC-glob screen-script bug was found, against every `.docc` catalog in `Sources/`,
not just ManifoldInference's own) not documented anywhere.

### A.1 candidates that were screened but rejected (stayed public)

The A.0 verification screen (`scripts/api-demotion-screen.sh`) flagged most of these as
`NEEDS-HAND-ADJUDICATION` or even `PASS`; hand adjudication against the actual source
(the screen's Step 2 in-repo signature-anchor check explicitly does not gate its own
verdict — it says so in its own output) found each one anchored to a public
declaration's signature elsewhere, so demoting it would not compile. Recorded here so
the next pass over Appendix 1 doesn't re-propose them without re-deriving the same
reasoning:

- `MarkdownRendering` — documented by name in
  `Sources/ManifoldFuzz/ManifoldFuzz.docc/RunRecordSchema.md`, which cites
  `MarkdownRendering.renderToVisibleString` as the exact transform a persisted
  `RunRecord` fixture's `rendered` field depends on. Found only after re-running the
  docs/DocC check with the corrected `**/*.docc/**` glob (the original glob never
  matched a catalog nested under `Sources/<Module>/` — same bug the A.2 cluster found
  and fixed in PR #2254).
- `BudgetPolicy` — parameter type of the public `PromptAssembler.assemble(...)`
  overloads; also now documented by `ContributingPromptContext.md` (PR #2253, merged).
- `PromptSlotRole`, `ResolvedSlot` — same DocC article (PR #2253, merged);
  `ResolvedSlot` is additionally the element type of `AssembledPrompt.orderedSlots`,
  and `AssembledPrompt` is explicitly excluded from demotion by the plan (B.5 —
  manifold-eval reproduces production prompt assembly against it).
- `SchemaProviding`, `StructuredOutput`, `ReaskPolicy` — generic constraint / return
  type / parameter type (respectively) of the public
  `InferenceService.respond<T>(_:to:config:)` family.
- `StructuredOutputError` — the thrown error type of the same `respond` family;
  documented by name in `Sources/ManifoldRuntime/ManifoldRuntime.docc/Articles/ErrorHandlingAtTheBoundary.md`.
- `PartialSnapshot` — return type (`AsyncThrowingStream<PartialSnapshot<T>, Error>`) of
  the public `InferenceService.streamObject(_:to:config:)`. The screen's single-line
  Step 2 grep missed this because the return type sits on a wrapped line below the
  `public func` line.
- `GBNFSchemaPreValidator` — parameter type of the public
  `ToolGrammarBuilder.init(preValidator:)`.
- `JSONSchemaValidating` — type of the public, settable `ToolRegistry.validator`
  property.
- `ToolOutputPolicy` — type of the public, settable `ToolRegistry.outputPolicy`
  property.
- `OversizeAction` — type of `ToolOutputPolicy.onOversize`, chained from the above.
- `WedgeWatchdog` — parameter type (`any WedgeWatchdog`) of the public
  `ModelExecutor.init(key:backendName:loader:makeWatchdog:)`.
- `RealWedgeWatchdog` — used only as that init's *default argument value*
  (`{ RealWedgeWatchdog(budget: .seconds(120)) }`); confirmed via compiler error
  (`initializer 'init(budget:)' is package and cannot be referenced from a default
  argument value`) that default-argument expressions require the same visibility as
  the enclosing public function, not just module-internal reachability.
- `DialogueSummariser` — parameter type (`any DialogueSummariser`) of the public
  `SummarisationHook.init(...)` (ManifoldRuntime).
- `DefaultDialogueSummariser` — same init's default argument value; rejected for the
  same reason as `RealWedgeWatchdog` above (confirmed via the identical compiler
  error).
- `ToolApprovalDecision` — return type of the public `AutoApproveGate.approve(_:)`
  and consumed by `ManifoldUI`'s public `UIToolApprovalGate.approve`/`.resolve`.
- `PreToolUseOutcome` — the resolved return type of the public `PreToolUseHook`
  typealias, itself a parameter type of the public
  `InferenceService.enqueue(structuredMessages:...)`.
- `ExecutorState` — type of the public `ModelExecutor.state` computed property.
- `ModelExecutorKey` — type of multiple public `ModelExecutor`/`ModelExecutorPool`
  properties and init parameters (`ModelExecutor` is a public actor).
- `MessageKind`, `MessageStatus` — types of the public `ChatMessage.kind` /
  `.status` properties (`ChatMessage` is the core transport type); `MessageKind` is
  additionally referenced from public computed properties in
  `ManifoldPersistenceSwiftData`'s schema versions.
- `PostGenerationTask` — element type of the public, settable
  `ChatViewModel.postGenerationTasks` array (`ManifoldUI`).
- `LoadIntent` — parameter type of the public `ModelLoadCoordinator.dispatchLoad(_:)`.
- `ModelLoadStatus` — type of public `ModelLoadCoordinator.status` /
  `.statusUpdates()` and `ModelSelection.loadStatusUpdates()`.
- `ScoredModel`, `ModelSelectionGroup`, `ModelSelectionSortOrder` — return/parameter
  types of `ModelSelection`'s own public methods (`scoredModels`, `rankedModels`,
  `sortedModels`, `groupedModels`) — `ModelSelection` (the concrete class) is not
  itself a demotion candidate, so these stay public independent of the
  `ModelSelecting` protocol's fate.
- `ContextBudget` — return type of the public
  `ContextWindowManager.calculateBudget(...)`.
- `RenderedPrompt` — return type of the public `ChatTemplate.format(...)`.
- `ProbeResult` — return type of `probe(timeout:)`, a default-implemented method on
  the public `HuggingFaceServiceProtocol` (members of a `public extension` default to
  public in Swift, so this is a real public API surface despite reading like an
  internal helper).

### Screen-verdict accuracy note

None of the four candidates the screen scored a clean **PASS** (`JSONSchemaValidating`,
`SchemaProviding`, `ToolOutputPolicy`, `WedgeWatchdog`) actually survived hand
adjudication — every one is anchored to a public signature elsewhere in the package
that the screen's Step 1–3 checks do not (and by design cannot) see, since those
checks only look at external consumer repos and docs, not in-repo public signatures.
The screen's own Step 2 output says as much ("Step 2 anchor hits ... still need
reviewer eyes before demotion"). Future clusters should budget real time for Step 2
review even on a `PASS` verdict, not just on `NEEDS-HAND-ADJUDICATION`.

## A.3 — Leaf-module internals (ManifoldContract, ManifoldHardware, ManifoldModelCatalog)

- `ManifoldContract`: `SentenceCoalescer` (struct) — the accessibility
  sentence-coalescing utility whose only consumer is `ManifoldUI`'s
  `AccessibilityAnnouncer` (in-package). Reachable via `import ManifoldContract`
  but had zero external consumer, companion, or doc references.
- `ManifoldHardware`: `CategorizedError` (protocol), `InferenceErrorCategory`
  (enum) — the `error.category` routing view on `InferenceError` /
  `CloudBackendError` is now `package`-only; `ChatTemplateIntegritySidecar`
  (struct) — internal chat-template drift-detection sidecar, only ever
  constructed by `ModelLifecycleCoordinator`'s private load path;
  `DeviceCapability` (enum) — a namespace of static query predicates
  (`supports(tier:)`, `highestSupportedTier(for:)`, `canLoadModel(...)`)
  layered over `DeviceCapabilityService`/`ModelLoadPlan`, unused by any
  consumer; `DownloadedModelPackageManifest` (struct) — the on-disk
  readiness marker for multi-file model packages, an internal storage
  concern of `ModelStorageService`/`ManifoldHuggingFace`.
- `ManifoldModelCatalog`: `NetworkPolicyGuard` (enum) — the stateless
  URL-vs-network-policy check called internally by
  `NetworkPolicyURLProtocol`/`CompositeURLSessionDelegate`.

### A.3 candidates that were screened but rejected (stayed public)

Several A.3 candidates listed in the plan's Appendix 1 turned out, on hand
adjudication, to back a live public signature, a companion/app cross-package
usage the mechanical grep screen couldn't see (member-access syntax like
`.cooperative` doesn't name the type), or a DocC article the screen script's
Step 3 glob couldn't match before its `**/*.docc/**` fix (PR #2254). Every A.3
candidate was re-screened with the corrected glob before this PR was marked
ready. Recorded here so the next pass over Appendix 1 doesn't re-propose them:

- `StreamTransform` (Contract) — listed under "Topics > Transforms" in
  `ManifoldInference.docc/Extensions/OutputParserSession.md`, documenting it
  as part of the `OutputParserSession` pipeline-construction API. The
  original screen's DocC check missed this due to the glob bug above.
- `CancellationStyle` (Hardware) — backs `BackendCapabilities.cancellationStyle`,
  a public field constructed by both companion backends
  (`manifold-mlx`, `manifold-llama`) via `BackendCapabilities(cancellationStyle: .cooperative, ...)`.
- `ModelPackageKind` (Hardware) — backs `DownloadableModel.packageKind`, a
  public field on a type idlewick (a first-party consumer) constructs
  directly.
- `ModelUseCase` (Hardware) — backs `ModelManagementViewModel.selectedUseCase`,
  a public var on a view model actively injected by all three first-party
  apps (basechat, fireside, idlewick).
- `UnloadReason` (Hardware) — fireside pattern-matches
  `MemoryPressureEvent.willUnload`/`.didUnload` cases directly
  (`reason == .criticalMemoryPressure`, etc.) — a live consumer dependency
  the type-name-only screen missed.
- `LocalModelDescriptor` (Hardware) — backs the public
  `BackendDescriptorRegistry.shared.register(_ descriptor: LocalModelDescriptor)`
  third-party-registration seam (same pattern documented for
  `CloudProviderDescriptor`); no current caller, but the public entry point
  requires the type to stay public.
- `ContentFilteringDisclosure` (Hardware) — backs the public
  `ModelSelectionProfile.contentFiltering` field and initializer parameter;
  `ModelSelectionProfile` itself is public (used as
  `ModelSelectionCandidate.resident(_:)`'s associated value), even though an
  in-source note marks the whole cluster "not yet wired" as of the
  2026-07-03 inert-surface audit.
- `CacheBreakpointPlan` / `PromptCachePolicy` (ManifoldCloudCore) — **verified
  live**: `ClaudeBackend.cachePolicy` is a public get/set property, and
  `annotateCacheBreakpoints(plan:...)` is a public function; both back the
  shipped Anthropic prompt-cache-breakpoint feature (`cache_control:
  {type: "ephemeral"}` tagging on the system prompt and tool catalog,
  reducing repeat-turn input costs 4–10× for large system prompts/tool
  catalogs). Not an inert-surface / #2128 candidate — this is a working,
  documented, user-facing cost-control knob.
- `DiagnosticsService` (ManifoldModelCatalog) — backs
  `ManifoldBootstrap.diagnostics`, a public stored property on ManifoldKit's
  canonical bootstrap entry point every consumer app constructs.
- `DiffusionDownloadProgress` (ManifoldHuggingFace) — backs the public
  `HuggingFaceService.downloadDiffusionModel(..., progress:)` closure
  parameter; `HuggingFaceService` itself is actively instantiated directly
  by idlewick (`HuggingFaceService()`), so the type fails A.0 check #2 (not
  a parameter/return type on a public signature of an externally-used type).

### Digester allowlist note

`swift package diagnose-api-breaking-changes` (the CI `api-digester-check` job)
does not flag pure `public → package` visibility demotions in this repo: without
`-enable-library-evolution`, the plain `.swiftmodule` the digester reads keeps
`package`-visible symbols in its symbol table on both the baseline and current
side, so a bare visibility narrowing (no signature/rename change) is invisible to
it by construction. Confirmed three independent ways across A.2/A.3: the exact CI
command run locally, a controlled flip-an-untouched-type test, and a manual
low-level `swift-api-digester -dump-sdk` reproduction. No `.github/api-breakage-allowlist.txt`
entries were needed for any Phase A cluster.

## D.4 — AccessibilityAnnouncer (wired internally + demoted)

Part of the [runtime residual sweep](plans/api-v1-rationalisation-2026-07.md)
(item D.4, Rory decision 2026-07-15) — a follow-up to Phase A's A.2 cluster,
which flagged `AccessibilityAnnouncer` `NEEDS-HAND-ADJUDICATION` rather than
demoting it (see the updated A.2-rejected entry above).

- `AccessibilityAnnouncer` (`ManifoldUI`) — carried a `## How to use it`
  runnable example describing direct host construction, but had zero in-repo
  call sites (only a `// should drive` comment in `ThinkingBlockView.swift`)
  and zero adopters across all six consumer repos. Rather than either
  freezing a documented-but-inert public seam or deleting real, tested
  coalesce/rate-limit/priority logic, this PR **wires it into the real
  streaming path** and demotes it in the same change: `ChatGenerationCoordinator`
  now owns the sole instance and drives it from `ConversationEvent` —
  `ingest(_:)` on `.tokenEmitted`, `finish(reason:)` on `.streamFinished` /
  `.errorRaised` (mapping `ManifoldRuntime.FinishReason` /
  `ConversationError` onto `GenerationCompletion.Reason`), `reset()` on
  `.streamStarted`.
- **No replacement API.** Every chat surface built on `ChatViewModel` now gets
  paced VoiceOver announcements on streaming completion automatically — there
  is nothing for a host to opt into or construct. If your app previously
  planned to construct `AccessibilityAnnouncer()` directly by following the
  old doc, stop: the behavior now ships for free, and the type is no longer
  reachable outside this package.
- The type, its nested `Priority` enum, `PostHandler` typealias, and all
  members (`ingest`, `finish`, `reset`, `platformPost`, `minimumInterval`,
  `init`) move `public` → `package` together — same pattern as Phase A. No
  digester allowlist entry needed (see the note above; applies identically
  here).

## D.2+D.3 — Agentic Run subsystem + background-task bridge (ManifoldRuntime, ManifoldPersistenceSwiftData, 2026-07-15)

Part of the [runtime residual sweep](plans/api-v1-rationalisation-2026-07.md)
(items D.2 and D.3, Rory decision 2026-07-15). Both PRs are riding the same
change because they share a module, a doc gate, and the `ManifoldRuntime`
baseline; D.3 is folded into this PR per the plan's own note ("Rides the D.2
PR").

### D.2 — Agentic Run subsystem: demoted whole, not deleted

`ConversationRun`/`RunStep`/`RunStatus`/`RunEvent`/`RunStore`/`RunStoreError`/
`RunInputProvider`/`FixedGoalRunInputProvider`/`ResumableRunDriver` (all
`ManifoldRuntime`) and `SwiftDataRunStore` (`ManifoldPersistenceSwiftData`)
move `public` → `package` together, plus:

- `ConversationRuntime.startRun`/`resumeRun`/`pauseActiveRun`/`cancelActiveRun`
  — demoted to `package`.
- `ConversationRuntimeOptions.runStore` — demoted to `package` (same pattern
  as `hostTurnContextProvider` in D.6: the property still exists and is still
  mutated by `ManifoldBootstrap`, it just isn't settable through the public
  memberwise initializer any more).
- `ManifoldBootstrap.runStore` (public property) — demoted to `package`,
  since a public property cannot expose a now-package type.
- `ManifoldBootstrap.init(...)`'s and `ManifoldBootstrap.build(...)`'s
  `enableResumableRuns: Bool = false` parameter — removed from the public
  overloads. Each split into a slimmer public overload (no
  `enableResumableRuns`) and a `package` sibling that keeps the full
  signature with `enableResumableRuns` **required** (no default) — the exact
  D.6 pattern (see that section above), applied to both an `init` and a
  `static func` this time. Omitting the label always resolves to the public
  overload; supplying it always resolves to the `package` one, so the two can
  never become ambiguous.

**Zero-adopter evidence:** the plan's addendum (see link above) verified zero
external adopters for the whole subsystem across all six consumer repos
(three first-party apps, manifold-mlx, manifold-llama, manifold-eval) —
`docs/plans/inert-code-audit-2026-07.md` item 51 first flagged it as
built-wired-tested-but-inert; the only place `enableResumableRuns` was ever
flipped to `true` anywhere in this repo is
`Tests/ManifoldPersistenceSwiftDataTests/ResumableRunEndToEndTests.swift`.
Per-type `scripts/api-demotion-screen.sh` runs (all against
`ManifoldRuntime`, except `SwiftDataRunStore` against
`ManifoldPersistenceSwiftData`) confirm this PASSes or is
NEEDS-HAND-ADJUDICATION-on-noisy-common-names (never a real hit) for every
demoted type:

| Type | Verdict |
|------|---------|
| `ConversationRun` | NEEDS-HAND-ADJUDICATION (21 member-name hits, all noisy generic identifiers — `id`, `status`, `goal`, etc. — hand-checked against the six repos: none are calls into this type) |
| `RunEvent` | PASS |
| `RunStatus` | NEEDS-HAND-ADJUDICATION (37 member-name hits, all noisy — `pending`/`running`/`paused`/`completed`/`cancelled`/`failed` are common enum-case names elsewhere; hand-checked, none anchor to this type) |
| `RunStep` | NEEDS-HAND-ADJUDICATION (14 member-name hits, all noisy — `id`, `isCompleted`, `isFailed`, etc.; hand-checked, none anchor to this type) |
| `RunStore` | PASS |
| `RunStoreError` | NEEDS-HAND-ADJUDICATION (4 member-name hits — `errorDescription` is `Error`'s own requirement name, appears everywhere; hand-checked, none anchor to this type) |
| `RunInputProvider` | PASS |
| `FixedGoalRunInputProvider` | PASS |
| `ResumableRunDriver` | PASS |
| `SwiftDataRunStore` (`ManifoldPersistenceSwiftData`) | PASS |

The screen's Step 2 in-repo signature-anchor check additionally flagged
`ManifoldSchemaV10.ConversationRunModel`'s/`RunStepModel`'s `public`-keyword
methods (`init(_:)`, `update(from:)`, `toRecord()`) that take/return
`ConversationRun`/`RunStep`. These are **not** a real anchor: `ManifoldSchemaV10`
itself has no access modifier (`enum ManifoldSchemaV10: VersionedSchema`,
i.e. `internal`), so the `public` keyword on its nested types and their
members is already capped to the enclosing type's `internal` access by
Swift's access-level rules — referencing a `package` type from an
effectively-`internal` member is never a leak. No schema-file edit was
needed or made (see below).

**What did NOT move — the frozen schema:** `ManifoldSchemaV10` and its
`@Model` types (`ConversationRunModel`, `RunStepModel`) are untouched.
SwiftData migration history is immutable by construction — editing a shipped
schema version is how you corrupt an existing on-disk store on upgrade.
**Accepted consequence:** V10's run tables remain part of the public schema
history (any app that ever ran with `enableResumableRuns: true` still
migrates its rows forward correctly) while the feature surface that reads
and writes them is now `package`-only — the tables are permanently dormant
for any host outside this package until the subsystem re-promotes on a first
real adopter. This is the same trade the plan's addendum called out in
advance ("demotion preserves migration integrity but leaves a
permanently-dormant public schema version no host can exercise while the
flag is `package` — accepted and stated, not hidden").

**Digester allowlist:** five entries appended to
`.github/api-breakage-allowlist.txt` — three parameter-removal/default-removal
breakages in `ManifoldRuntime` (`ConversationRuntime.init` splitting into two
overloads, one with `runStore` moved later in a shrunk parameter list, one
losing the parameter's default outright; `ConversationRuntimeOptions.init`
losing its `runStore` parameter) and two in `ManifoldPersistenceSwiftData`
(`ManifoldBootstrap.init` and `ManifoldBootstrap.build` both losing
`enableResumableRuns`'s default argument as the public overloads split from
their `package` siblings):

```
API breakage: constructor ConversationRuntime.init(messageStore:sessionStore:inferenceService:pipeline:budgetPlanner:ragService:auxiliaryInferenceService:usageStore:generationHooks:compressionPolicy:preTurnCompressionPolicy:historyShaper:historyProviders:hostTurnContextProvider:turnContextProvider:sessionToolSources:hookRegistry:runStore:) has removed default argument from parameter 17
API breakage: constructor ConversationRuntime.init(messageStore:sessionStore:inferenceService:pipeline:budgetPlanner:ragService:auxiliaryInferenceService:usageStore:generationHooks:compressionPolicy:preTurnCompressionPolicy:historyShaper:historyProviders:turnContextProvider:sessionToolSources:hookRegistry:runStore:) has been removed
API breakage: constructor ConversationRuntimeOptions.init(pipeline:budgetPlanner:generationHooks:compressionPolicy:preTurnCompressionPolicy:historyShaper:historyProviders:turnContextProvider:auxiliaryInferenceService:runStore:) has been removed
API breakage: constructor ManifoldBootstrap.init(configuration:ragConfiguration:inferenceService:imageGenerationService:videoGenerationService:webSearchRuntime:diagnostics:runtimeOptions:sessionToolSources:hookRegistry:enableResumableRuns:makeModelContainer:isInMemory:audioGenerationService:) has removed default argument from parameter 10
API breakage: func ManifoldBootstrap.build(configuration:ragConfiguration:inferenceService:imageGenerationService:videoGenerationService:webSearchRuntime:diagnostics:runtimeOptions:sessionToolSources:hookRegistry:enableResumableRuns:makeModelContainer:audioGenerationService:) has removed default argument from parameter 10
```

`swift package diagnose-api-breaking-changes origin/main --targets
ManifoldRuntime ManifoldPersistenceSwiftData --breakage-allowlist-path
.github/api-breakage-allowlist.txt` is clean with these entries in place.

**Replacement for hosts:** none — this is the same "no replacement API"
shape as D.4. No host anywhere ever set `enableResumableRuns: true` outside
this package's own end-to-end test, so there is no live migration path to
document; a host that genuinely wants checkpointed multi-step runs should
open an issue describing the use case (re-promotion candidate on first real
adopter, per the plan's standing bias).

### D.3 — Background-task bridge: demoted, doc rewritten in the same PR

`ConversationRuntimeBackgroundBridge` and `ManifoldBackgroundTaskIdentifiers`
(both `ManifoldRuntime`) move `public` → `package` together, including every
member (`handleExpiration()`, `backgroundGPUAvailable`, `init(runtime:)`, and
the four identifier constants).

**Zero-adopter evidence:** `scripts/api-demotion-screen.sh
ConversationRuntimeBackgroundBridge ManifoldRuntime` and `...
ManifoldBackgroundTaskIdentifiers ManifoldRuntime` both report **FAIL**
against the working tree in this PR — but re-running the screen against the
pre-this-PR tree (`git stash` the two doc edits, re-run, pop) shows the FAIL
was never a real external-consumer hit in either direction:
- **Before this PR:** the FAIL was `BackgroundTaskSupport.md`'s *own*
  `swift,no-build` recipe constructing `ConversationRuntimeBackgroundBridge`
  directly and referencing `ManifoldBackgroundTaskIdentifiers.continueGeneration`
  — i.e. the exact "documented but zero real adopters" shape D.3 exists to
  fix, not evidence of an adopter. (`README.md`'s historical BaseChatKit→
  ManifoldKit rename bullet also matches `ManifoldBackgroundTaskIdentifiers`
  by name; it is a frozen rename note, not a usage instruction — same
  treatment as D.6's rejected candidates.)
- **After this PR:** the FAIL is this PR's own migration notes
  (`docs/MIGRATION-background-task-scheduler-removed.md`'s "Update
  (2026-07-15)" addendum, and the rewritten `BackgroundTaskSupport` article's
  explanatory note about the demotion) — the same self-referential-migration-
  note shape D.6 hit.

Neither state shows a real consumer anywhere in this repo or the six survey
repos; both types were constructed only in the now-rewritten DocC recipe.

**Doc rewrite (same PR, per the plan's F4 finding):** `BackgroundTaskSupport.md`
(`Sources/ManifoldRuntime/ManifoldRuntime.docc/Articles/`) previously
instructed host construction of `ConversationRuntimeBackgroundBridge`
directly. Its code fences are `swift,no-build`, so the doc-snippet compile
gate would never have caught a recipe that no longer compiles for an outside
consumer — banner-over-the-recipe was rejected for exactly this reason (see
F4 in the addendum's review record). The article is rewritten to show the
`BGContinuedProcessingTask.expirationHandler` recipe calling the still-public
``ConversationRuntime/cancelAllTurns()`` directly (`Task.detached { await
conversationRuntime.cancelAllTurns() }`), with a note explaining that the
internal `ConversationRuntimeBackgroundBridge` helper exists but is
`package`-only. `ConversationRuntime.cancelAllTurns()`'s own doc comment
(previously linking the now-package `ConversationRuntimeBackgroundBridge`
via a DocC symbol link, which would have rendered as a broken link in public
docs) is rewritten the same way.

**Replacement for hosts:** ``ConversationRuntime/cancelAllTurns()`` — public,
unaffected by this PR, async, idempotent, safe to call with no turns in
flight. It is the same one-line call the bridge wrapped; the bridge added
only the `Task.detached` synchronous-handler bridging, which any host can
write inline (see the rewritten article).

**No digester allowlist entries needed** for D.3 — both are pure
`public` → `package` visibility demotions with no public-signature changes
elsewhere (same as D.1/A.1–A.3; see the note at the top of this file).

## 2026-07-21 inert-surface sweep (#2128 rulings)

Four more demotions, decided in the #2128 rulings comment dated 2026-07-21
(consumer evidence: the eight-app consumer screen run that day — three
first-party apps, manifold-mlx, manifold-llama, manifold-eval, plus the two
apps added to the survey since the plan's original six-repo baseline).
Same contract as every entry above: `package` types are not part of the
public SwiftPM surface, and (except where noted) no behavior changed.

### `NetworkActivityCenter` (`ManifoldNetworking`) — demoted, not deleted

`NetworkActivityCenter` (the class, its `.shared` singleton, and all its
members) plus its three supporting types — `NetworkActivity`,
`NetworkActivityKind`, `NetworkActivityToken` — move `public` → `package`
together. The producer wiring stays real and live:
`URLSessionFactory.ephemeral(...)`, `BackgroundDownloadManager`, and
`HuggingFaceService` all still funnel begin/end/updateDownload calls into
`NetworkActivityCenter.shared` on every request. What's missing is a reader:
as of the 2026-07-21 screen, nothing outside this package subscribes via
`.updates()` or displays `.current`/`.activeHosts`/`.inFlightCount` — the
status-indicator surface the type was built for doesn't exist anywhere yet.

**Signature changes this forced (Swift does not allow a `public` function to
take a `package`-typed parameter, even a defaulted one):**

- `URLSessionFactory.ephemeral(hopCap:resourceTimeout:additionalDataDelegate:activityCenter:)`
  → `ephemeral(hopCap:resourceTimeout:additionalDataDelegate:)`. The
  `activityCenter` parameter is gone from the public signature; the factory
  always wires `NetworkActivityCenter.shared` internally now. No caller
  anywhere in this repo or the eight surveyed consumer repos ever passed a
  non-default value.
- `HuggingFaceService.init(hubClient:activityCenter:)` →
  `init(hubClient:)`, same reasoning.
- `BackgroundDownloadManager.init(storageService:sessionIdentifier:persistenceDirectory:tempScanDirectory:userDefaults:activityCenter:)`
  → drops `activityCenter:`, same reasoning.

**Replacement for hosts:** none needed — every dropped parameter only ever
carried its default value in practice. A host that previously passed a
custom `NetworkActivityCenter` for test isolation should construct the
`URLSession`/service/manager the normal way; the shared center is
process-wide and `@MainActor`-isolated, so parallel test isolation was never
actually achieved by injecting a fresh instance through these particular
call sites (the in-package unit tests that need isolation construct
`NetworkActivityTrackingDelegate` directly instead — see
`Tests/ManifoldNetworkingTests/NetworkActivityCenterTests.swift`).

**Digester allowlist:** three entries appended to
`.github/api-breakage-allowlist.txt` for the signature changes above (two
"has been removed" constructor breakages, one "has been renamed" — the
digester reads a parameter's removal from an otherwise-identical signature as
a rename). No entry needed for the `NetworkActivityCenter`
visibility demotion itself or its three supporting types (pure `public` →
`package`, invisible to the digester by construction — see the note at the
top of this file).

**Re-promotion signal:** issue #1292 tracks a documented consumer-app ask for
exactly the network-status indicator this type was built for.

### `ModelCatalog` (`ManifoldModelCatalog`) — demoted, not deleted

`ModelCatalog` (the actor, `manifestFileName`, `init`, and all five methods —
`catalog()`, `record(_:)`, `evict(_:deleteArtifact:)`,
`enforceDiskBudget(_:)`, `touch(_:at:)`) moves `public` → `package`. As
recorded in the type's own doc comment since the 2026-07-03 inert-surface
audit, no production code path constructs one — `ManifoldBootstrap`,
`ModelManagementViewModel`, and `ModelRegistry` all use
`ModelStorageService` directly. Only this type's own in-package tests
construct and exercise it.

**What did NOT move:** `CatalogEntry` and `ModelSource` stay `public` — they
carry no behavior of their own (plain `Codable` value types) and are not the
inert surface; only the actor that drove them is. No other public
declaration in this package references either type, so this leaves no
orphaned public signature.

**Digester allowlist:** none needed (pure visibility demotion).

### `RouterBackend` (`ManifoldInference`) — demoted, not deleted

`RouterBackend` (the class, `children`, `init(children:)`, and every method —
`selectBackend(for:)`, `loadModel(from:plan:)`, `generate(...)`,
`stopGeneration()`, `unloadModel()`, `resetConversation()`, plus the
`isModelLoaded`/`isGenerating`/`capabilities` properties) moves `public` →
`package`. This resolves the plan's B.5 adjudication item for the
reliability-wrapper cluster (`FallbackBackend`, `RouterBackend`,
`RetryStrategy` + friends): well-tested (`RouterBackendTests`, unaffected by
this PR), zero adopters. Unlike `FallbackBackend`'s error-advance routing
(which stays public and gains a DocC article — "Reliability Wrappers" — in
this same PR), the 2026-07-21 screen found no adopter for the
capability-select routing `RouterBackend` provides specifically, so it
demotes rather than promotes.

Every doc comment elsewhere in the package that symbol-linked
```` ``RouterBackend`` ```` is rewritten to a plain `` `RouterBackend` `` code
span in this PR (`ManifoldHardware/BackendCapabilities.swift`,
`ManifoldHardware/InferenceError.swift`,
`ManifoldHardware/GenerationCapabilityRequirement.swift`,
`ManifoldInference/Protocols/InferenceBackend+CapabilityGate.swift`,
`ManifoldInference/Services/FallbackBackend.swift`,
`ManifoldInference/Services/FallbackPolicy.swift`) — the same "would render
as a broken link in public docs" fix D.3/D.4 applied above.

**Digester allowlist:** none needed (pure visibility demotion;
`RouterBackend: InferenceBackend` conformance is unaffected — a `package`
type can conform to a `public` protocol without widening anything).

**Re-promotion signal:** a host that needs capability-based multiplexing
across already-loaded backends is the trigger; open an issue describing the
use case.

### Benchmark surface on `ModelManagementViewModel` (`ManifoldUIModelManagement`)

`benchmarkRunner`, `isBenchmarking`, `benchmarkResults`, and
`runBenchmark(for:)` move `public` → `package`. **What did NOT move:** the
underlying `ModelBenchmarkRunner` protocol and `ModelBenchmarkResult` value
type (in `ManifoldModelCatalog`) stay `public` — the benchmark *engine* is a
live, documented capability; what's inert is this specific view model's
action wiring, for which the 2026-07-21 eight-app screen found zero adopters.
`benchmarkCache` (the storage-neutral cache property) is unaffected and
stays public — it is not part of this demotion.

**Digester allowlist:** none needed (pure visibility demotion).
