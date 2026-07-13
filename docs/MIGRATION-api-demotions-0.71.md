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

## A.2 — ManifoldUI + ManifoldUIModelManagement (this PR)

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
