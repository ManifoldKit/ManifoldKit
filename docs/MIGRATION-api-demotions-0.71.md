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
