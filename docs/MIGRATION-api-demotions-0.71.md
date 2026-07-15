# Migration: Phase A API demotions (0.71)

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
- `AccessibilityAnnouncer` — carries its own `## How to use it` runnable example describing direct host construction (`AccessibilityAnnouncer()` driven from a host's own event loop); despite having no in-repo call site today, the documented contract reads as intentionally host-facing, not internal. Flagged for a human decision on whether to formally deprecate the promise or keep it public — not touched in this PR.
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
